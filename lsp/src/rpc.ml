open Import

type t =
  { ic : in_channel
  ; oc : out_channel
  ; fd : Unix.file_descr
  ; mutable state : state
  }

and state =
  | Ready
  | Initialized of Initialize.ClientCapabilities.t
  | Closed

let { Logger.log } = Logger.for_section "lsp"

let send rpc json =
  log ~title:"debug" "send: %a"
    (fun () -> Yojson.Safe.pretty_to_string ~std:false)
    json;
  let data = Yojson.Safe.to_string json in
  let length = String.length data in
  let contentLengthString =
    "Content-Length: " ^ string_of_int length ^ "\r\n"
  in
  output_string rpc.oc contentLengthString;
  output_string rpc.oc "\r\n";
  output_string rpc.oc data;
  flush rpc.oc

module Headers = struct
  type t = { content_length : int option }

  let initial = { content_length = None }

  let content_length = "Content-Length: "

  let content_length_len = String.length content_length

  let end_line = "\r\n"

  let end_line_len = String.length end_line

  let has_content_length s =
    String.length s > content_length_len
    && String.compare
         (String.sub s ~pos:0 ~len:content_length_len)
         content_length
       = 0

  let parse_content_length line =
    let v =
      String.sub line ~pos:content_length_len
        ~len:(String.length line - end_line_len - content_length_len)
    in
    int_of_string v

  type state =
    | Partial of t
    | Done of t

  let parse_line headers line =
    if String.compare line "\r\n" = 0 then
      Done headers
    else if has_content_length line then
      let content_length = parse_content_length line in
      Partial { content_length = Some content_length }
    else
      Partial headers

  let read ic =
    let rec loop headers =
      let line = input_line ic in
      match parse_line headers (line ^ "\n") with
      | Partial headers -> loop headers
      | Done headers -> headers
    in
    loop initial
end

let read rpc =
  let open Result.Infix in
  let read_content rpc =
    Thread.wait_read rpc.fd;
    let headers = Headers.read rpc.ic in
    match headers.content_length with
    | Some len ->
      let buffer = Bytes.create len in
      let rec read_loop read =
        if read < len then
          let n = input rpc.ic buffer read (len - read) in
          read_loop (read + n)
        else
          ()
      in
      let () = read_loop 0 in
      Ok (Bytes.to_string buffer)
    | None -> Error "missing Content-length header"
  in

  let parse_json content =
    match Yojson.Safe.from_string content with
    | json ->
      log ~title:"debug" "recv: %a"
        (fun () -> Yojson.Safe.pretty_to_string ~std:false)
        json;
      Ok json
    | exception Yojson.Json_error msg ->
      Result.errorf "error parsing json: %s" msg
  in

  read_content rpc >>= parse_json >>= fun parsed ->
  match Jsonrpc.Request.t_of_yojson parsed with
  | r -> Ok r
  | exception _exn -> Error "Unexpected packet"

let send_response rpc (response : Jsonrpc.Response.t) =
  let json = Jsonrpc.Response.yojson_of_t response in
  send rpc json

module Server_notification = struct
  open Protocol

  type t = PublishDiagnostics of PublishDiagnostics.params

  let method_ = function
    | PublishDiagnostics _ -> "textDocument/publishDiagnostics"

  let yojson_of_params = function
    | PublishDiagnostics params -> PublishDiagnostics.yojson_of_params params

  let to_jsonrpc_request t =
    let method_ = method_ t in
    let params = Some (yojson_of_params t) in
    { Jsonrpc.Request.id = None; params; method_ }
end

let send_notification rpc notif =
  let response = Server_notification.to_jsonrpc_request notif in
  let json = Jsonrpc.Request.yojson_of_t response in
  send rpc json

module Message = struct
  type t =
    | Request of Jsonrpc.Id.t * Request.packed
    | Client_notification of Client_notification.t

  let of_jsonrpc (packet : Jsonrpc.Request.t) =
    let open Result.Infix in
    match packet.id with
    | None ->
      Client_notification.of_jsonrpc packet >>| fun cn -> Client_notification cn
    | Some id -> Request.of_jsonrpc packet >>| fun r -> Request (id, r)
end

type 'state handler =
  { on_initialize :
         t
      -> 'state
      -> Initialize.Params.t
      -> ('state * Initialize.Result.t, string) result
  ; on_request :
      'res.    t -> 'state -> Initialize.ClientCapabilities.t -> 'res Request.t
      -> ('state * 'res, string) result
  ; on_notification :
      t -> 'state -> Client_notification.t -> ('state, string) result
  }

let start init_state handler ic oc =
  let open Result.Infix in
  let read_message rpc = read rpc >>= Message.of_jsonrpc in

  let handle_message prev_state f =
    let start = Unix.gettimeofday () in
    let next_state = f () in
    let ellapsed = (Unix.gettimeofday () -. start) /. 1000.0 in
    log ~title:"debug" "time elapsed processing message: %fs" ellapsed;
    match next_state with
    | Ok next_state -> next_state
    | Error msg ->
      log ~title:"error" "%s" msg;
      prev_state
  in

  let rec loop rpc state =
    match rpc.state with
    | Closed -> ()
    | Ready ->
      let next_state =
        handle_message state (fun () ->
            read_message rpc >>= function
            | Message.Request (id, E (Request.Initialize params)) ->
              handler.on_initialize rpc state params
              >>= fun (next_state, result) ->
              let json = Initialize.Result.yojson_of_t result in
              let response = Jsonrpc.Response.ok id json in
              rpc.state <- Initialized params.capabilities;
              send_response rpc response;
              Ok next_state
            | Message.Client_notification Exit ->
              rpc.state <- Closed;
              Ok state
            | Message.Client_notification _ ->
              (* we drop all notifications per protocol before we initialized *)
              Ok state
            | Message.Request (id, _) ->
              (* we response with -32002 per protocol before we initialized *)
              let response =
                let error =
                  Jsonrpc.Response.Error.make ~code:ServerNotInitialized
                    ~message:"not initialized" ()
                in
                Jsonrpc.Response.error id error
              in
              send_response rpc response;
              Ok state)
      in
      Logger.log_flush ();
      loop rpc next_state
    | Initialized client_capabilities ->
      let next_state =
        handle_message state (fun () ->
            read_message rpc >>= function
            | Message.Request (_id, E (Initialize _)) ->
              errorf "received another initialize request"
            | Message.Client_notification (Exit as notif) ->
              rpc.state <- Closed;
              handler.on_notification rpc state notif
            | Message.Client_notification notif ->
              handler.on_notification rpc state notif
            | Message.Request (id, E req) -> (
              handler.on_request rpc state client_capabilities req
              >>= fun (next_state, result) ->
              match Request.yojson_of_result req result with
              | None -> Ok next_state
              | Some response ->
                let response = Jsonrpc.Response.ok id response in
                send_response rpc response;
                Ok next_state ))
      in
      Logger.log_flush ();
      loop rpc next_state
  in

  set_binary_mode_in ic true;
  set_binary_mode_out oc true;
  let fd = Unix.descr_of_in_channel stdin in
  let rpc = { ic; oc; fd; state = Ready } in
  loop rpc init_state

let stop (rpc : t) = rpc.state <- Closed

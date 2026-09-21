///|
/// A server-side push promise captured by the `TestClient`: the pushed `path`
/// and the request headers the server would send for it (`http.response.push`).
pub(all) struct PushPromise {
  path : String
  headers : Array[(String, String)]
} derive(Eq)

///|
/// First push-request header matching `name`.
pub fn PushPromise::header(self : PushPromise, name : String) -> String? {
  for pair in self.headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// A `http.response.zerocopysend` message captured by the `TestClient`: the open
/// file descriptor the app handed off, and the optional byte `offset` / `count`.
/// The sans-transport analog of the server performing the zero-copy send.
pub(all) struct ZeroCopySend {
  fd : Int
  offset : Int?
  count : Int?
} derive(Eq)

///|
/// The materialised result of driving an application in-process: the response
/// status and headers, the body reassembled from every `HttpResponseBody`
/// chunk, the trailing headers gathered from `HttpResponseTrailers`, any push
/// promises, the `pathsend` path if the app used the path-send extension, the
/// last `zerocopysend` handoff, every `debug` info payload, and the
/// `early_hints` (each a `103` message's `Link` values). The captured,
/// sans-transport analog of what a real client would observe.
pub(all) struct TestResponse {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
  trailers : Array[(String, String)]
  pushes : Array[PushPromise]
  pathsend : String?
  zerocopysend : ZeroCopySend?
  debug : Array[Json]
  early_hints : Array[Array[String]]
} derive(Eq)

///|
/// First response header matching `name` (ASGI lowercased-name convention).
pub fn TestResponse::header(self : TestResponse, name : String) -> String? {
  for pair in self.headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// First trailing header matching `name`.
pub fn TestResponse::trailer(self : TestResponse, name : String) -> String? {
  for pair in self.trailers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// The response body decoded as UTF-8 (lossy: invalid sequences become the
/// replacement character), for asserting on text responses.
pub fn TestResponse::text(self : TestResponse) -> String {
  @utf8.decode_lossy(self.body[:])
}

///|
/// The response body parsed as JSON. Raises `@json.ParseError` if the body is
/// not valid JSON, mirroring a real client's `.json()`.
pub fn TestResponse::json(self : TestResponse) -> Json raise {
  @json.parse(@utf8.decode_lossy(self.body[:]))
}

///|
/// Fold an outbound event stream into a `TestResponse`: `HttpResponseStart`
/// sets status/headers, every `HttpResponseBody` appends to the body, every
/// `HttpResponseTrailers` appends to the trailers, each `HttpResponsePush`
/// records a promise, `HttpResponsePathSend` records the served path, and every
/// `HttpResponseEarlyHint` records one `103` message's `Link` values. Other
/// events (websocket, lifespan) are ignored — the http response is what a client
/// observes.
/// 把一串事件拼回一个响应，一致性套件与测试客户端共用。
pub fn reassemble(events : Array[@spec.Event]) -> TestResponse {
  let mut status = 0
  let mut headers : Array[(String, String)] = []
  let buf = Buffer()
  let trailers : Array[(String, String)] = []
  let pushes : Array[PushPromise] = []
  let mut pathsend : String? = None
  let mut zerocopysend : ZeroCopySend? = None
  let debug : Array[Json] = []
  let early_hints : Array[Array[String]] = []
  for ev in events {
    match ev {
      HttpResponseStart(status=s, headers=h, trailers=_) => {
        status = s
        headers = h
      }
      HttpResponseBody(body=b, more_body=_) => buf.write_bytes(b[:])
      HttpResponseTrailers(headers=h, more_trailers=_) =>
        for pair in h {
          trailers.push(pair)
        }
      HttpResponsePush(path=p, headers=h) =>
        pushes.push({ path: p, headers: h, })
      HttpResponsePathSend(path=p) => pathsend = Some(p)
      HttpResponseZeroCopySend(fd~, offset~, count~, more_body=_) =>
        zerocopysend = Some({ fd, offset, count, })
      HttpResponseDebug(info~) => debug.push(info)
      HttpResponseEarlyHint(links=l) => early_hints.push(l)
      _ => ()
    }
  }
  {
    status,
    headers,
    body: buf.to_bytes(),
    trailers,
    pushes,
    pathsend,
    zerocopysend,
    debug,
    early_hints,
  }
}

///|
/// An in-process application driver — the ASGI `TestClient` — built on the
/// synchronous `@http.run_http_app` core, so it needs no socket and runs on every
/// backend. It builds a synthetic http scope, feeds the request body in as
/// `HttpRequest` events, runs the application, and reassembles the outbound
/// stream into a `TestResponse`. `app` is the event-emitting application; the
/// `new` / `from_stream` constructors adapt a `@http.Handler` / `@http.StreamHandler`.
pub(all) struct TestClient {
  app : (@http.Request) -> Array[@spec.Event]
  root_path : String
  base_headers : Array[(String, String)]
  client : (String, Int)?
  server : (String, Int?)?
  extensions : @spec.Extensions
}

///|
/// Build a `TestClient` from a raw event-emitting application (the shape
/// `@http.run_http_app` drives). Defaults mirror a typical test harness: empty
/// `root_path`, no base headers, a `("testclient", 50000)` client peer, a
/// `("testserver", 80)` server, and no advertised extensions.
pub fn TestClient::from_app(
  app : (@http.Request) -> Array[@spec.Event],
  root_path? : String = "",
  base_headers? : Array[(String, String)] = [],
  client? : (String, Int)? = Some(("testclient", 50000)),
  server? : (String, Int?)? = Some(("testserver", Some(80))),
  extensions? : @spec.Extensions = @spec.Extensions::none(),
) -> TestClient {
  { app, root_path, base_headers, client, server, extensions, }
}

///|
/// Build a `TestClient` from a unary `@http.Handler`.
pub fn TestClient::new(
  handler : @http.Handler,
  root_path? : String = "",
  base_headers? : Array[(String, String)] = [],
  client? : (String, Int)? = Some(("testclient", 50000)),
  server? : (String, Int?)? = Some(("testserver", Some(80))),
  extensions? : @spec.Extensions = @spec.Extensions::none(),
) -> TestClient {
  TestClient::from_app(
    fn(req) { handler(req).events() },
    root_path~,
    base_headers~,
    client~,
    server~,
    extensions~,
  )
}

///|
/// Build a `TestClient` from a streaming `@http.StreamHandler` (multi-chunk body,
/// optional trailers).
pub fn TestClient::from_stream(
  handler : @http.StreamHandler,
  root_path? : String = "",
  base_headers? : Array[(String, String)] = [],
  client? : (String, Int)? = Some(("testclient", 50000)),
  server? : (String, Int?)? = Some(("testserver", Some(80))),
  extensions? : @spec.Extensions = @spec.Extensions::none(),
) -> TestClient {
  TestClient::from_app(
    fn(req) { handler(req).events() },
    root_path~,
    base_headers~,
    client~,
    server~,
    extensions~,
  )
}

///|
/// Materialise a request body into inbound `HttpRequest` events. When `chunks`
/// is given each element becomes its own event (`more_body: true` on all but the
/// last), exercising a streamed request; otherwise `body` is a single event.
fn body_events(body : Bytes, chunks : Array[Bytes]?) -> Array[@spec.Event] {
  match chunks {
    Some(cs) =>
      if cs.length() == 0 {
        [HttpRequest(body=b"", more_body=false)]
      } else {
        let out : Array[@spec.Event] = []
        for i = 0; i < cs.length(); i = i + 1 {
          out.push(HttpRequest(body=cs[i], more_body=i != cs.length() - 1))
        }
        out
      }
    None => [HttpRequest(body~, more_body=false)]
  }
}

///|
/// Drive one request through the application and capture the response. Splits
/// `path` into path + query string, merges the client's `base_headers` before
/// the per-request `headers`, builds an http scope (carrying the client's
/// `root_path` / peers / advertised `extensions`), feeds the body in, runs the
/// app, and reassembles the outbound stream. Pass `chunks` to stream the request
/// body as several `HttpRequest` events.
pub fn TestClient::request(
  self : TestClient,
  http_method~ : String,
  path~ : String,
  headers? : Array[(String, String)] = [],
  body? : Bytes = b"",
  http_version? : String = "1.1",
  chunks? : Array[Bytes],
) -> TestResponse {
  let (p, q) = @spec.split_target(path)
  let scope = @spec.HttpScope::new(
    http_method~,
    path=p,
    http_version~,
    query_string=@utf8.encode(q),
    root_path=self.root_path,
    headers=[..self.base_headers, ..headers],
    client=self.client,
    server=self.server,
    extensions=self.extensions,
  )
  reassemble(
    @http.run_http_app(self.app, Http(scope), body_events(body, chunks)),
  )
}

///|
/// `GET path`.
pub fn TestClient::get(
  self : TestClient,
  path : String,
  headers? : Array[(String, String)] = [],
) -> TestResponse {
  self.request(http_method="GET", path~, headers~)
}

///|
/// `HEAD path`.
pub fn TestClient::head(
  self : TestClient,
  path : String,
  headers? : Array[(String, String)] = [],
) -> TestResponse {
  self.request(http_method="HEAD", path~, headers~)
}

///|
/// `DELETE path`.
pub fn TestClient::delete(
  self : TestClient,
  path : String,
  headers? : Array[(String, String)] = [],
) -> TestResponse {
  self.request(http_method="DELETE", path~, headers~)
}

///|
/// `POST path` with `body`.
pub fn TestClient::post(
  self : TestClient,
  path : String,
  body? : Bytes = b"",
  headers? : Array[(String, String)] = [],
) -> TestResponse {
  self.request(http_method="POST", path~, headers~, body~)
}

///|
/// `PUT path` with `body`.
pub fn TestClient::put(
  self : TestClient,
  path : String,
  body? : Bytes = b"",
  headers? : Array[(String, String)] = [],
) -> TestResponse {
  self.request(http_method="PUT", path~, headers~, body~)
}

///|
/// `PATCH path` with `body`.
pub fn TestClient::patch(
  self : TestClient,
  path : String,
  body? : Bytes = b"",
  headers? : Array[(String, String)] = [],
) -> TestResponse {
  self.request(http_method="PATCH", path~, headers~, body~)
}

///|
/// The materialised result of driving a WebSocket connection in-process: whether
/// the handshake was `accepted`, the negotiated `subprotocol` and `accept_headers`,
/// every server→client message (`messages`), whether the server `closed` and with
/// what `close_code` / `close_reason`, and — when the handshake was denied with
/// the `websocket.http.response` extension — the captured HTTP `denial` response.
/// The WebSocket analog of `TestResponse`.
pub(all) struct WsTestSession {
  accepted : Bool
  subprotocol : String?
  accept_headers : Array[(String, String)]
  messages : Array[@ws.WsMessage]
  closed : Bool
  close_code : Int?
  close_reason : String?
  denial : TestResponse?
} derive(Eq)

///|
/// First accept-response header matching `name`.
pub fn WsTestSession::header(self : WsTestSession, name : String) -> String? {
  for pair in self.accept_headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// The server→client messages that were text frames, decoded to their strings
/// (binary frames are skipped). The ergonomic assertion target for an echo/chat
/// exchange.
pub fn WsTestSession::texts(self : WsTestSession) -> Array[String] {
  let out : Array[String] = []
  for m in self.messages {
    match m {
      Text(t) => out.push(t)
      Binary(_) => ()
    }
  }
  out
}

///|
/// Fold an outbound WebSocket event stream into a `WsTestSession`:
/// `WebSocketAccept` records the handshake and negotiated subprotocol/headers,
/// every `WebSocketSendText` / `WebSocketSendBytes` appends a message,
/// `WebSocketClose` records the close, and a `WebSocketHttpResponseStart` +
/// `WebSocketHttpResponseBody` pair reconstructs the denial HTTP response. Other
/// events are ignored.
fn reassemble_ws(events : Array[@spec.Event]) -> WsTestSession {
  let mut accepted = false
  let mut subprotocol : String? = None
  let mut accept_headers : Array[(String, String)] = []
  let messages : Array[@ws.WsMessage] = []
  let mut closed = false
  let mut close_code : Int? = None
  let mut close_reason : String? = None
  let mut had_denial = false
  let mut denial_status = 0
  let mut denial_headers : Array[(String, String)] = []
  let denial_body = Buffer()
  for ev in events {
    match ev {
      WebSocketAccept(subprotocol=sp, headers=h) => {
        accepted = true
        subprotocol = sp
        accept_headers = h
      }
      WebSocketSendText(t) => messages.push(Text(t))
      WebSocketSendBytes(b) => messages.push(Binary(b))
      WebSocketClose(code~, reason~) => {
        closed = true
        close_code = Some(code)
        close_reason = Some(reason)
      }
      WebSocketHttpResponseStart(status~, headers~, ..) => {
        had_denial = true
        denial_status = status
        denial_headers = headers
      }
      WebSocketHttpResponseBody(body~, more_body=_) =>
        denial_body.write_bytes(body[:])
      _ => ()
    }
  }
  let denial : TestResponse? = if had_denial {
    Some({
      status: denial_status,
      headers: denial_headers,
      body: denial_body.to_bytes(),
      trailers: [],
      pushes: [],
      pathsend: None,
      zerocopysend: None,
      debug: [],
      early_hints: [],
    })
  } else {
    None
  }
  {
    accepted,
    subprotocol,
    accept_headers,
    messages,
    closed,
    close_code,
    close_reason,
    denial,
  }
}

///|
/// Materialise client→server messages into the inbound event stream a server
/// hands a WebSocket app: a leading `WebSocketConnect`, one `WebSocketReceive`
/// per message (text or binary), and a terminating `WebSocketDisconnect` when a
/// `disconnect` code is given.
fn ws_inbound(
  messages : Array[@ws.WsMessage],
  disconnect : Int?,
) -> Array[@spec.Event] {
  let out : Array[@spec.Event] = [WebSocketConnect]
  for m in messages {
    match m {
      Text(t) => out.push(WebSocketReceive(text=Some(t), bytes=None))
      Binary(b) => out.push(WebSocketReceive(text=None, bytes=Some(b)))
    }
  }
  match disconnect {
    Some(c) => out.push(WebSocketDisconnect(code=c, reason=None))
    None => ()
  }
  out
}

///|
/// Build the synthetic `@spec.WebSocketScope` the WebSocket driver runs against: the
/// path/query split off `path`, the client's `base_headers` merged before the
/// per-connection `headers`, the offered `subprotocols`, the websocket `asgi`
/// handshake (sub-spec `2.5`), and the client's `root_path` / peers / advertised
/// `extensions`.
fn TestClient::ws_scope(
  self : TestClient,
  path : String,
  headers : Array[(String, String)],
  subprotocols : Array[String],
) -> @spec.WebSocketScope {
  let (p, q) = @spec.split_target(path)
  @spec.WebSocketScope::new(
    path=p,
    query_string=@utf8.encode(q),
    root_path=self.root_path,
    headers=[..self.base_headers, ..headers],
    client=self.client,
    server=self.server,
    subprotocols~,
    asgi=@spec.AsgiVersion::websocket(),
    extensions=self.extensions,
  )
}

///|
/// Drive a `@ws.WebSocketHandler` through a full connection in-process and capture
/// the result. Opens a `WebSocketConnect`, feeds each `send` message in as a
/// `WebSocketReceive`, then (unless `disconnect` is `None`) a
/// `WebSocketDisconnect` with the given close code, runs the handler through the
/// synchronous `@ws.ws_run` core, and reassembles the server's outbound frames into a
/// `WsTestSession`. No socket — testable on every backend, the WebSocket
/// counterpart of `request`.
pub fn TestClient::websocket(
  self : TestClient,
  path~ : String,
  handler~ : @ws.WebSocketHandler,
  send? : Array[@ws.WsMessage] = [],
  headers? : Array[(String, String)] = [],
  subprotocols? : Array[String] = [],
  disconnect? : Int? = Some(1000),
) -> WsTestSession {
  let scope = self.ws_scope(path, headers, subprotocols)
  reassemble_ws(
    @ws.ws_run(handler, WebSocket(scope), ws_inbound(send, disconnect)),
  )
}

///|
/// Drive a general `(@spec.WebSocketScope, Array[@spec.Event]) -> Array[@spec.Event]` application
/// through a full connection in-process. Like `websocket`, but for an app that
/// consumes the whole inbound stream directly (the `@ws.ws_run_app` escape hatch)
/// rather than the connect/receive/disconnect fold.
pub fn TestClient::websocket_app(
  self : TestClient,
  path~ : String,
  app~ : (@spec.WebSocketScope, Array[@spec.Event]) -> Array[@spec.Event],
  send? : Array[@ws.WsMessage] = [],
  headers? : Array[(String, String)] = [],
  subprotocols? : Array[String] = [],
  disconnect? : Int? = Some(1000),
) -> WsTestSession {
  let scope = self.ws_scope(path, headers, subprotocols)
  reassemble_ws(
    @ws.ws_run_app(app, WebSocket(scope), ws_inbound(send, disconnect)),
  )
}

///|
pub extend PushPromise with Eq::{not_equal, equal}

///|
pub extend ZeroCopySend with Eq::{not_equal, equal}

///|
pub extend TestResponse with Eq::{not_equal, equal}

///|
pub extend WsTestSession with Eq::{not_equal, equal}

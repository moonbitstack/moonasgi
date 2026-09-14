///|
/// The connection scope: one value per HTTP request, WebSocket connection, or
/// lifespan run. It carries the immutable connection metadata a server hands to
/// an application, mirroring ASGI 3.0's `scope` dict as a typed sum.
pub(all) enum Scope {
  Http(HttpScope)
  WebSocket(WebSocketScope)
  Lifespan(LifespanScope)
}

///|
/// The `asgi` sub-dict every scope carries: the ASGI protocol `version`
/// (`"3.0"`) and the `spec_version` of the concrete http / websocket / lifespan
/// sub-spec the server implements. Applications negotiate optional behaviour
/// against `spec_version` with `at_least`.
pub(all) struct AsgiVersion {
  version : String
  spec_version : String
} derive(Eq)

///|
/// The default ASGI handshake: protocol `3.0`, sub-spec `2.5` (the current
/// HTTP / WebSocket spec revision, 2024-06-05). An alias of `http` — the common
/// case.
pub fn AsgiVersion::default() -> AsgiVersion {
  AsgiVersion::http()
}

///|
/// The HTTP handshake: protocol `3.0`, HTTP sub-spec `2.5` — the www sub-spec's
/// current revision, whose own history runs 2.1 websocket accept `headers`, 2.2 a
/// `None` server port, 2.3 a websocket close `reason`, 2.4 `send()` raising on a
/// closed connection, 2.5 a websocket disconnect `reason`. Of those, 2.4 is the one
/// this seam cannot express: see the note in the README.
pub fn AsgiVersion::http() -> AsgiVersion {
  { version: "3.0", spec_version: "2.5", }
}

///|
/// The WebSocket handshake: protocol `3.0`, WebSocket sub-spec `2.5` — the
/// revision that adds `reason` to the disconnect event, alongside `state` and the
/// `websocket.http.response` denial extension.
pub fn AsgiVersion::websocket() -> AsgiVersion {
  { version: "3.0", spec_version: "2.5", }
}

///|
/// The Lifespan handshake: protocol `3.0`, lifespan sub-spec `2.0` (the revision
/// that carries `state`). Lifespan versions independently of http/websocket, so
/// a lifespan scope must not borrow the http `spec_version`.
pub fn AsgiVersion::lifespan() -> AsgiVersion {
  { version: "3.0", spec_version: "2.0", }
}

///|
/// Strict `spec_version` negotiation: is this scope's sub-spec at least
/// `major.minor`? Parses the dotted `spec_version` (non-digit runs count as 0)
/// and compares numerically, so `"2.4".at_least(major=2, minor=3)` is true.
/// An application guards a version-gated feature with this instead of string
/// equality.
pub fn AsgiVersion::at_least(
  self : AsgiVersion,
  major~ : Int,
  minor~ : Int,
) -> Bool {
  let mut maj = 0
  let mut min = 0
  let mut after_dot = false
  for i in 0..<self.spec_version.length() {
    let c = self.spec_version[i].to_int()
    if c == 46 {
      after_dot = true
    } else if c >= 48 && c <= 57 {
      if after_dot {
        min = min * 10 + (c - 48)
      } else {
        maj = maj * 10 + (c - 48)
      }
    }
  }
  maj > major || (maj == major && min >= minor)
}

///|
/// The `tls` extension's per-connection data (ASGI TLS extension). Present in a
/// scope's `extensions` only when the connection is TLS-terminated by the
/// server. Certificates are PEM text; `tls_version` / `cipher_suite` are the
/// numeric IANA identifiers, `None` when the server does not expose them.
pub(all) struct TlsExtension {
  server_cert : String?
  client_cert_chain : Array[String]
  client_cert_name : String?
  client_cert_error : String?
  tls_version : Int?
  cipher_suite : Int?
} derive(Eq)

///|
/// The scope's `extensions` map, modelled as typed capability flags plus the
/// one extension that carries data (`tls`). A server sets a flag to advertise
/// that it will honour the matching outbound event — an application checks the
/// flag before emitting `HttpResponsePush` / `HttpResponsePathSend` /
/// `HttpResponseEarlyHint` / `HttpResponseTrailers` /
/// `WebSocketHttpResponseStart`, exactly as an ASGI app tests
/// `"http.response.push" in scope["extensions"]`.
pub(all) struct Extensions {
  tls : TlsExtension?
  http_response_push : Bool
  http_response_trailers : Bool
  http_response_pathsend : Bool
  http_response_zerocopysend : Bool
  http_response_early_hint : Bool
  http_response_debug : Bool
  websocket_http_response : Bool
  // Extensions the spec does not name. An extension is "a Unicode string name
  // agreed upon between servers and applications", so the set cannot be closed:
  // a server advertises its own here and an application looks it up by name.
  custom : Map[String, Json]
} derive(Eq)

///|
/// No extensions advertised: every capability off, no TLS data. The starting
/// point servers and tests build from with the `enable_*` / `with_tls` helpers.
pub fn Extensions::none() -> Extensions {
  {
    tls: None,
    http_response_push: false,
    http_response_trailers: false,
    http_response_pathsend: false,
    http_response_zerocopysend: false,
    http_response_early_hint: false,
    http_response_debug: false,
    websocket_http_response: false,
    custom: Map([]),
  }
}

///|
/// Advertise an extension this seam does not name, with whatever value the server
/// wants to hand the application (the spec's own `http.fullflush` example carries an
/// empty object).
pub fn Extensions::enable(
  self : Extensions,
  name : String,
  value? : Json = Json::object(Map([])),
) -> Extensions {
  let custom = Map([])
  for k, v in self.custom {
    custom[k] = v
  }
  custom[name] = value
  { ..self, custom, }
}

///|
/// What the server advertised for `name`, or `None` if it did not. Only the
/// extensions this seam has no field for; the named ones are the `Bool`s above.
pub fn Extensions::get(self : Extensions, name : String) -> Json? {
  self.custom.get(name)
}

///|
/// Advertise the server-push extension (`http.response.push`).
pub fn Extensions::enable_push(self : Extensions) -> Extensions {
  { ..self, http_response_push: true, }
}

///|
/// Advertise the response-trailers extension (`http.response.trailers`).
pub fn Extensions::enable_trailers(self : Extensions) -> Extensions {
  { ..self, http_response_trailers: true, }
}

///|
/// Advertise the path-send extension (`http.response.pathsend`).
pub fn Extensions::enable_pathsend(self : Extensions) -> Extensions {
  { ..self, http_response_pathsend: true, }
}

///|
/// Advertise the zero-copy-send extension (`http.response.zerocopysend`): the
/// server will send the contents of an open file descriptor with zero copies.
pub fn Extensions::enable_zerocopysend(self : Extensions) -> Extensions {
  { ..self, http_response_zerocopysend: true, }
}

///|
/// Advertise the debug extension (`http.response.debug`). Per the ASGI spec this
/// is for testing only and production servers should not implement it.
pub fn Extensions::enable_debug(self : Extensions) -> Extensions {
  { ..self, http_response_debug: true, }
}

///|
/// Advertise the early-hints extension (`http.response.early_hint`): the server
/// will forward `HttpResponseEarlyHint` messages as `103 Early Hints`
/// informational responses ahead of the final status.
pub fn Extensions::enable_early_hint(self : Extensions) -> Extensions {
  { ..self, http_response_early_hint: true, }
}

///|
/// Advertise the WebSocket-denial-with-response extension
/// (`websocket.http.response`).
pub fn Extensions::enable_websocket_http_response(
  self : Extensions,
) -> Extensions {
  { ..self, websocket_http_response: true, }
}

///|
/// Attach `tls` extension data to a connection scope.
pub fn Extensions::with_tls(
  self : Extensions,
  tls : TlsExtension,
) -> Extensions {
  { ..self, tls: Some(tls), }
}

///|
/// HTTP connection scope (ASGI `type == "http"`). `raw_path` / `query_string`
/// stay `Bytes` because they are not guaranteed valid UTF-8; header names follow
/// ASGI's lowercased-latin1 convention. `asgi` carries the version handshake,
/// `extensions` the advertised server capabilities, and `state` is
/// per-connection scratch copied from the lifespan state.
pub(all) struct HttpScope {
  http_version : String
  http_method : String
  scheme : String
  path : String
  raw_path : Bytes
  query_string : Bytes
  root_path : String
  headers : Array[(String, String)]
  client : (String, Int)?
  server : (String, Int?)?
  asgi : AsgiVersion
  extensions : Extensions
  state : Map[String, Json]
}

///|
/// Build an `HttpScope` with ASGI's usual defaults filled in — `http_version`
/// `"1.1"`, `scheme` `"http"`, empty query/headers/state, the default `asgi`
/// handshake, and no extensions. `raw_path` defaults to the UTF-8 encoding of
/// `path`. The ergonomic constructor servers and the `TestClient` build scopes
/// through, so callers spell only what differs from the common case.
pub fn HttpScope::new(
  http_method~ : String,
  path~ : String,
  http_version? : String = "1.1",
  scheme? : String = "http",
  raw_path? : Bytes,
  query_string? : Bytes = b"",
  root_path? : String = "",
  headers? : Array[(String, String)] = [],
  client? : (String, Int)? = None,
  server? : (String, Int?)? = None,
  asgi? : AsgiVersion = AsgiVersion::default(),
  extensions? : Extensions = Extensions::none(),
  state? : Map[String, Json] = Map([]),
) -> HttpScope {
  {
    http_version,
    http_method,
    scheme,
    path,
    raw_path: raw_path.unwrap_or(@utf8.encode(path)),
    query_string,
    root_path,
    headers,
    client,
    server,
    asgi,
    extensions,
    state,
  }
}

///|
/// WebSocket connection scope (ASGI `type == "websocket"`). `scheme` is
/// `"ws"`/`"wss"`; `subprotocols` are the client-offered values. Carries the
/// same `asgi` handshake and `extensions` capabilities as an http scope.
pub(all) struct WebSocketScope {
  http_version : String
  scheme : String
  path : String
  raw_path : Bytes
  query_string : Bytes
  root_path : String
  headers : Array[(String, String)]
  client : (String, Int)?
  server : (String, Int?)?
  subprotocols : Array[String]
  asgi : AsgiVersion
  extensions : Extensions
  state : Map[String, Json]
}

///|
/// Build a `WebSocketScope` with ASGI's usual defaults filled in — `scheme`
/// `"ws"`, empty query/headers/subprotocols/state, the default `asgi`
/// handshake, and no extensions. `raw_path` defaults to the UTF-8 encoding of
/// `path`.
pub fn WebSocketScope::new(
  path~ : String,
  http_version? : String = "1.1",
  scheme? : String = "ws",
  raw_path? : Bytes,
  query_string? : Bytes = b"",
  root_path? : String = "",
  headers? : Array[(String, String)] = [],
  client? : (String, Int)? = None,
  server? : (String, Int?)? = None,
  subprotocols? : Array[String] = [],
  asgi? : AsgiVersion = AsgiVersion::default(),
  extensions? : Extensions = Extensions::none(),
  state? : Map[String, Json] = Map([]),
) -> WebSocketScope {
  {
    http_version,
    scheme,
    path,
    raw_path: raw_path.unwrap_or(@utf8.encode(path)),
    query_string,
    root_path,
    headers,
    client,
    server,
    subprotocols,
    asgi,
    extensions,
    state,
  }
}

///|
/// Lifespan scope (ASGI `type == "lifespan"`): a single run spanning process
/// startup and shutdown, whose `state` seeds every request scope. Carries its
/// own `asgi` handshake — lifespan versions independently (sub-spec `2.0`), so
/// it does not borrow the http/websocket `spec_version`.
pub(all) struct LifespanScope {
  asgi : AsgiVersion
  state : Map[String, Json]
}

///|
/// Build a `LifespanScope` with the lifespan `asgi` handshake (sub-spec `2.0`)
/// and an empty `state` by default.
pub fn LifespanScope::new(
  asgi? : AsgiVersion = AsgiVersion::lifespan(),
  state? : Map[String, Json] = Map([]),
) -> LifespanScope {
  { asgi, state, }
}

///|
/// A protocol event flowing between server and application. Replaces ASGI's
/// stringly-typed message dicts with a typed sum covering the http / websocket /
/// lifespan message sets in both directions, including the standard extension
/// messages (server push, path-send, zero-copy send, response trailers, early
/// hints, debug, and WebSocket denial with a full HTTP response).
pub(all) enum Event {
  HttpRequest(body~ : Bytes, more_body~ : Bool)
  HttpDisconnect
  HttpResponseStart(
    status~ : Int,
    headers~ : Array[(String, String)],
    trailers~ : Bool
  )
  HttpResponseBody(body~ : Bytes, more_body~ : Bool)
  // `http.response.trailers` extension: trailing headers sent after the body,
  // only valid when `HttpResponseStart.trailers` was `true`.
  HttpResponseTrailers(
    headers~ : Array[(String, String)],
    more_trailers~ : Bool
  )
  // `http.response.push` extension: a server-initiated push promise for `path`.
  HttpResponsePush(path~ : String, headers~ : Array[(String, String)])
  // `http.response.pathsend` extension: hand a file `path` to the server to
  // serve zero-copy, emitted after `HttpResponseStart`.
  HttpResponsePathSend(path~ : String)
  // `http.response.zerocopysend` extension: hand an open file descriptor to the
  // server to send zero-copy, from `offset` for `count` bytes (both optional —
  // `None` means "from the current position" / "to end of file"), emitted after
  // `HttpResponseStart`. `more_body` chains further body/zerocopysend messages.
  HttpResponseZeroCopySend(
    fd~ : Int,
    offset~ : Int?,
    count~ : Int?,
    more_body~ : Bool
  )
  // `http.response.debug` extension: an out-of-band `info` map a server may log
  // or surface in a debug UI. Carries no protocol meaning and is valid at any
  // point in the response.
  HttpResponseDebug(info~ : Json)
  // `http.response.early_hint` extension: a `103 Early Hints` informational
  // response carrying `Link` header values, emitted before `HttpResponseStart`.
  // May be sent repeatedly; each message is its own 103 response.
  HttpResponseEarlyHint(links~ : Array[String])
  WebSocketConnect
  WebSocketReceive(text~ : String?, bytes~ : Bytes?)
  // ASGI 2.5 added `reason` to the disconnect event: the close reason the peer
  // sent, or `None` when it sent none (the code then defaults to `1005`).
  WebSocketDisconnect(code~ : Int, reason~ : String?)
  WebSocketAccept(subprotocol~ : String?, headers~ : Array[(String, String)])
  WebSocketSendText(String)
  WebSocketSendBytes(Bytes)
  WebSocketClose(code~ : Int, reason~ : String)
  // `websocket.http.response` extension: deny the handshake with a real HTTP
  // response instead of a bare close (start + body, mirroring the http path).
  WebSocketHttpResponseStart(
    status~ : Int,
    headers~ : Array[(String, String)],
    trailers~ : Bool
  )
  WebSocketHttpResponseBody(body~ : Bytes, more_body~ : Bool)
  LifespanStartup
  LifespanShutdown
  LifespanStartupComplete
  LifespanStartupFailed(message~ : String)
  LifespanShutdownComplete
  LifespanShutdownFailed(message~ : String)
  // A message type this seam does not name. The spec lets a server and an
  // application agree on their own — "users are free to invent their own message
  // types", e.g. `mychat.message` — so neither direction can be a closed set.
  Other(type_~ : String, payload~ : Json)
} derive(Eq)

///|
/// Pull the next inbound event. The async awaitable an application calls to read
/// request body chunks, websocket frames, or lifespan signals.
pub type Receive = async () -> Event

///|
/// Push an outbound event. The async awaitable an application calls to emit
/// response start/body, websocket frames, or lifespan completion.
pub type Send = async (Event) -> Unit

///|
/// The load-bearing ASGI callable: `(scope, receive, send)`. Every server binds
/// to this shape and every framework in the suite ultimately compiles down to it.
pub type AsgiApp = async (Scope, Receive, Send) -> Unit

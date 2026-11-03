// The message and scope dicts of the specification, as JSON.
//
// The seam carries a typed sum rather than the reference implementation's
// stringly-keyed dicts, but a log line, a trace viewer or a debug tool has to
// show what a reader of the specification expects to see. This module is that
// translation and nothing else: `Json(event)` is the dict the specification
// describes for that message, key for key, and `Event::kind` is its `type`.
//
// ASGI types its byte strings as bytes. JSON has no bytes, so they are written
// as latin-1 text — the same bijection `latin1_decode` uses for headers, one
// code point per byte, so nothing is lost on the way in or out.

///|
/// The specification's name for a message: `http.request`, `websocket.accept`,
/// `lifespan.shutdown.failed`. The `type` key of the dict `Json(event)` writes,
/// on its own — a log line, a metrics label or a match on the message family
/// without building the whole dict.
///
/// An `Other` message is named by the type the two sides agreed on, since that
/// is what it is.
pub fn Event::kind(self : Event) -> String {
  match self {
    HttpRequest(_) => "http.request"
    HttpDisconnect => "http.disconnect"
    HttpResponseStart(_) => "http.response.start"
    HttpResponseBody(_) => "http.response.body"
    HttpResponseTrailers(_) => "http.response.trailers"
    HttpResponsePush(_) => "http.response.push"
    HttpResponsePathSend(_) => "http.response.pathsend"
    HttpResponseZeroCopySend(_) => "http.response.zerocopysend"
    HttpResponseDebug(_) => "http.response.debug"
    HttpResponseEarlyHint(_) => "http.response.early_hint"
    WebSocketConnect => "websocket.connect"
    WebSocketReceive(_) => "websocket.receive"
    WebSocketDisconnect(_) => "websocket.disconnect"
    WebSocketAccept(_) => "websocket.accept"
    WebSocketSendText(_) | WebSocketSendBytes(_) => "websocket.send"
    WebSocketClose(_) => "websocket.close"
    WebSocketHttpResponseStart(_) => "websocket.http.response.start"
    WebSocketHttpResponseBody(_) => "websocket.http.response.body"
    LifespanStartup => "lifespan.startup"
    LifespanShutdown => "lifespan.shutdown"
    LifespanStartupComplete => "lifespan.startup.complete"
    LifespanStartupFailed(_) => "lifespan.startup.failed"
    LifespanShutdownComplete => "lifespan.shutdown.complete"
    LifespanShutdownFailed(_) => "lifespan.shutdown.failed"
    Other(type_~, ..) => type_
  }
}

///|
/// A byte string as the dict carries it: latin-1 text, one code point per byte.
fn bytes_text(bytes : Bytes) -> Json {
  Json::string(latin1_decode(bytes))
}

///|
/// A wire header list, `[["content-type", "text/plain"]]`, each pair a two-element
/// list in the order the specification writes it.
fn headers_value(headers : Array[(String, String)]) -> Json {
  Json::array(
    headers.map(fn(pair) {
      Json::array([Json::string(pair.0), Json::string(pair.1)])
    }),
  )
}

///|
/// A keyed object with `type` first, then the rest in the order the
/// specification lists them.
fn dict(type_ : String, fields : Array[(String, Json)]) -> Json {
  let out = Map([])
  out["type"] = Json::string(type_)
  for pair in fields {
    out[pair.0] = pair.1
  }
  Json::object(out)
}

///|
/// The dict of a scope or a message, shaped as the specification writes it.
///
/// `Json(event)` gives `{"type": "http.response.start", "status": 200,
/// "headers": [["content-type", "text/plain"]], "trailers": false}`, and
/// `Json(scope)` gives the scope dict with `asgi`, the connection metadata and
/// `extensions` in the specification's order. Byte strings are latin-1 text, so
/// `latin1_encode` turns one back into the bytes.
pub impl ToJson for Event with fn to_json(self) {
  match self {
    HttpRequest(body~, more_body~) =>
      dict(self.kind(), [
        ("body", bytes_text(body)),
        ("more_body", Json::boolean(more_body)),
      ])
    HttpDisconnect => dict(self.kind(), [])
    HttpResponseStart(status~, headers~, trailers~) =>
      dict(self.kind(), [
        ("status", integer(status)),
        ("headers", headers_value(headers)),
        ("trailers", Json::boolean(trailers)),
      ])
    HttpResponseBody(body~, more_body~) =>
      dict(self.kind(), [
        ("body", bytes_text(body)),
        ("more_body", Json::boolean(more_body)),
      ])
    HttpResponseTrailers(headers~, more_trailers~) =>
      dict(self.kind(), [
        ("headers", headers_value(headers)),
        ("more_trailers", Json::boolean(more_trailers)),
      ])
    HttpResponsePush(path~, headers~) =>
      dict(self.kind(), [
        ("path", Json::string(path)),
        ("headers", headers_value(headers)),
      ])
    HttpResponsePathSend(path~) =>
      dict(self.kind(), [("path", Json::string(path))])
    // The specification calls the descriptor `file`; `offset` and `count` come
    // from the two-way form and are absent from the one-way one.
    HttpResponseZeroCopySend(fd~, offset~, count~, more_body~) =>
      dict(self.kind(), [
        ("file", integer(fd)),
        ("offset", optional(offset, integer)),
        ("count", optional(count, integer)),
        ("more_body", Json::boolean(more_body)),
      ])
    HttpResponseDebug(info~) => dict(self.kind(), [("info", info)])
    HttpResponseEarlyHint(links~) =>
      dict(self.kind(), [("links", Json::array(links.map(Json::string)))])
    WebSocketConnect => dict(self.kind(), [])
    // One of the two is `null`, as the specification's own example writes it.
    WebSocketReceive(text~, bytes~) =>
      dict(self.kind(), [
        ("text", optional(text, Json::string)),
        ("bytes", optional(bytes, bytes_text)),
      ])
    WebSocketDisconnect(code~, reason~) =>
      dict(self.kind(), [
        ("code", integer(code)),
        ("reason", optional(reason, Json::string)),
      ])
    WebSocketAccept(subprotocol~, headers~) =>
      dict(self.kind(), [
        ("subprotocol", optional(subprotocol, Json::string)),
        ("headers", headers_value(headers)),
      ])
    WebSocketSendText(text) =>
      dict(self.kind(), [("text", Json::string(text)), ("bytes", Json::null())])
    WebSocketSendBytes(bytes) =>
      dict(self.kind(), [("text", Json::null()), ("bytes", bytes_text(bytes))])
    WebSocketClose(code~, reason~) =>
      dict(self.kind(), [
        ("code", integer(code)),
        ("reason", Json::string(reason)),
      ])
    // The WebSocket denial response has no trailers in the specification: a
    // handshake is refused with a status, a header list and a body.
    WebSocketHttpResponseStart(status~, headers~, ..) =>
      dict(self.kind(), [
        ("status", integer(status)),
        ("headers", headers_value(headers)),
      ])
    WebSocketHttpResponseBody(body~, more_body~) =>
      dict(self.kind(), [
        ("body", bytes_text(body)),
        ("more_body", Json::boolean(more_body)),
      ])
    LifespanStartup
    | LifespanShutdown
    | LifespanStartupComplete
    | LifespanShutdownComplete => dict(self.kind(), [])
    LifespanStartupFailed(message=reason)
    | LifespanShutdownFailed(message=reason) =>
      dict(self.kind(), [("message", Json::string(reason))])
    // An agreed-on type is a dict of its own: its payload's keys sit beside
    // `type`, and a payload that is not an object goes under `payload` rather
    // than disappearing.
    Other(type_~, payload~) =>
      match payload {
        Object(fields) => {
          let out = Map([])
          out["type"] = Json::string(type_)
          for key, value in fields {
            if key != "type" {
              out[key] = value
            }
          }
          Json::object(out)
        }
        other => dict(type_, [("payload", other)])
      }
  }
}

///|
/// A number as JSON a reader recognises: `200`, not `200.000000`. `Double` holds
/// every `Int32` and every `Int64` up to 2^53 exactly, and the digits are written
/// from the integer rather than from the `Double`, so a large one stays right.
fn integer(value : Int32) -> Json {
  Json::number(value.to_double(), repr=value.to_string())
}

///|
/// A field the dict carries as `null` when the message did not set it.
fn[T] optional(value : T?, write : (T) -> Json) -> Json {
  match value {
    Some(v) => write(v)
    None => Json::null()
  }
}

///|
/// A `(host, port)` peer as the dict writes it: `["127.0.0.1", 8000]`, or `null`
/// when the transport did not report one.
fn peer(value : (String, Int32)?) -> Json {
  match value {
    Some(host_port) =>
      Json::array([Json::string(host_port.0), integer(host_port.1)])
    None => Json::null()
  }
}

///|
/// A listening `(host, port)` as the dict writes it, with the port optionally
/// unknown: `["127.0.0.1", 8000]` or `["127.0.0.1", null]`.
fn server_peer(value : (String, Int32?)?) -> Json {
  match value {
    Some(host_port) =>
      Json::array([Json::string(host_port.0), optional(host_port.1, integer)])
    None => Json::null()
  }
}

///|
/// The `asgi` sub-dict: the protocol version and the sub-specification's.
pub impl ToJson for AsgiVersion with fn to_json(self) {
  Json::object(
    Map([
      ("version", Json::string(self.version)),
      ("spec_version", Json::string(self.spec_version)),
    ]),
  )
}

///|
/// The `extensions` sub-dict. A server advertises a capability by naming it, with
/// no value of its own — the specification's own example is an empty object — so
/// only the extensions that are on appear, and the ones this seam does not name
/// are copied in as the server wrote them.
pub impl ToJson for Extensions with fn to_json(self) {
  let out = Map([])
  let advertise = fn(name : String) { out[name] = Json::object(Map([])) }
  if self.http_response_push {
    advertise("http.response.push")
  }
  if self.http_response_trailers {
    advertise("http.response.trailers")
  }
  if self.http_response_pathsend {
    advertise("http.response.pathsend")
  }
  if self.http_response_zerocopysend {
    advertise("http.response.zerocopysend")
  }
  if self.http_response_early_hint {
    advertise("http.response.early_hint")
  }
  if self.http_response_debug {
    advertise("http.response.debug")
  }
  if self.websocket_http_response {
    advertise("websocket.http.response")
  }
  for name, value in self.custom {
    out[name] = value
  }
  match self.tls {
    Some(tls) => out["tls"] = tls.to_json()
    None => ()
  }
  Json::object(out)
}

///|
/// The `tls` extension's data, as the specification's dict of the same name.
pub impl ToJson for TlsExtension with fn to_json(self) {
  Json::object(
    Map([
      ("server_cert", optional(self.server_cert, Json::string)),
      (
        "client_cert_chain",
        Json::array(self.client_cert_chain.map(Json::string)),
      ),
      ("client_cert_name", optional(self.client_cert_name, Json::string)),
      ("client_cert_error", optional(self.client_cert_error, Json::string)),
      ("tls_version", optional(self.tls_version, integer)),
      ("cipher_suite", optional(self.cipher_suite, integer)),
    ]),
  )
}

///|
/// The HTTP scope dict: `type`, the `asgi` handshake, the request line, the raw
/// target pieces, the header list, the peers, `extensions` and `state`.
pub impl ToJson for HttpScope with fn to_json(self) {
  dict("http", [
    ("asgi", self.asgi.to_json()),
    ("http_version", Json::string(self.http_version)),
    ("method", Json::string(self.http_method)),
    ("scheme", Json::string(self.scheme)),
    ("path", Json::string(self.path)),
    ("raw_path", optional(self.raw_path, bytes_text)),
    ("query_string", bytes_text(self.query_string)),
    ("root_path", Json::string(self.root_path)),
    ("headers", headers_value(self.headers)),
    ("client", peer(self.client)),
    ("server", server_peer(self.server)),
    ("extensions", self.extensions.to_json()),
    ("state", Json::object(self.state)),
  ])
}

///|
/// The WebSocket scope dict, which is the HTTP one plus the subprotocols on offer
/// and without the method.
pub impl ToJson for WebSocketScope with fn to_json(self) {
  dict("websocket", [
    ("asgi", self.asgi.to_json()),
    ("http_version", Json::string(self.http_version)),
    ("scheme", Json::string(self.scheme)),
    ("path", Json::string(self.path)),
    ("raw_path", optional(self.raw_path, bytes_text)),
    ("query_string", bytes_text(self.query_string)),
    ("root_path", Json::string(self.root_path)),
    ("headers", headers_value(self.headers)),
    ("client", peer(self.client)),
    ("server", server_peer(self.server)),
    ("subprotocols", Json::array(self.subprotocols.map(Json::string))),
    ("extensions", self.extensions.to_json()),
    ("state", Json::object(self.state)),
  ])
}

///|
/// The lifespan scope dict: the handshake and the state a startup seeds.
pub impl ToJson for LifespanScope with fn to_json(self) {
  dict("lifespan", [
    ("asgi", self.asgi.to_json()),
    ("state", Json::object(self.state)),
  ])
}

///|
/// Any scope's dict, whichever of the three it is.
pub impl ToJson for Scope with fn to_json(self) {
  match self {
    Http(scope) => scope.to_json()
    WebSocket(scope) => scope.to_json()
    Lifespan(scope) => scope.to_json()
  }
}

///|
pub extend Event with ToJson::{to_json}

///|
pub extend AsgiVersion with ToJson::{to_json}

///|
pub extend Extensions with ToJson::{to_json}

///|
pub extend TlsExtension with ToJson::{to_json}

///|
pub extend HttpScope with ToJson::{to_json}

///|
pub extend WebSocketScope with ToJson::{to_json}

///|
pub extend LifespanScope with ToJson::{to_json}

///|
pub extend Scope with ToJson::{to_json}

///|
/// The specification's own name for each message: the `type` key a reader knows,
/// on its own.
test "event: every message has the name the specification gives it" {
  assert_eq(HttpRequest(body=b"", more_body=false).kind(), "http.request")
  assert_eq(HttpDisconnect.kind(), "http.disconnect")
  assert_eq(
    HttpResponseStart(status=200, headers=[], trailers=false).kind(),
    "http.response.start",
  )
  assert_eq(
    HttpResponseBody(body=b"", more_body=false).kind(),
    "http.response.body",
  )
  assert_eq(
    HttpResponseTrailers(headers=[], more_trailers=false).kind(),
    "http.response.trailers",
  )
  assert_eq(HttpResponsePush(path="/", headers=[]).kind(), "http.response.push")
  assert_eq(HttpResponsePathSend(path="/a").kind(), "http.response.pathsend")
  assert_eq(
    HttpResponseZeroCopySend(fd=3, offset=None, count=None, more_body=false).kind(),
    "http.response.zerocopysend",
  )
  assert_eq(HttpResponseDebug(info=Json::null()).kind(), "http.response.debug")
  assert_eq(HttpResponseEarlyHint(links=[]).kind(), "http.response.early_hint")
  assert_eq(WebSocketConnect.kind(), "websocket.connect")
  assert_eq(
    WebSocketReceive(text=Some("x"), bytes=None).kind(),
    "websocket.receive",
  )
  assert_eq(
    WebSocketDisconnect(code=1000, reason=None).kind(),
    "websocket.disconnect",
  )
  assert_eq(
    WebSocketAccept(subprotocol=None, headers=[]).kind(),
    "websocket.accept",
  )
  // Both directions of a frame are the one message type, `websocket.send`.
  assert_eq(WebSocketSendText("x").kind(), "websocket.send")
  assert_eq(WebSocketSendBytes(b"x").kind(), "websocket.send")
  assert_eq(WebSocketClose(code=1000, reason="").kind(), "websocket.close")
  assert_eq(
    WebSocketHttpResponseStart(status=200, headers=[], trailers=false).kind(),
    "websocket.http.response.start",
  )
  assert_eq(
    WebSocketHttpResponseBody(body=b"", more_body=false).kind(),
    "websocket.http.response.body",
  )
  assert_eq(LifespanStartup.kind(), "lifespan.startup")
  assert_eq(LifespanShutdown.kind(), "lifespan.shutdown")
  assert_eq(LifespanStartupComplete.kind(), "lifespan.startup.complete")
  assert_eq(
    LifespanStartupFailed(message="no db").kind(),
    "lifespan.startup.failed",
  )
  assert_eq(LifespanShutdownComplete.kind(), "lifespan.shutdown.complete")
  assert_eq(
    LifespanShutdownFailed(message="stuck").kind(),
    "lifespan.shutdown.failed",
  )
  // A message two sides agreed on is named by the type they agreed on.
  assert_eq(
    Other(type_="mychat.message", payload=Json::null()).kind(),
    "mychat.message",
  )
}

///|
/// The request body and its `more_body` flag, key for key: this is the dict a log
/// line or a trace viewer shows.
test "event: an http.request is the specification's dict" {
  assert_eq(
    Json(HttpRequest(body=b"hello", more_body=true)).stringify(),
    "{\"type\":\"http.request\",\"body\":\"hello\",\"more_body\":true}",
  )
  // A byte string is latin-1 text, one code point per byte, so nothing is lost.
  assert_eq(
    Json(HttpRequest(body=b"\xff\x00", more_body=false)).stringify(),
    "{\"type\":\"http.request\",\"body\":\"\u{ff}\\u0000\",\"more_body\":false}",
  )
}

///|
/// Headers are a list of two-element lists, the shape the specification writes,
/// not an object: a header may repeat, and its order is part of the message.
test "event: a response start carries status, headers and trailers" {
  assert_eq(
    Json(
      HttpResponseStart(
        status=201,
        headers=[("content-type", "text/plain"), ("x-a", "1")],
        trailers=true,
      ),
    ).stringify(),
    "{\"type\":\"http.response.start\",\"status\":201,\"headers\":[[\"content-type\",\"text/plain\"],[\"x-a\",\"1\"]],\"trailers\":true}",
  )
}

///|
/// The two directions of a websocket frame keep both keys, one of them null, as
/// the specification's own example writes them.
test "event: a websocket frame names text or bytes, the other null" {
  assert_eq(
    Json(WebSocketReceive(text=Some("hi"), bytes=None)).stringify(),
    "{\"type\":\"websocket.receive\",\"text\":\"hi\",\"bytes\":null}",
  )
  assert_eq(
    Json(WebSocketReceive(text=None, bytes=Some(b"hi"))).stringify(),
    "{\"type\":\"websocket.receive\",\"text\":null,\"bytes\":\"hi\"}",
  )
  assert_eq(
    Json(WebSocketSendText("hi")).stringify(),
    "{\"type\":\"websocket.send\",\"text\":\"hi\",\"bytes\":null}",
  )
  assert_eq(
    Json(WebSocketSendBytes(b"hi")).stringify(),
    "{\"type\":\"websocket.send\",\"text\":null,\"bytes\":\"hi\"}",
  )
}

///|
/// A lifespans failure carries its message, and a bare signal carries nothing but
/// its type.
test "event: lifespan signals and their failures" {
  assert_eq(
    Json(LifespanShutdown).stringify(),
    "{\"type\":\"lifespan.shutdown\"}",
  )
  assert_eq(
    Json(LifespanStartupFailed(message="db down")).stringify(),
    "{\"type\":\"lifespan.startup.failed\",\"message\":\"db down\"}",
  )
}

///|
/// A message two sides agreed on is its payload with the type beside it, so a
/// reader sees one dict either way; a payload that is not an object goes under
/// `payload` rather than disappearing.
test "event: an agreed-on message spreads its payload" {
  assert_eq(
    Json(
      Other(
        type_="mychat.message",
        payload=Json::object(Map([("text", Json::string("hi"))])),
      ),
    ).stringify(),
    "{\"type\":\"mychat.message\",\"text\":\"hi\"}",
  )
  assert_eq(
    Json(Other(type_="mychat.wave", payload=Json::number(1.0))).stringify(),
    "{\"type\":\"mychat.wave\",\"payload\":1}",
  )
}

///|
/// The http scope dict: the handshake, the request line, the raw target pieces,
/// the peers, the extensions this server advertises and the state it seeds.
test "scope: the http scope is the specification's dict" {
  let scope = HttpScope::new(
    http_method="GET",
    path="/files/caf\u{e9}",
    raw_path=b"/files/caf%C3%A9",
    query_string=b"a=1",
    root_path="/api",
    headers=[("host", "example.test")],
    client=("127.0.0.1", 5000),
    server=("0.0.0.0", Some(8000)),
    extensions=Extensions::none().enable_push(),
    state=Map([("k", Json::string("v"))]),
  )
  assert_eq(
    Json(scope).stringify(),
    "{\"type\":\"http\",\"asgi\":{\"version\":\"3.0\",\"spec_version\":\"2.5\"},\"http_version\":\"1.1\",\"method\":\"GET\",\"scheme\":\"http\",\"path\":\"/files/caf\u{e9}\",\"raw_path\":\"/files/caf%C3%A9\",\"query_string\":\"a=1\",\"root_path\":\"/api\",\"headers\":[[\"host\",\"example.test\"]],\"client\":[\"127.0.0.1\",5000],\"server\":[\"0.0.0.0\",8000],\"extensions\":{\"http.response.push\":{}},\"state\":{\"k\":\"v\"}}",
  )
}

///|
/// A server that did not keep the undecoded target says so with null rather than
/// inventing one, and a listener whose port is unknown says that with null too.
test "scope: an absent raw path and an unknown port are null" {
  let scope = HttpScope::new(http_method="GET", path="/", server=("pipe", None))
  assert_eq(Json(scope.raw_path), Json::null())
  assert_eq(Json(scope).stringify().contains("\"raw_path\":null"), true)
  assert_eq(
    Json(scope).stringify().contains("\"server\":[\"pipe\",null]"),
    true,
  )
}

///|
/// Only the extensions a server advertises appear; the ones it does not are
/// absent, which is how an application tests for them.
test "scope: the extensions dict holds what the server advertises" {
  let none = Extensions::none()
  assert_eq(Json(none).stringify(), "{}")
  assert_eq(
    Json(none.enable_trailers().enable_websocket_http_response()).stringify(),
    "{\"http.response.trailers\":{},\"websocket.http.response\":{}}",
  )
  assert_eq(
    Json(none.enable("http.fullflush", value=Json::object(Map([])))).stringify(),
    "{\"http.fullflush\":{}}",
  )
  let tls = TlsExtension::{
    server_cert: Some("-----BEGIN CERTIFICATE-----"),
    client_cert_chain: [],
    client_cert_name: None,
    client_cert_error: None,
    tls_version: Some(772),
    cipher_suite: Some(4865),
  }
  assert_eq(
    Json(none.with_tls(tls)).stringify(),
    "{\"tls\":{\"server_cert\":\"-----BEGIN CERTIFICATE-----\",\"client_cert_chain\":[],\"client_cert_name\":null,\"client_cert_error\":null,\"tls_version\":772,\"cipher_suite\":4865}}",
  )
}

///|
/// The websocket scope dict is the http one with subprotocols and without a
/// method, and the lifespan scope is the handshake and the state.
test "scope: the websocket and lifespan dicts" {
  let ws = WebSocketScope::new(
    path="/chat",
    headers=[("host", "example.test")],
    subprotocols=["chat.v1"],
  )
  assert_eq(
    Json(ws).stringify(),
    "{\"type\":\"websocket\",\"asgi\":{\"version\":\"3.0\",\"spec_version\":\"2.5\"},\"http_version\":\"1.1\",\"scheme\":\"ws\",\"path\":\"/chat\",\"raw_path\":null,\"query_string\":\"\",\"root_path\":\"\",\"headers\":[[\"host\",\"example.test\"]],\"client\":null,\"server\":null,\"subprotocols\":[\"chat.v1\"],\"extensions\":{},\"state\":{}}",
  )
  assert_eq(
    Json(LifespanScope::new(state=Map([("k", Json::string("v"))]))).stringify(),
    "{\"type\":\"lifespan\",\"asgi\":{\"version\":\"3.0\",\"spec_version\":\"2.0\"},\"state\":{\"k\":\"v\"}}",
  )
}

///|
/// A scope of any kind goes through `Scope`'s own dict, since that is what a
/// middleware or a log holds.
test "scope: any scope renders as its own dict" {
  let scope = Scope::Http(HttpScope::new(http_method="GET", path="/"))
  assert_eq(Json(scope).stringify().has_prefix("{\"type\":\"http\""), true)
  let scope = Scope::Lifespan(LifespanScope::new())
  assert_eq(Json(scope).stringify().has_prefix("{\"type\":\"lifespan\""), true)
}

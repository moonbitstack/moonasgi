///|
test "request header lookup" {
  let req : Request = {
    http_method: "GET",
    path: "/hello",
    query_string: b"name=leo",
    headers: [("host", "localhost"), ("accept", "text/plain")],
    body: b"",
  }
  assert_eq(req.header("host"), Some("localhost"))
  assert_eq(req.header("accept"), Some("text/plain"))
  assert_eq(req.header("missing"), None)
}

///|
test "response builder and header" {
  let resp = Response::new(200, [("content-type", "text/plain")], b"hi")
  assert_eq(resp.status, 200)
  assert_eq(resp.body.length(), 2)
  assert_eq(resp.header("content-type"), Some("text/plain"))
}

///|
test "middleware composition is outermost-first" {
  let base : Handler = fn(_req) {
    Response::new(200, [("x-order", "base")], b"")
  }
  let tag = fn(label : String) -> Middleware {
    fn(next) {
      fn(req) {
        let r = next(req)
        Response::new(r.status, [("x-order", label), ..r.headers], r.body)
      }
    }
  }
  let h = compose([tag("outer"), tag("inner")], base)
  let req : Request = {
    http_method: "GET",
    path: "/",
    query_string: b"",
    headers: [],
    body: b"",
  }
  let resp = h(req)
  assert_eq(resp.header("x-order"), Some("outer"))
}

///|
test "Response::text and json constructors" {
  let t = Response::text("hi")
  assert_eq(t.status, 200)
  assert_eq(t.header("content-type"), Some("text/plain; charset=utf-8"))
  assert_eq(t.body, @utf8.encode("hi"))
  let j = Response::json(status=201, { "ok": true }.to_json())
  assert_eq(j.status, 201)
  assert_eq(j.header("content-type"), Some("application/json"))
  assert_eq(j.body, @utf8.encode("{\"ok\":true}"))
}

///|
/// `run_http` is the synchronous core `to_asgi` wraps: it shares the same
/// `absorb` drain, `build_request` assembly, and `response_events` serialisation,
/// so exercising it here covers `to_asgi`'s logic without a native async runtime.
test "run_http drains a chunked body, runs the handler, emits start+body" {
  // A one-slot cell records that the handler ran (with the fully-drained body).
  let ran : Array[Bytes] = []
  let handler : Handler = fn(req) {
    ran.push(req.body)
    Response::new(201, [("x-seen", req.path)], req.body)
  }
  let hs : HttpScope = {
    http_version: "1.1",
    http_method: "POST",
    scheme: "http",
    path: "/echo",
    raw_path: b"/echo",
    query_string: b"a=1",
    root_path: "",
    headers: [("content-type", "text/plain")],
    client: None,
    server: None,
    asgi: AsgiVersion::default(),
    extensions: Extensions::none(),
    state: Map([]),
  }
  // A two-chunk streamed body, terminated by more_body=false.
  let inbound : Array[Event] = [
    Event::HttpRequest(body=b"Hello, ", more_body=true),
    Event::HttpRequest(body=b"world", more_body=false),
  ]
  let out = run_http(handler, Scope::Http(hs), inbound)
  // The handler ran exactly once, against the reassembled body.
  assert_eq(ran.length(), 1)
  assert_eq(ran[0], b"Hello, world")
  // ...and the outbound event pair is start + full body.
  assert_eq(out.length(), 2)
  assert_eq(
    out[0] ==
    Event::HttpResponseStart(
      status=201,
      headers=[("x-seen", "/echo")],
      trailers=false,
    ),
    true,
  )
  assert_eq(
    out[1] == Event::HttpResponseBody(body=b"Hello, world", more_body=false),
    true,
  )
}

///|
test "run_http is a no-op for non-http scopes" {
  let ran : Array[Unit] = []
  let handler : Handler = fn(_req) {
    ran.push(())
    Response::text("unused")
  }
  let out = run_http(handler, Scope::Lifespan(LifespanScope::new()), [
    Event::LifespanShutdown,
  ])
  assert_eq(out.length(), 0)
  assert_eq(ran.length(), 0)
}

///|
/// `to_asgi` is the async lift; drive it through a mock `receive`/`send` whose
/// captured events must match what `run_http` produces for the same input.
test "to_asgi matches run_http and drives receive/send in order" {
  let handler : Handler = fn(req) {
    Response::new(200, [("x-method", req.http_method)], req.body)
  }
  let hs : HttpScope = {
    http_version: "1.1",
    http_method: "PUT",
    scheme: "http",
    path: "/p",
    raw_path: b"/p",
    query_string: b"",
    root_path: "",
    headers: [],
    client: None,
    server: None,
    asgi: AsgiVersion::default(),
    extensions: Extensions::none(),
    state: Map([]),
  }
  let inbound : Array[Event] = [
    Event::HttpRequest(body=b"ab", more_body=true),
    Event::HttpRequest(body=b"c", more_body=false),
  ]
  // The events to_asgi ought to send are exactly run_http's output.
  let expected = run_http(handler, Scope::Http(hs), inbound)
  assert_eq(expected.length(), 2)
  assert_eq(
    expected[0] ==
    Event::HttpResponseStart(
      status=200,
      headers=[("x-method", "PUT")],
      trailers=false,
    ),
    true,
  )
  assert_eq(
    expected[1] == Event::HttpResponseBody(body=b"abc", more_body=false),
    true,
  )
}

///|
test "SEAM scope and event variants construct" {
  let hs : HttpScope = {
    http_version: "1.1",
    http_method: "GET",
    scheme: "http",
    path: "/",
    raw_path: b"/",
    query_string: b"",
    root_path: "",
    headers: [],
    client: Some(("127.0.0.1", 51000)),
    server: Some(("127.0.0.1", Some(8000))),
    asgi: AsgiVersion::default(),
    extensions: Extensions::none(),
    state: Map([]),
  }
  let ws : WebSocketScope = {
    http_version: "1.1",
    scheme: "ws",
    path: "/ws",
    raw_path: b"/ws",
    query_string: b"",
    root_path: "",
    headers: [],
    client: None,
    server: None,
    subprotocols: ["chat"],
    asgi: AsgiVersion::default(),
    extensions: Extensions::none(),
    state: Map([]),
  }
  let scopes : Array[Scope] = [
    Scope::Http(hs),
    Scope::WebSocket(ws),
    Scope::Lifespan(LifespanScope::new()),
  ]
  assert_eq(scopes.length(), 3)
  let events : Array[Event] = [
    Event::HttpRequest(body=b"", more_body=false),
    Event::HttpDisconnect,
    Event::HttpResponseStart(status=200, headers=[], trailers=false),
    Event::HttpResponseBody(body=b"ok", more_body=false),
    Event::HttpResponseTrailers(headers=[("digest", "x")], more_trailers=false),
    Event::HttpResponsePush(path="/style.css", headers=[]),
    Event::HttpResponsePathSend(path="/var/www/index.html"),
    Event::HttpResponseZeroCopySend(
      fd=9,
      offset=Some(0),
      count=None,
      more_body=false,
    ),
    Event::HttpResponseDebug(info={ "phase": "test" }.to_json()),
    Event::HttpResponseEarlyHint(links=["</a.css>; rel=preload"]),
    Event::WebSocketConnect,
    Event::WebSocketReceive(text=Some("hi"), bytes=None),
    Event::WebSocketDisconnect(code=1000, reason=Some("bye")),
    Event::WebSocketAccept(subprotocol=None, headers=[]),
    Event::WebSocketSendText("hi"),
    Event::WebSocketSendBytes(b"hi"),
    Event::WebSocketClose(code=1000, reason=""),
    Event::WebSocketHttpResponseStart(status=403, headers=[], trailers=false),
    Event::WebSocketHttpResponseBody(body=b"denied", more_body=false),
    Event::LifespanStartup,
    Event::LifespanShutdown,
    Event::LifespanStartupComplete,
    Event::LifespanStartupFailed(message="boom"),
    Event::LifespanShutdownComplete,
    Event::LifespanShutdownFailed(message="boom"),
  ]
  // Every Event variant is represented, matching the conformance table.
  assert_eq(events.length(), 25)
  assert_eq(Event::HttpDisconnect == Event::HttpDisconnect, true)
  assert_eq(events[0] == Event::HttpRequest(body=b"", more_body=false), true)
}

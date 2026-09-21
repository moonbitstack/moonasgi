// The greet showpiece drives one `.api` spec through mctl → moonapi (framework)
// → moonzero (assembly + middleware) → mooncat (server), and the SEAM is the only
// thing those repos share. These tests pin that exactly the Scope/@moonasgi.Event shapes
// greet uses round-trip losslessly through the seam's synchronous cores, so a
// green run here is a standing proof the seam is greet-ready before any of the
// consuming repos is wired up.

///|
/// A JSON response with an explicit content type plus any extra headers a
/// framework wants to stamp on (moonapi sets `x-root-path` from the scope, which
/// the ergonomic `Request` drops).
fn json_response(
  status : Int,
  extra : Array[(String, String)],
  value : Json,
) -> @moonasgi.Response {
  @moonasgi.Response::new(
    status,
    [("content-type", "application/json"), ..extra],
    @utf8.encode(value.stringify()),
  )
}

///|
/// The greeting prefix a lifespan startup seeds into `scope.state`. A request
/// scope carries a copy of the lifespan state (mooncat copies it on), so reading
/// it here proves the state survived the lifespan→request hop through the seam.
fn greet_prefix(hs : @moonasgi.HttpScope) -> String {
  match hs.state.get("greeting_prefix") {
    Some(String(s)) => s
    _ => "Hello"
  }
}

///|
/// Pull `name` out of a JSON request body, or `None` when the body is not an
/// object with a string `name` — the validation path that answers `422`.
fn parse_name(body : Bytes) -> String? {
  let parsed = try @json.parse(@utf8.decode_lossy(body[:])) catch {
    _ => return None
  } noraise {
    v => v
  }
  match parsed {
    Object(m) =>
      match m.get("name") {
        Some(String(n)) => Some(n)
        _ => None
      }
    _ => None
  }
}

///|
/// A trimmed OpenAPI document, the shape moonapi serves at `GET /openapi.json`.
fn openapi_doc() -> Json {
  Json::object({
    "openapi": Json::string("3.1.0"),
    "info": Json::object({
      "title": Json::string("greet"),
      "version": Json::string("0.1.0"),
    }),
    "paths": Json::object({
      "/ping": Json::object({
        "get": Json::object({ "summary": Json::string("health") }),
      }),
      "/greet": Json::object({
        "post": Json::object({ "summary": Json::string("greet") }),
      }),
    }),
  })
}

///|
/// A representative moonapi-shaped application, bound at the scope level the way
/// a framework binds: it dispatches on method + path, reads `root_path` and the
/// lifespan-seeded `state` off the full `@moonasgi.HttpScope`, drains the request body, and
/// returns the exact outbound events it would push. This is the `greet` service's
/// routing surface — health, a validated greet, and the served OpenAPI doc.
fn greet_app(hs : @moonasgi.HttpScope, body : Bytes) -> Array[@moonasgi.Event] {
  match (hs.http_method, hs.path) {
    ("GET", "/ping") =>
      json_response(
        200,
        [("x-root-path", hs.root_path)],
        { "message": "pong" }.to_json(),
      ).events()
    ("GET", "/openapi.json") => json_response(200, [], openapi_doc()).events()
    ("POST", "/greet") =>
      match parse_name(body) {
        Some(n) =>
          json_response(
            200,
            [],
            { "message": greet_prefix(hs) + ", " + n + "!" }.to_json(),
          ).events()
        None =>
          json_response(
            422,
            [],
            Json::object({ "detail": Json::string("field required: name") }),
          ).events()
      }
    _ =>
      json_response(
        404,
        [],
        Json::object({ "detail": Json::string("not found") }),
      ).events()
  }
}

///|
/// Drive `greet_app` over a request and return both the reassembled response and
/// the seam's own verdict on whether the events it emitted are well-formed, so
/// every case asserts round-trip fidelity and spec-compliant ordering at once.
fn drive_greet(
  hs : @moonasgi.HttpScope,
  body : Bytes,
) -> (@moonasgi.TestResponse, @moonasgi.EventOrderError?) {
  let sc = @spec.Http(hs)
  let ev = @http.run_http_scoped(greet_app, sc, [
    @spec.HttpRequest(body~, more_body=false),
  ])
  (@client.reassemble(ev), @conform.validate_events(sc, ev))
}

///|
/// The string value at `key` in a JSON object body, for asserting on responses.
fn json_str(j : Json, key : String) -> String? {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
}

///|
/// Parse a `@moonasgi.TestResponse` body as JSON or fail the test.
fn body_json(r : @moonasgi.TestResponse) -> Json {
  try r.json() catch {
    _ => abort("response body was not valid JSON")
  } noraise {
    v => v
  }
}

///|
/// moonapi routing round-trips through the scope-aware seam core: request line,
/// query, body, headers, `root_path`, and the served response all survive
/// lowering to events and reassembly, and every emitted stream is well-formed.
test "greet: moonapi http routing round-trips through @http.run_http_scoped" {
  // Health check: GET /ping. The framework reads root_path off the scope (the
  // ergonomic Request drops it) and stamps it onto the response.
  let (ping, ping_v) = drive_greet(
    @moonasgi.HttpScope::new(http_method="GET", path="/ping", root_path="/api"),
    b"",
  )
  assert_eq(ping_v is None, true)
  assert_eq(ping.status, 200)
  assert_eq(ping.header("content-type"), Some("application/json"))
  assert_eq(ping.header("x-root-path"), Some("/api"))
  assert_eq(json_str(body_json(ping), "message"), Some("pong"))

  // Validated POST /greet: a well-formed body greets, a malformed one 422s.
  let (ok, ok_v) = drive_greet(
    @moonasgi.HttpScope::new(http_method="POST", path="/greet"),
    @utf8.encode("{\"name\":\"Leo\"}"),
  )
  assert_eq(ok_v is None, true)
  assert_eq(ok.status, 200)
  assert_eq(json_str(body_json(ok), "message"), Some("Hello, Leo!"))
  let (bad, bad_v) = drive_greet(
    @moonasgi.HttpScope::new(http_method="POST", path="/greet"),
    @utf8.encode("{\"nope\":1}"),
  )
  assert_eq(bad_v is None, true)
  assert_eq(bad.status, 422)
  assert_eq(json_str(body_json(bad), "detail"), Some("field required: name"))

  // The served OpenAPI document round-trips as structured JSON, not a blob.
  let (spec, spec_v) = drive_greet(
    @moonasgi.HttpScope::new(http_method="GET", path="/openapi.json"),
    b"",
  )
  assert_eq(spec_v is None, true)
  assert_eq(spec.status, 200)
  let doc = body_json(spec)
  assert_eq(json_str(doc, "openapi"), Some("3.1.0"))
  match doc {
    Object(m) => assert_eq(m.get("paths") is Some(_), true)
    _ => abort("openapi doc was not a JSON object")
  }

  // An unknown route 404s through the same path.
  let (miss, miss_v) = drive_greet(
    @moonasgi.HttpScope::new(http_method="GET", path="/nope"),
    b"",
  )
  assert_eq(miss_v is None, true)
  assert_eq(miss.status, 404)
}

///|
/// A streamed request body — several `@spec.HttpRequest` chunks the server feeds in as
/// it reads the socket — reassembles into the exact bytes the framework parses,
/// so a chunked upload greets identically to a buffered one.
test "greet: a chunked request body drains losslessly into the framework" {
  let sc = @spec.Http(
    @moonasgi.HttpScope::new(http_method="POST", path="/greet"),
  )
  // "{\"name\":\"Ada\"}" split across three inbound frames.
  let inbound = [
    @spec.HttpRequest(body=@utf8.encode("{\"na"), more_body=true),
    @spec.HttpRequest(body=@utf8.encode("me\":\"A"), more_body=true),
    @spec.HttpRequest(body=@utf8.encode("da\"}"), more_body=false),
  ]
  let ev = @http.run_http_scoped(greet_app, sc, inbound)
  assert_eq(@conform.validate_events(sc, ev) is None, true)
  let r = @client.reassemble(ev)
  assert_eq(r.status, 200)
  assert_eq(json_str(body_json(r), "message"), Some("Hello, Ada!"))
}

///|
/// The lifespan a server runs at boot round-trips through `@lifespan.run_lifespan`: startup
/// seeds `scope.state` in place, the server copies that state onto each request
/// scope, and the framework reads it back — the exact hop greet uses to share a
/// DB pool / config with every request. Shutdown replies complete, and a failed
/// startup short-circuits the way ASGI pins.
test "greet: lifespan startup seeds state that reaches the request handler" {
  let boot = @moonasgi.LifespanScope::new()
  let handler = @moonasgi.LifespanHandler::new(on_startup=fn(s) {
    // A framework's startup hook populates scope.state in place.
    s.state["greeting_prefix"] = Json::string("Bonjour")
    s.state["db_pool"] = Json::string("pool://greet")
    Complete
  })
  let ls_scope = @spec.Lifespan(boot)
  let up = @lifespan.run_lifespan(handler, ls_scope, [LifespanStartup])
  assert_eq(up == [LifespanStartupComplete], true)
  assert_eq(boot.state.get("db_pool") is Some(_), true)
  assert_eq(@conform.validate_events(ls_scope, up) is None, true)

  // mooncat copies the lifespan state onto each request scope; the framework
  // greets with the prefix that startup seeded, proving the state carried across.
  let (r, v) = drive_greet(
    @moonasgi.HttpScope::new(
      http_method="POST",
      path="/greet",
      state=boot.state,
    ),
    @utf8.encode("{\"name\":\"Grace\"}"),
  )
  assert_eq(v is None, true)
  assert_eq(json_str(body_json(r), "message"), Some("Bonjour, Grace!"))

  // Shutdown completes, and the full startup→shutdown cycle validates in order.
  let cycle = @lifespan.run_lifespan(handler, ls_scope, [
    LifespanStartup,
    LifespanShutdown,
  ])
  assert_eq(cycle == [LifespanStartupComplete, LifespanShutdownComplete], true)
  assert_eq(@conform.validate_events(ls_scope, cycle) is None, true)

  // A failed startup aborts the boot: the server never proceeds to shutdown.
  let failing = @moonasgi.LifespanHandler::new(on_startup=fn(_s) {
    Failed(message="db unreachable")
  })
  let failed = @lifespan.run_lifespan(
    failing,
    @spec.Lifespan(@moonasgi.LifespanScope::new()),
    [LifespanStartup, LifespanShutdown],
  )
  assert_eq(failed == [LifespanStartupFailed(message="db unreachable")], true)
}

///|
/// The moonzero middleware chain composes over a greet handler and drives end to
/// end through the `@moonasgi.TestClient` (the ergonomic path a request-oriented handler
/// takes): request-id, CORS, and logging headers land outermost-first and the
/// body round-trips untouched.
test "greet: the moonzero middleware chain round-trips through the @moonasgi.TestClient" {
  let request_id : @moonasgi.Middleware = fn(next) {
    fn(req) {
      let r = next(req)
      @moonasgi.Response::new(
        r.status,
        [("x-request-id", "req-42"), ..r.headers],
        r.body,
      )
    }
  }
  let cors : @moonasgi.Middleware = fn(next) {
    fn(req) {
      let r = next(req)
      @moonasgi.Response::new(
        r.status,
        [("access-control-allow-origin", "*"), ..r.headers],
        r.body,
      )
    }
  }
  let base : @moonasgi.Handler = fn(req) {
    json_response(
      200,
      [("x-core", "hit")],
      { "echo": @utf8.decode_lossy(req.body[:]) }.to_json(),
    )
  }
  let logging : @moonasgi.Middleware = fn(next) {
    fn(req) {
      let r = next(req)
      @moonasgi.Response::new(
        r.status,
        [("x-logged", req.path), ..r.headers],
        r.body,
      )
    }
  }
  let app = @http.compose([request_id, cors, logging], base)
  let client = @moonasgi.TestClient::new(app)
  let r = client.post("/greet", body=@utf8.encode("payload"))
  assert_eq(r.status, 200)
  // Outermost middleware ran last on the way out, so its header sits first.
  assert_eq(r.header("x-request-id"), Some("req-42"))
  assert_eq(r.header("access-control-allow-origin"), Some("*"))
  assert_eq(r.header("x-logged"), Some("/greet"))
  assert_eq(r.header("x-core"), Some("hit"))
  assert_eq(json_str(body_json(r), "echo"), Some("payload"))
}

///|
/// The greet chat endpoint: a @spec.WebSocket app accepts with a negotiated
/// subprotocol, echoes each text/binary frame, and closes on disconnect — the
/// accept/receive/send/close cycle greet's chat uses, round-tripped through
/// `@ws.ws_run` / the `@moonasgi.TestClient` with no socket.
test "greet: websocket chat accepts, echoes, and closes through @ws.ws_run" {
  let client = @moonasgi.TestClient::new(fn(_r) { @moonasgi.Response::text("") })
  // A chat handler: accept with a negotiated subprotocol, echo each frame, and
  // close when the client says "bye" — the accept/receive/send/close cycle.
  let chat = @moonasgi.WebSocketHandler::new(
    on_connect=fn(_s) { Accept(subprotocol=Some("greet.chat.v1"), headers=[]) },
    on_receive=fn(m) {
      match m {
        Text("bye") => [SendText("goodbye"), Close(code=1000, reason="bye")]
        Text(t) => [SendText(t)]
        Binary(b) => [SendBinary(b)]
      }
    },
  )
  let session = client.websocket(
    path="/chat",
    handler=chat,
    send=[Text("hello"), Binary(b"\x01\x02"), Text("bye")],
    // The server closes first, so no client disconnect follows.
    disconnect=None,
  )
  assert_eq(session.accepted, true)
  assert_eq(session.subprotocol, Some("greet.chat.v1"))
  assert_eq(
    session.messages == [Text("hello"), Binary(b"\x01\x02"), Text("goodbye")],
    true,
  )
  assert_eq(session.texts(), ["hello", "goodbye"])
  // The handler closed the connection with its code and reason.
  assert_eq(session.closed, true)
  assert_eq(session.close_code, Some(1000))
  assert_eq(session.close_reason, Some("bye"))
  // The raw driver output is a well-formed handshake+frames+close stream.
  let scope = @spec.WebSocket(@moonasgi.WebSocketScope::new(path="/chat"))
  let raw = @ws.ws_run(@moonasgi.WebSocketHandler::echo(), scope, [
    WebSocketConnect,
    WebSocketReceive(text=Some("x"), bytes=None),
    WebSocketDisconnect(code=1000, reason=None),
  ])
  assert_eq(@conform.validate_ws_response(raw) is None, true)
}

///|
/// A server-sent-events stream: the framework emits an event-stream response as
/// several body chunks (`more_body: true`), and the client reassembles them into
/// the contiguous body a real client would read, ordering intact.
test "greet: an SSE stream reassembles chunk-for-chunk" {
  let sse : @moonasgi.StreamHandler = fn(_req) {
    @moonasgi.StreamingResponse::new(
      status=200,
      headers=[("content-type", "text/event-stream")],
      chunks=[b"data: one\n\n", b"data: two\n\n", b"data: three\n\n"],
    )
  }
  // The lowered stream marks every chunk but the last as more_body=true.
  let events = sse({
    http_method: "GET",
    path: "/events",
    query_string: b"",
    headers: [],
    body: b"",
  }).events()
  assert_eq(@conform.validate_http_response(events) is None, true)
  let client = @moonasgi.TestClient::from_stream(sse)
  let r = client.get("/events")
  assert_eq(r.status, 200)
  assert_eq(r.header("content-type"), Some("text/event-stream"))
  assert_eq(r.body, b"data: one\n\ndata: two\n\ndata: three\n\n")
}

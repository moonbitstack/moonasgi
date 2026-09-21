///|
/// The TestClient drives a unary handler in-process: build it from a `@http.Handler`,
/// issue GET/POST, and read back the captured status/body/headers with no socket.
test "TestClient drives a unary handler for GET and POST" {
  let handler : @http.Handler = fn(req) {
    @http.Response::new(
      200,
      [("x-method", req.http_method), ("x-path", req.path)],
      req.body,
    )
  }
  let client = TestClient::new(handler)
  let g = client.get("/hello")
  assert_eq(g.status, 200)
  assert_eq(g.header("x-method"), Some("GET"))
  assert_eq(g.header("x-path"), Some("/hello"))
  assert_eq(g.body, b"")
  let p = client.post("/echo", body=b"payload")
  assert_eq(p.header("x-method"), Some("POST"))
  assert_eq(p.body, b"payload")
  assert_eq(p.text(), "payload")
}

///|
/// The query string is split off the target on the first `?` and reaches the
/// scope as `query_string` bytes, while `path` is the bare path.
test "TestClient splits the query string from the path" {
  let seen : Array[Bytes] = []
  let seen_path : Array[String] = []
  let handler : @http.Handler = fn(req) {
    seen.push(req.query_string)
    seen_path.push(req.path)
    @http.Response::text("ok")
  }
  let client = TestClient::new(handler)
  let _ = client.get("/search?q=moonbit&n=3")
  assert_eq(seen_path[0], "/search")
  assert_eq(seen[0], b"q=moonbit&n=3")
}

///|
/// Base headers set on the client are merged in front of per-request headers.
test "TestClient merges base headers with per-request headers" {
  let handler : @http.Handler = fn(req) {
    @http.Response::new(
      200,
      [("auth", req.header("authorization").unwrap_or("none"))],
      match req.header("x-req") {
        Some(v) => @utf8.encode(v)
        None => b""
      },
    )
  }
  let client = TestClient::new(handler, base_headers=[
    ("authorization", "Bearer t"),
  ])
  let r = client.get("/", headers=[("x-req", "here")])
  assert_eq(r.header("auth"), Some("Bearer t"))
  assert_eq(r.body, b"here")
}

///|
/// A streamed request body — several `HttpRequest` chunks — is drained and
/// reassembled into the handler's `@http.Request.body`, exactly like the async path.
test "TestClient streams a chunked request body into the handler" {
  let handler : @http.Handler = fn(req) {
    @http.Response::new(200, [], req.body)
  }
  let client = TestClient::new(handler)
  let r = client.request(http_method="POST", path="/upload", chunks=[
    b"chunk-1;", b"chunk-2;", b"chunk-3",
  ])
  assert_eq(r.body, b"chunk-1;chunk-2;chunk-3")
}

///|
/// A streaming handler's multi-chunk body is reassembled by the client into one
/// contiguous body — the response-streaming path (`more_body: true`) end to end.
test "TestClient reassembles a streaming multi-chunk response body" {
  let handler : @http.StreamHandler = fn(_req) {
    @http.StreamingResponse::new(
      status=200,
      headers=[("content-type", "text/plain")],
      chunks=[b"one ", b"two ", b"three"],
    )
  }
  // The lowered event stream marks every chunk but the last as more_body=true.
  let stream = handler({
    http_method: "GET",
    path: "/",
    query_string: b"",
    headers: [],
    body: b"",
  }).events()
  assert_eq(stream[1] == HttpResponseBody(body=b"one ", more_body=true), true)
  assert_eq(stream[3] == HttpResponseBody(body=b"three", more_body=false), true)
  let client = TestClient::from_stream(handler)
  let r = client.get("/")
  assert_eq(r.status, 200)
  assert_eq(r.body, b"one two three")
  assert_eq(r.header("content-type"), Some("text/plain"))
}

///|
/// The `http.response.trailers` extension: a streamed response with trailers
/// sets `HttpResponseStart.trailers=true`, appends an `HttpResponseTrailers`
/// after the body, and the client surfaces them via `TestResponse.trailers`.
test "TestClient captures response trailers" {
  let handler : @http.StreamHandler = fn(_req) {
    @http.StreamingResponse::new(chunks=[b"body"], trailers=[
      ("content-digest", "sha-256=abc"),
    ])
  }
  let events = handler({
    http_method: "GET",
    path: "/",
    query_string: b"",
    headers: [],
    body: b"",
  }).events()
  // start carries trailers=true; a trailers frame terminates the stream.
  assert_eq(
    events[0] == HttpResponseStart(status=200, headers=[], trailers=true),
    true,
  )
  assert_eq(
    events[events.length() - 1] ==
    HttpResponseTrailers(
      headers=[("content-digest", "sha-256=abc")],
      more_trailers=false,
    ),
    true,
  )
  let client = TestClient::from_stream(handler)
  let r = client.get("/")
  assert_eq(r.body, b"body")
  assert_eq(r.trailer("content-digest"), Some("sha-256=abc"))
}

///|
/// The `http.response.push` and `http.response.pathsend` extensions: an
/// event-emitting app can promise pushes and hand off a file path, both captured
/// by the client.
test "TestClient captures server push and pathsend" {
  let app : (@http.Request) -> Array[@spec.Event] = fn(_req) {
    [
      HttpResponseStart(status=200, headers=[], trailers=false),
      HttpResponsePush(path="/app.css", headers=[("accept", "text/css")]),
      HttpResponsePush(path="/app.js", headers=[]),
      HttpResponsePathSend(path="/srv/www/index.html"),
    ]
  }
  let client = TestClient::from_app(app)
  let r = client.get("/")
  assert_eq(r.status, 200)
  assert_eq(r.pushes.length(), 2)
  assert_eq(r.pushes[0].path, "/app.css")
  assert_eq(r.pushes[0].header("accept"), Some("text/css"))
  assert_eq(r.pushes[1].path, "/app.js")
  assert_eq(r.pathsend, Some("/srv/www/index.html"))
}

///|
/// The JSON convenience: a JSON body round-trips through `TestResponse.json`.
test "TestResponse decodes a JSON body" {
  let handler : @http.Handler = fn(_req) {
    @http.Response::json(
      Json::object({ "hero": Json::string("leo"), "level": Json::number(9) }),
    )
  }
  let client = TestClient::new(handler)
  let r = client.get("/")
  assert_eq(r.header("content-type"), Some("application/json"))
  let parsed = try r.json() catch {
    _ => abort("body was not valid JSON")
  } noraise {
    v => v
  }
  match parsed {
    Object(m) => {
      match m.get("hero") {
        Some(String(s)) => assert_eq(s, "leo")
        _ => abort("expected string hero")
      }
      match m.get("level") {
        Some(Number(n, ..)) => assert_eq(n, 9.0)
        _ => abort("expected number level")
      }
    }
    _ => abort("expected a JSON object body")
  }
}

///|
/// A `@http.Middleware` stack composed into a `@http.Handler` is driven end to end through
/// the `TestClient` — the real in-process request→response path, outermost
/// middleware first.
test "TestClient drives a full middleware-composed application" {
  let base : @http.Handler = fn(req) {
    @http.Response::new(200, [("x-core", "hit")], req.body)
  }
  let stamp = fn(label : String) -> @http.Middleware {
    fn(next) {
      fn(req) {
        let r = next(req)
        @http.Response::new(r.status, [("x-layer", label), ..r.headers], r.body)
      }
    }
  }
  let app = @http.compose([stamp("outer"), stamp("inner")], base)
  let client = TestClient::new(app)
  let r = client.post("/run", body=b"go")
  assert_eq(r.status, 200)
  // outermost middleware ran last on the way out, so its header is first.
  assert_eq(r.header("x-layer"), Some("outer"))
  assert_eq(r.header("x-core"), Some("hit"))
  assert_eq(r.body, b"go")
}

///|
/// spec_version negotiation: `at_least` compares the dotted `spec_version`
/// numerically, so a `2.5` scope satisfies a `2.4` requirement but not `2.6`.
test "AsgiVersion negotiates spec_version numerically" {
  let v = @spec.AsgiVersion::default()
  assert_eq(v.spec_version, "2.5")
  assert_eq(v.at_least(major=2, minor=0), true)
  assert_eq(v.at_least(major=2, minor=5), true)
  assert_eq(v.at_least(major=2, minor=6), false)
  assert_eq(v.at_least(major=1, minor=9), true)
  assert_eq(v.at_least(major=3, minor=0), false)
  let old : @spec.AsgiVersion = { version: "3.0", spec_version: "2.10", }
  assert_eq(old.at_least(major=2, minor=9), true)
}

///|
/// The `extensions` capability flags and TLS data flow onto the scope the client
/// builds, so an application can gate extension use on what the server advertises.
test "Extensions builder advertises capabilities and TLS data" {
  let tls : @spec.TlsExtension = {
    server_cert: Some("-----BEGIN CERTIFICATE-----"),
    client_cert_chain: [],
    client_cert_name: None,
    client_cert_error: None,
    tls_version: Some(0x0304),
    cipher_suite: Some(0x1301),
  }
  let ext = @spec.Extensions::none()
    .enable_push()
    .enable_trailers()
    .enable_pathsend()
    .enable_websocket_http_response()
    .with_tls(tls)
  assert_eq(ext.http_response_push, true)
  assert_eq(ext.http_response_trailers, true)
  assert_eq(ext.http_response_pathsend, true)
  assert_eq(ext.websocket_http_response, true)
  assert_eq(ext.tls is Some(_), true)
  // The client threads its advertised extensions onto every request scope.
  let seen : Array[Bool] = []
  let app : (@http.Request) -> Array[@spec.Event] = fn(_req) {
    [HttpResponseStart(status=204, headers=[], trailers=false)]
  }
  let client = TestClient::from_app(app, extensions=ext)
  let r = client.get("/")
  assert_eq(r.status, 204)
  seen.push(true)
  assert_eq(seen.length(), 1)
}

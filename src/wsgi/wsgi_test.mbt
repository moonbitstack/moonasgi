///|
fn hello() -> @wsgi.WsgiApp {
  (_, start) => {
    ignore(start("201 Created", [("Content-Type", "text/plain")]))
    [b"hello", b"", b", ", b"world"].iter()
  }
}

///|
async test "status, lowered headers, and the body chunk by chunk" {
  let reply = @testing.Client::new(@wsgi.to_asgi(hello())).get("/")
  assert_eq(reply.status, 201)
  assert_eq(reply.header("content-type"), Some("text/plain"))
  assert_eq(reply.text(), "hello, world")
  let scope = @spec.Scope::Http(
    @spec.HttpScope::new(http_method="GET", path="/"),
  )
  @testing.communicate(@wsgi.to_asgi(hello()), scope, c => {
    c.send(HttpRequest(body=b"", more_body=false))
    assert_true(c.receive() is HttpResponseStart(status=201, ..))
    assert_true(c.receive() is HttpResponseBody(body=b"hello", more_body=true))
    assert_true(c.receive() is HttpResponseBody(body=b", ", more_body=true))
    assert_true(c.receive() is HttpResponseBody(body=b"world", more_body=true))
    assert_true(c.receive() is HttpResponseBody(body=b"", more_body=false))
  })
}

///|
async test "write() goes out before what the iterator yields" {
  let app : @wsgi.WsgiApp = (_, start) => {
    let write = start("200 OK", [])
    write(b"a")
    write(b"b")
    [b"c"].iter()
  }
  assert_eq(@testing.Client::new(@wsgi.to_asgi(app)).get("/").text(), "abc")
}

///|
async test "the environment, under a mount" {
  let seen : Array[@wsgi.Environ] = []
  let app : @wsgi.WsgiApp = (environ, start) => {
    seen.push(environ)
    ignore(start("200 OK", []))
    [environ.input].iter()
  }
  let mounted = @dispatch.mount([("/legacy", @wsgi.to_asgi(app))])
  let reply = @testing.Client::new(mounted).post(
    "/legacy/items?page=2",
    body=b"name=moon",
    headers=[
      ("content-type", "application/x-www-form-urlencoded"),
      ("x-tag", "a"),
      ("x-tag", "b"),
      ("host", "example.com:8080"),
    ],
  )
  assert_eq(reply.text(), "name=moon")
  let env = seen[0]
  assert_eq(env.request_method, "POST")
  assert_eq(env.script_name, "/legacy")
  assert_eq(env.path_info, "/items")
  assert_eq(env.query_string, "page=2")
  assert_eq(env.header("X-Tag"), Some("a"))
  let cgi = env.to_map()
  assert_eq(cgi.get("CONTENT_TYPE"), Some("application/x-www-form-urlencoded"))
  assert_eq(cgi.get("HTTP_X_TAG"), Some("a,b"))
  assert_eq(cgi.get("HTTP_CONTENT_TYPE"), None)
  assert_eq(cgi.get("SERVER_PROTOCOL"), Some("HTTP/1.1"))
  assert_eq(cgi.get("wsgi.url_scheme"), Some("http"))
}

///|
test "server name and port from the scope, the Host header, or the scheme" {
  let scope = @spec.HttpScope::new(
    http_method="GET",
    path="/",
    scheme="https",
    headers=[("host", "api.test")],
  )
  let env = @wsgi.Environ::of(scope, b"")
  assert_eq((env.server_name, env.server_port), ("api.test", "443"))
  let served = @wsgi.Environ::of(
    { ..scope, server: Some(("10.0.0.1", Some(9000))), },
    b"",
  )
  assert_eq((served.server_name, served.server_port), ("10.0.0.1", "9000"))
}

///|
async test "a raise, no start, or a body before the start is a 500" {
  let raising : @wsgi.WsgiApp = (_, _) => raise Failure("broken")
  let silent : @wsgi.WsgiApp = (_, _) => [b""].iter()
  let early : @wsgi.WsgiApp = (_, _) => [b"body"].iter()
  for app in [raising, silent, early] {
    assert_eq(@testing.Client::new(@wsgi.to_asgi(app)).get("/").status, 500)
  }
}

///|
async test "a WebSocket is declined and the lifespan answered" {
  let app = @wsgi.to_asgi(hello())
  @testing.communicate(
    app,
    @spec.Scope::WebSocket(@spec.WebSocketScope::new(path="/")),
    c => {
      c.send(WebSocketConnect)
      assert_true(c.receive() is WebSocketClose(..))
    },
  )
  @testing.communicate(app, @spec.Scope::Lifespan(@spec.LifespanScope::new()), c => {
    c.send(LifespanStartup)
    assert_true(c.receive() is LifespanStartupComplete)
    c.send(LifespanShutdown)
    assert_true(c.receive() is LifespanShutdownComplete)
  })
}

///|
/// Echoes the request body, and reports the method, path and query in headers.
let mirror : @spec.AsgiApp = @http.to_asgi(req => {
  @http.Response::new(
    200,
    [
      ("x-method", req.http_method),
      ("x-path", req.path),
      ("x-query", @utf8.decode_lossy(req.query_string)),
      ("x-token", req.header("x-token").unwrap_or("")),
    ],
    req.body,
  )
})

///|
/// Reports the scope's peers, root path and state in a JSON body.
let scoped : @spec.AsgiApp = async fn(scope, receive, send) {
  guard scope is Http(s) else { raise Boom }
  ignore(receive())
  let doc : Json = {
    "client": s.client.map(c => c.0).unwrap_or(""),
    "server": s.server.map(c => c.0).unwrap_or(""),
    "root": s.root_path,
    "state": Json::object(s.state),
  }
  send(HttpResponseStart(status=200, headers=[], trailers=false))
  send(HttpResponseBody(body=@utf8.encode(doc.stringify()), more_body=false))
}

///|
async test "request runs the application and gathers the response" {
  let client = @testing.Client::new(mirror)
  let r = client.post("/items?q=1", body=b"payload")
  assert_eq(r.status, 200)
  assert_eq(r.header("x-method"), Some("POST"))
  assert_eq(r.header("x-path"), Some("/items"))
  assert_eq(r.header("x-query"), Some("q=1"))
  assert_eq(r.text(), "payload")
}

///|
async test "every verb helper sends its method" {
  let client = @testing.Client::new(mirror)
  assert_eq(client.get("/").header("x-method"), Some("GET"))
  assert_eq(client.head("/").header("x-method"), Some("HEAD"))
  assert_eq(client.delete("/").header("x-method"), Some("DELETE"))
  assert_eq(client.put("/", body=b"a").text(), "a")
  assert_eq(client.patch("/", body=b"b").text(), "b")
}

///|
async test "chunks arrive as one streamed body" {
  let r = @testing.Client::new(mirror).request(http_method="POST", path="/", chunks=[
    b"ab", b"", b"cd",
  ])
  assert_eq(r.text(), "abcd")
}

///|
async test "base headers come before the request's own" {
  let client = @testing.Client::new(mirror, base_headers=[("x-token", "base")])
  assert_eq(client.get("/").header("x-token"), Some("base"))
  let r = @testing.Client::new(mirror, base_headers=[("x-other", "1")]).get(
    "/",
    headers=[("x-token", "own")],
  )
  assert_eq(r.header("x-token"), Some("own"))
}

///|
async test "the scope carries the client's peers and root path" {
  let r = @testing.Client::new(scoped, root_path="/api").get("/")
  assert_eq(r.json(), {
    "client": "testclient",
    "server": "testserver",
    "root": "/api",
    "state": {},
  })
  let bare = @testing.Client::new(scoped, client=None, server=None).get("/")
  assert_eq(bare.json(), { "client": "", "server": "", "root": "", "state": {} })
}

///|
async test "trailers end the response and are gathered" {
  let app : @spec.AsgiApp = async fn(_, receive, send) {
    ignore(receive())
    send(HttpResponseStart(status=200, headers=[], trailers=true))
    send(HttpResponseBody(body=b"x", more_body=false))
    send(HttpResponseTrailers(headers=[("x-sum", "1")], more_trailers=false))
  }
  let r = @testing.Client::new(app).get("/")
  assert_eq(r.text(), "x")
  assert_eq(r.trailer("x-sum"), Some("1"))
}

///|
async test "a response owing trailers is not complete until they are sent" {
  let app : @spec.AsgiApp = async fn(_, receive, send) {
    ignore(receive())
    send(HttpResponseStart(status=200, headers=[], trailers=true))
    send(HttpResponseBody(body=b"x", more_body=false))
    let early = @async.with_timeout_opt(50, () => receive())
    send(
      HttpResponseTrailers(
        headers=[("x-early", if early is None { "none" } else { "disconnect" })],
        more_trailers=false,
      ),
    )
  }
  assert_eq(@testing.Client::new(app).get("/").trailer("x-early"), Some("none"))
}

///|
async test "the application sees http.disconnect once its response is complete" {
  let after : Array[@spec.Event] = []
  let app : @spec.AsgiApp = async fn(_, receive, send) {
    ignore(receive())
    send(HttpResponseStart(status=204, headers=[], trailers=false))
    send(HttpResponseBody(body=b"", more_body=false))
    after.push(receive())
    send(HttpResponseDebug(info={ "late": true }))
  }
  let r = @testing.Client::new(app).get("/")
  assert_eq(r.status, 204)
  assert_eq(after, [HttpDisconnect])
  assert_eq(r.debug, [{ "late": true }])
}

///|
async test "an application that returns without answering raises Finished" {
  let app : @spec.AsgiApp = async fn(_, receive, _) { ignore(receive()) }
  assert_true(
    error_of(() => @testing.Client::new(app).get("/")) is @testing.Finished,
  )
}

///|
async test "an error raised after the response still fails the request" {
  let app : @spec.AsgiApp = async fn(_, receive, send) {
    ignore(receive())
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(HttpResponseBody(body=b"", more_body=false))
    raise Boom
  }
  assert_true(error_of(() => @testing.Client::new(app).get("/")) is Boom)
}

///|
async test "a stalled application times out at the client's timeout" {
  assert_true(
    error_of(() => @testing.Client::new(stuck, timeout=25).get("/"))
    is @testing.Timeout(limit=25),
  )
}

///|
async test "a legacy double-callable application runs once made single" {
  let legacy = @spec.guarantee_single_callable(
    Legacy(scope => async fn(receive, send) { mirror(scope, receive, send) }),
  )
  assert_eq(@testing.Client::new(legacy).post("/", body=b"old").text(), "old")
}

///|
async test "lifespan state reaches every request scope" {
  let trace : Array[String] = []
  let app : @spec.AsgiApp = async fn(scope, receive, send) {
    match scope {
      Lifespan(s) =>
        while true {
          match receive() {
            LifespanStartup => {
              s.state["db"] = "ready"
              trace.push("startup")
              send(LifespanStartupComplete)
            }
            LifespanShutdown => {
              trace.push("shutdown")
              send(LifespanShutdownComplete)
              break
            }
            _ => raise Boom
          }
        }
      _ => {
        trace.push("request")
        scoped(scope, receive, send)
      }
    }
  }
  let client = @testing.Client::new(app)
  let r = client.lifespan(() => client.get("/"))
  assert_eq(r.json(), {
    "client": "testclient",
    "server": "testserver",
    "root": "",
    "state": { "db": "ready" },
  })
  assert_eq(trace, ["startup", "request", "shutdown"])
}

///|
/// A lifespan handler that answers startup and shutdown with the given events.
fn lifespan_app(
  startup : @spec.Event,
  shutdown : @spec.Event,
  trace : Array[String],
) -> @spec.AsgiApp {
  async fn(_, receive, send) {
    while true {
      match receive() {
        LifespanStartup => send(startup)
        LifespanShutdown => {
          trace.push("shutdown")
          send(shutdown)
          break
        }
        _ => raise Boom
      }
    }
  }
}

///|
async test "a failed startup raises Startup with the message" {
  let app = lifespan_app(
    LifespanStartupFailed(message="no db"),
    LifespanShutdownComplete,
    [],
  )
  assert_true(
    error_of(() => @testing.Client::new(app).lifespan(() => ()))
    is @testing.Startup("no db"),
  )
}

///|
async test "a failed shutdown raises Shutdown with the message" {
  let app = lifespan_app(
    LifespanStartupComplete,
    LifespanShutdownFailed(message="leak"),
    [],
  )
  assert_true(
    error_of(() => @testing.Client::new(app).lifespan(() => ()))
    is @testing.Shutdown("leak"),
  )
}

///|
async test "shutdown runs when the body fails" {
  let trace = []
  let app = lifespan_app(
    LifespanStartupComplete,
    LifespanShutdownComplete,
    trace,
  )
  assert_true(error_of(() => @testing.Client::new(app).lifespan(boom)) is Boom)
  assert_eq(trace, ["shutdown"])
}

///|
async test "a reply outside the lifespan protocol raises Unexpected" {
  let app = lifespan_app(HttpDisconnect, LifespanShutdownComplete, [])
  assert_true(
    error_of(() => @testing.Client::new(app).lifespan(() => ()))
    is @testing.Unexpected(HttpDisconnect),
  )
}

///|
async test "a body goes with its content-length unless the caller framed it" {
  let app : @spec.AsgiApp = async fn(scope, _, send) {
    guard scope is Http(hs) else { return }
    let length = hs.headers
      .iter()
      .find_first(h => h.0 == "content-length")
      .map(h => h.1)
      .unwrap_or("none")
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(HttpResponseBody(body=@utf8.encode(length), more_body=false))
  }
  let client = @testing.Client::new(app)
  assert_eq(client.post("/", body=b"12345").text(), "5")
  assert_eq(client.get("/").text(), "none")
  assert_eq(
    client.post("/", body=b"12345", headers=[("content-length", "5")]).text(),
    "5",
  )
  assert_eq(
    client.request(http_method="POST", path="/", chunks=[b"ab", b"cde"]).text(),
    "5",
  )
}

///|
async test "a response's cookie is kept and sent on the next request" {
  let app = @http.to_asgi(req => {
    match req.path {
      "/login" =>
        @http.Response::new(200, [("set-cookie", "sid=abc; Path=/")], b"")
      _ =>
        @http.Response::new(
          200,
          [],
          @utf8.encode(req.header("cookie").unwrap_or("")),
        )
    }
  })
  let client = @testing.Client::new(app)
  assert_eq(client.get("/login").status, 200)
  assert_eq(client.cookie("sid"), Some("abc"))
  assert_eq(client.cookies(), [("sid", "abc")])
  assert_eq(client.get("/").text(), "sid=abc")
}

///|
async test "a cookie with no path belongs to the request's directory" {
  let app = @http.to_asgi(req => {
    match req.path {
      "/app/login" => @http.Response::new(200, [("set-cookie", "sid=abc")], b"")
      _ =>
        @http.Response::new(
          200,
          [],
          @utf8.encode(req.header("cookie").unwrap_or("")),
        )
    }
  })
  let client = @testing.Client::new(app)
  ignore(client.get("/app/login"))
  assert_eq(client.get("/app/dashboard").text(), "sid=abc")
  assert_eq(client.get("/other").text(), "")
  assert_eq(client.get("/").text(), "")
}

///|
async test "a cookie for another domain is refused and never sent" {
  let app = @http.to_asgi(req => {
    match req.path {
      "/plant" =>
        @http.Response::new(
          200,
          [("set-cookie", "sid=evil; Domain=other.example; Path=/")],
          b"",
        )
      _ =>
        @http.Response::new(
          200,
          [],
          @utf8.encode(req.header("cookie").unwrap_or("")),
        )
    }
  })
  let client = @testing.Client::new(app)
  ignore(client.get("/plant"))
  assert_eq(client.cookie("sid"), None)
  assert_eq(client.get("/").text(), "")
}

///|
async test "a redirect is followed only when the client is asked to" {
  let app = @http.to_asgi(req => {
    match req.path {
      "/old" => @http.Response::new(302, [("location", "/new")], b"moved")
      "/new" => @http.Response::new(200, [], @utf8.encode("at " + req.path))
      _ => @http.Response::new(404, [], b"")
    }
  })
  // Off by default, so a test that asserts on a redirect keeps seeing it.
  let still = @testing.Client::new(app)
  let r = still.get("/old")
  assert_eq(r.status, 302)
  assert_eq(r.text(), "moved")
  let following = @testing.Client::new(app, follow_redirects=true)
  let r = following.get("/old")
  assert_eq(r.status, 200)
  assert_eq(r.text(), "at /new")
}

///|
async test "a 303 continues as a GET and a 307 keeps the body" {
  let app = @http.to_asgi(req => {
    match req.path {
      "/submit" =>
        @http.Response::new(
          303,
          [("location", "/done"), ("set-cookie", "sid=one; Path=/")],
          b"",
        )
      "/keep" => @http.Response::new(307, [("location", "/done")], b"")
      "/done" =>
        @http.Response::new(
          200,
          [],
          @utf8.encode(
            req.http_method +
            " " +
            @utf8.decode_lossy(req.body[:]) +
            " " +
            req.header("cookie").unwrap_or(""),
          ),
        )
      _ => @http.Response::new(404, [], b"")
    }
  })
  let client = @testing.Client::new(app, follow_redirects=true)
  // The cookie the redirect itself set is carried to the hop it points at.
  assert_eq(client.post("/submit", body=b"payload").text(), "GET  sid=one")
  assert_eq(
    client.post("/keep", body=b"payload").text(),
    "POST payload sid=one",
  )
}

///|
async test "following stops at the limit and answers with the redirect" {
  let hits : Array[String] = []
  let app = @http.to_asgi(req => {
    hits.push(req.path)
    @http.Response::new(302, [("location", "/loop")], b"")
  })
  let client = @testing.Client::new(app, follow_redirects=true, max_redirects=3)
  let r = client.get("/loop")
  assert_eq(r.status, 302)
  // The request itself and three hops after it.
  assert_eq(hits.length(), 4)
}

///|
async test "an absolute redirect names its own host and path" {
  let app = @http.to_asgi(req => {
    match req.path {
      "/go" =>
        @http.Response::new(301, [("location", "http://other.example/x")], b"")
      _ =>
        @http.Response::new(
          200,
          [],
          @utf8.encode(req.header("host").unwrap_or("") + req.path),
        )
    }
  })
  let client = @testing.Client::new(app, follow_redirects=true)
  assert_eq(client.get("/go").text(), "other.example/x")
}

///|
/// A `secure` cookie is kept but not sent over plain HTTP, and is sent once the
/// client speaks TLS — the scheme the scope carries too.
let secure_cookie : @spec.AsgiApp = @http.to_asgi(req => {
  match req.path {
    "/login" =>
      @http.Response::new(200, [("set-cookie", "sid=abc; Secure; Path=/")], b"")
    _ =>
      @http.Response::new(
        200,
        [],
        @utf8.encode(req.header("cookie").unwrap_or("")),
      )
  }
})

///|
async test "a secure cookie waits for a secure client" {
  let plain = @testing.Client::new(secure_cookie)
  ignore(plain.get("/login"))
  assert_eq(plain.cookie("sid"), None)
  assert_eq(plain.get("/").text(), "")
  let tls = @testing.Client::new(secure_cookie, scheme="https")
  ignore(tls.get("/login"))
  assert_eq(tls.cookie("sid"), Some("abc"))
  assert_eq(tls.get("/").text(), "sid=abc")
}

///|
async test "a websocket handshake carries the jar's cookies" {
  let app : @spec.AsgiApp = async fn(scope, receive, send) {
    ignore(receive())
    let headers = match scope {
      Http(h) => h.headers
      WebSocket(w) => w.headers
      Lifespan(_) => []
    }
    let cookie = headers
      .iter()
      .find_first(pair => pair.0 == "cookie")
      .map(pair => pair.1)
      .unwrap_or("")
    send(WebSocketAccept(subprotocol=None, headers=[]))
    send(WebSocketSendText(cookie))
    send(WebSocketClose(code=1000, reason=""))
  }
  let client = @testing.Client::new(app)
  client.jar.set(name="sid", value="abc", host="testserver")
  let seen : String = client.websocket(path="/chat", session => {
    session.receive_text()
  })
  assert_eq(seen, "sid=abc")
}

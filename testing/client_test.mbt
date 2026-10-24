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

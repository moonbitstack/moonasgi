///|
/// An application that answers `<name> <root_path>|<path>`, and records its
/// lifespan in `log`.
fn echo(name : String, log? : Array[String]) -> @spec.AsgiApp {
  (scope, receive, send) => {
    match scope {
      Http(hs) => {
        send(HttpResponseStart(status=200, headers=[], trailers=false))
        send(
          HttpResponseBody(
            body=@utf8.encode("\{name} \{hs.root_path}|\{hs.path}"),
            more_body=false,
          ),
        )
      }
      WebSocket(_) => send(WebSocketClose(code=1000, reason=""))
      Lifespan(_) => {
        guard log is Some(log) else { return }
        while true {
          match receive() {
            LifespanStartup => {
              log.push("\{name} up")
              send(LifespanStartupComplete)
            }
            LifespanShutdown => {
              log.push("\{name} down")
              send(LifespanShutdownComplete)
              return
            }
            _ => return
          }
        }
      }
    }
  }
}

///|
async test "mount: whole segments, the longest prefix, the path below it" {
  let app = @dispatch.mount(
    [("/api", echo("api")), ("/api/v2", echo("v2")), ("/mcp/", echo("mcp"))],
    fallback=echo("rest"),
  )
  let client = @testing.Client::new(app)
  assert_eq(client.get("/api/users").text(), "api /api|/users")
  assert_eq(client.get("/api").text(), "api /api|/")
  assert_eq(client.get("/api/v2/x").text(), "v2 /api/v2|/x")
  assert_eq(client.get("/mcp").text(), "mcp /mcp|/")
  assert_eq(client.get("/apis").text(), "rest |/apis")
}

///|
async test "mount: nothing taken is a 404, and a mount below another root keeps it" {
  let client = @testing.Client::new(@dispatch.mount([("/api", echo("api"))]))
  let missing = client.get("/elsewhere")
  assert_eq(missing.status, 404)
  let nested = @testing.Client::new(
    @dispatch.mount([("/outer", @dispatch.mount([("/inner", echo("in"))]))]),
  )
  assert_eq(nested.get("/outer/inner/x").text(), "in /outer/inner|/x")
}

///|
async test "mount: a WebSocket nothing takes is declined" {
  let app = @dispatch.mount([("/api", echo("api"))])
  let scope = @spec.Scope::WebSocket(@spec.WebSocketScope::new(path="/nope"))
  @testing.communicate(app, scope, c => {
    c.send(WebSocketConnect)
    assert_true(c.receive() is WebSocketClose(..))
  })
}

///|
async test "hosts: exact names, wildcards below a domain, ports ignored" {
  let app = @dispatch.hosts(
    [("api.example.com", echo("api")), ("*.example.com", echo("any"))],
    fallback=echo("other"),
  )
  let client = @testing.Client::new(app)
  let at = (host : String) => client.get("/", headers=[("host", host)]).text()
  assert_eq(at("api.example.com:8443"), "api |/")
  assert_eq(at("API.Example.com"), "api |/")
  assert_eq(at("docs.example.com"), "any |/")
  assert_eq(at("example.com"), "other |/")
  let bare = @testing.Client::new(@dispatch.hosts([("a.test", echo("a"))]))
  assert_eq(bare.get("/", headers=[("host", "b.test")]).status, 404)
}

///|
async test "lifespan: startup in order, shutdown in reverse, non-takers skipped" {
  let log = []
  let app = @dispatch.mount(
    [("/a", echo("a", log~)), ("/b", echo("b")), ("/c", echo("c", log~))],
    fallback=echo("rest", log~),
  )
  let scope = @spec.Scope::Lifespan(@spec.LifespanScope::new())
  @testing.communicate(app, scope, c => {
    c.send(LifespanStartup)
    assert_true(c.receive() is LifespanStartupComplete)
    c.send(LifespanShutdown)
    assert_true(c.receive() is LifespanShutdownComplete)
  })
  assert_eq(log, ["a up", "c up", "rest up", "rest down", "c down", "a down"])
}

///|
async test "lifespan: one failed startup fails them all, with its message" {
  let refusing : @spec.AsgiApp = (_, receive, send) => {
    ignore(receive())
    send(LifespanStartupFailed(message="no database"))
  }
  let log = []
  let app = @dispatch.mount([("/a", echo("a", log~)), ("/b", refusing)])
  let scope = @spec.Scope::Lifespan(@spec.LifespanScope::new())
  @testing.communicate(app, scope, c => {
    c.send(LifespanStartup)
    assert_true(c.receive() is LifespanStartupFailed(message="no database"))
  })
  assert_eq(log, ["a up"])
}

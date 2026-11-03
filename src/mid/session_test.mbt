///|
/// A fixed clock, so a cookie signed in one call verifies in the next and a test
/// can move time forward on purpose.
let session_now : Int64 = 1_700_000_000L

///|
/// A `Sessions` layer with a known secret and a clock the test controls.
fn sessions(now~ : Int64 = session_now) -> @mid.Sessions {
  @mid.Sessions::new(secret=b"secret", clock=fn() { now })
}

///|
/// The `set-cookie` values a response carries.
fn set_cookies(events : Array[@spec.Event]) -> Array[String] {
  let (_, headers) = try start(events) catch {
    _ => return []
  } noraise {
    pair => pair
  }
  headers.filter(fn(pair) { pair.0 == "set-cookie" }).map(fn(pair) { pair.1 })
}

///|
/// An application that records what the session held when it ran and adds `name`
/// to it, as a login or a settings change does.
fn writer(name : String) -> @spec.AsgiApp {
  async fn(scope, receive, send) {
    ignore(receive())
    @mid.session(scope)[name] = Json::string("set")
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(HttpResponseBody(body=b"", more_body=false))
  }
}

///|
/// An application that answers with the keys the session held when it ran, so a
/// test can see what the layer handed it.
fn reader() -> @spec.AsgiApp {
  async fn(scope, receive, send) {
    ignore(receive())
    let keys = @mid.session(scope).keys().map(fn(key) { key }).join(",")
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(HttpResponseBody(body=@utf8.encode(keys), more_body=false))
  }
}

///|
/// A request with no cookie starts an empty session, and a response that leaves it
/// empty says nothing about cookies at all: a page a reader merely visits does not
/// hand them a session.
async test "sessions: a request without a cookie starts empty and sets nothing" {
  let app = sessions().wrap(reader())
  let events = drive(app, http("GET", "/", []))
  assert_eq(body(events), b"")
  assert_eq(set_cookies(events), [])
}

///|
/// What an application writes to the session comes back in the response cookie,
/// and the next request that carries that cookie sees it — the round trip that
/// makes a session a session.
async test "sessions: what one response writes the next request reads" {
  let layer = sessions()
  let login = drive(layer.wrap(writer("user")), http("POST", "/login", []))
  let cookies = set_cookies(login)
  assert_eq(cookies.length(), 1)
  let set_cookie = try @cookie.SetCookie::parse(cookies[0]) catch {
    _ => abort("the response carries a set-cookie")
  } noraise {
    cookie => cookie
  }
  assert_eq(set_cookie.name, "session")
  assert_eq(set_cookie.path, Some("/"))
  assert_eq(set_cookie.http_only, true)
  assert_eq(set_cookie.same_site, Some("lax"))
  assert_eq(set_cookie.max_age, Some(1_209_600))

  let events = drive(
    layer.wrap(reader()),
    http("GET", "/", [("cookie", "session=" + set_cookie.value)]),
  )
  assert_eq(body(events), b"user")
  // Reading did not change the session, so the answer carries it back unchanged.
  assert_eq(set_cookies(events).length(), 1)
}

///|
/// A cookie whose signature does not verify is no cookie: the layer hands the
/// application an empty session rather than the data an attacker edited into it.
async test "sessions: a tampered cookie is ignored" {
  let layer = sessions()
  let login = drive(layer.wrap(writer("user")), http("POST", "/login", []))
  let cookie = try @cookie.SetCookie::parse(set_cookies(login)[0]) catch {
    _ => abort("the response carries a set-cookie")
  } noraise {
    c => c
  }
  // Change one character of the payload, keeping the signature.
  let value = cookie.value
  let tampered = "x" + value[1:].to_owned()
  let events = drive(
    layer.wrap(reader()),
    http("GET", "/", [("cookie", "session=" + tampered)]),
  )
  assert_eq(body(events), b"")
  // And a cookie signed with another secret is no better.
  let other = sessions()
  let forgeries = drive(
    @mid.Sessions::new(secret=b"other", clock=fn() { session_now }).wrap(
      writer("user"),
    ),
    http("POST", "/login", []),
  )
  let forged = try @cookie.SetCookie::parse(set_cookies(forgeries)[0]) catch {
    _ => abort("the response carries a set-cookie")
  } noraise {
    c => c
  }
  let events = drive(
    other.wrap(reader()),
    http("GET", "/", [("cookie", "session=" + forged.value)]),
  )
  assert_eq(body(events), b"")
}

///|
/// A cookie older than `max_age` has aged out: fourteen days is the default, and a
/// day later it is gone.
async test "sessions: a cookie past its age is ignored" {
  let signed = drive(
    sessions().wrap(writer("user")),
    http("POST", "/login", []),
  )
  let cookie = try @cookie.SetCookie::parse(set_cookies(signed)[0]) catch {
    _ => abort("the response carries a set-cookie")
  } noraise {
    c => c
  }
  let fresh = drive(
    sessions(now=session_now + 1_209_600L).wrap(reader()),
    http("GET", "/", [("cookie", "session=" + cookie.value)]),
  )
  assert_eq(body(fresh), b"user")
  let stale = drive(
    sessions(now=session_now + 1_209_601L).wrap(reader()),
    http("GET", "/", [("cookie", "session=" + cookie.value)]),
  )
  assert_eq(body(stale), b"")
}

///|
/// A session the application empties is a session the client is told to drop: the
/// answer carries a cookie that expired at the epoch, and the next request with it
/// starts empty again.
async test "sessions: emptying the session clears the cookie" {
  let layer = sessions()
  let login = drive(layer.wrap(writer("user")), http("POST", "/login", []))
  let cookie = try @cookie.SetCookie::parse(set_cookies(login)[0]) catch {
    _ => abort("the response carries a set-cookie")
  } noraise {
    c => c
  }
  let logout : @spec.AsgiApp = async fn(scope, receive, send) {
    ignore(receive())
    @mid.session(scope).clear()
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(HttpResponseBody(body=b"", more_body=false))
  }
  let events = drive(
    layer.wrap(logout),
    http("GET", "/logout", [("cookie", "session=" + cookie.value)]),
  )
  let cleared = try @cookie.SetCookie::parse(set_cookies(events)[0]) catch {
    _ => abort("the response carries a set-cookie")
  } noraise {
    c => c
  }
  assert_eq(cleared.value, "null")
  assert_eq(cleared.max_age, Some(0))
  assert_eq(cleared.expires, Some(0L))
  // A request already carrying the cleared value starts empty: the signature is
  // over `null`, which is not the object the layer wrote.
  let events = drive(
    layer.wrap(reader()),
    http("GET", "/", [("cookie", "session=" + cleared.value)]),
  )
  assert_eq(body(events), b"")
}

///|
/// The cookie a session is written into is the layer's to name: a service that
/// runs beside another one separates them without changing any handler.
async test "sessions: the cookie name, path and flags are the layer's" {
  let layer = @mid.Sessions::new(
    secret=b"secret",
    cookie="sid",
    path="/app",
    same_site="strict",
    https_only=true,
    domain="example.com",
    clock=fn() { session_now },
  )
  let events = drive(layer.wrap(writer("user")), http("POST", "/login", []))
  let cookie = try @cookie.SetCookie::parse(set_cookies(events)[0]) catch {
    _ => abort("the response carries a set-cookie")
  } noraise {
    c => c
  }
  assert_eq(cookie.name, "sid")
  assert_eq(cookie.path, Some("/app"))
  assert_eq(cookie.domain, Some("example.com"))
  assert_eq(cookie.same_site, Some("strict"))
  assert_eq(cookie.secure, true)
}

///|
/// A WebSocket connection reads the same session: the handshake request carries
/// the cookie, and the application behind it shares the state the layer built.
async test "sessions: a websocket handshake reads the session" {
  let layer = sessions()
  let login = drive(layer.wrap(writer("user")), http("POST", "/login", []))
  let cookie = try @cookie.SetCookie::parse(set_cookies(login)[0]) catch {
    _ => abort("the response carries a set-cookie")
  } noraise {
    c => c
  }
  let seen : Array[String] = []
  let app : @spec.AsgiApp = async fn(scope, _receive, send) {
    seen.push(@mid.session(scope).keys().map(fn(k) { k }).join(","))
    send(@spec.WebSocketAccept(subprotocol=None, headers=[]))
    send(@spec.WebSocketClose(code=1000, reason=""))
  }
  let scope = @spec.WebSocket(
    @spec.WebSocketScope::new(path="/chat", headers=[
      ("cookie", "session=" + cookie.value),
    ]),
  )
  let events = drive(layer.wrap(app), scope, inbound=[@spec.WebSocketConnect])
  assert_eq(seen, ["user"])
  assert_eq(events.length(), 2)
}

///|
/// A lifespan run has no cookies and no session to write: the layer leaves it
/// alone, so a service that boots with a session layer still boots.
async test "sessions: a lifespan scope passes through" {
  let layer = sessions()
  let seen : Array[String] = []
  let app : @spec.AsgiApp = async fn(_scope, receive, send) {
    let event = receive()
    seen.push("startup")
    send(@spec.LifespanStartupComplete)
    ignore(event)
  }
  let events = drive(
    layer.wrap(app),
    @spec.Lifespan(@spec.LifespanScope::new()),
    inbound=[@spec.LifespanStartup],
  )
  assert_eq(seen, ["startup"])
  assert_eq(events, [LifespanStartupComplete])
}

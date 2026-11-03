///|
/// A backend that reads a bearer token out of the `authorization` header and looks
/// it up: the rule most services need, written as a function.
fn bearer(tokens : Map[String, String]) -> @mid.BackendFn {
  @mid.BackendFn(fn(scope) {
    let headers = match scope {
      Http(h) => h.headers
      WebSocket(w) => w.headers
      Lifespan(_) => []
    }
    for pair in headers {
      if pair.0.to_lower() == "authorization" && pair.1.has_prefix("Bearer ") {
        let token = pair.1[7:].to_owned()
        match tokens.get(token) {
          Some(name) =>
            return {
              user: Some(Json::object(Map([("name", Json::string(name))]))),
              auth: Some(
                Json::object(Map([("scheme", Json::string("bearer"))])),
              ),
            }
          None => ()
        }
      }
    }
    @mid.Identity::anonymous()
  })
}

///|
/// The name the layer resolved for a connection, as a handler reads it out of the
/// scope.
fn identity_name(scope : @spec.Scope) -> String? {
  match @mid.user(scope) {
    Some(Object(fields)) =>
      match fields.get("name") {
        Some(String(name)) => Some(name)
        _ => None
      }
    _ => None
  }
}

///|
/// An application that answers with the name the layer resolved, so a test reads
/// what a handler would.
fn whoami() -> @spec.AsgiApp {
  async fn(scope, receive, send) {
    ignore(receive())
    let name = identity_name(scope).unwrap_or("nobody")
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(HttpResponseBody(body=@utf8.encode(name), more_body=false))
  }
}

///|
/// A connection with no credentials reaches the application unidentified, and the
/// scope says so rather than saying nothing.
async test "auth: a request without credentials is anonymous" {
  let layer = @mid.Auth::new(bearer(Map([("t0ken", "ada")])))
  let events = drive(layer.wrap(whoami()), http("GET", "/", []))
  assert_eq(body(events), b"nobody")
  assert_eq(identity_name(http("GET", "/", [])), None)
}

///|
/// A request the backend recognises reaches the application with the identity
/// resolved, under the key a handler reads.
async test "auth: a recognised token reaches the handler as a user" {
  let layer = @mid.Auth::new(bearer(Map([("t0ken", "ada")])))
  let events = drive(
    layer.wrap(whoami()),
    http("GET", "/", [("authorization", "Bearer t0ken")]),
  )
  assert_eq(body(events), b"ada")
  // An unknown token is not an identity either.
  let unknown = drive(
    layer.wrap(whoami()),
    http("GET", "/", [("authorization", "Bearer nope")]),
  )
  assert_eq(body(unknown), b"nobody")
}

///|
/// The layer writes both keys, `user` and `auth`, every time: a handler reads
/// `auth` for the record the decision came from, and `null` when the backend kept
/// none. The key is there holding null rather than absent, so a handler can tell
/// an unidentified connection from a service with no auth layer.
async test "auth: both keys are on the scope, filled or null" {
  let layer = @mid.Auth::new(bearer(Map([("t0ken", "ada")])))
  let seen : Array[Json] = []
  let app : @spec.AsgiApp = async fn(scope, receive, send) {
    ignore(receive())
    match scope {
      Http(h) => seen.push(h.state["user"])
      WebSocket(w) => seen.push(w.state["user"])
      Lifespan(l) => seen.push(l.state["user"])
    }
    seen.push(@mid.user(scope).unwrap_or(Json::null()))
    seen.push(@mid.auth(scope).unwrap_or(Json::null()))
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(HttpResponseBody(body=b"", more_body=false))
  }
  ignore(drive(layer.wrap(app), http("GET", "/", [])))
  assert_eq(seen, [Json::null(), Json::null(), Json::null()])

  seen.clear()
  ignore(
    drive(
      layer.wrap(app),
      http("GET", "/", [("authorization", "Bearer t0ken")]),
    ),
  )
  match seen[0] {
    Object(fields) => assert_eq(fields.get("name"), Some(Json::string("ada")))
    _ => abort("the user is an object")
  }
  match seen[2] {
    Object(fields) =>
      assert_eq(fields.get("scheme"), Some(Json::string("bearer")))
    _ => abort("the auth record is an object")
  }
}

///|
/// A backend that reads the session is how a browser stays identified between
/// requests, and it needs the session layer to be the outer one.
async test "auth: a backend reads the session the outer layer wrote" {
  let login : @spec.AsgiApp = async fn(scope, receive, send) {
    ignore(receive())
    @mid.session(scope)["user"] = Json::string("ada")
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(HttpResponseBody(body=b"", more_body=false))
  }
  let sessions = @mid.Sessions::new(secret=b"secret", clock=fn() { session_now })
  let signed = drive(sessions.wrap(login), http("POST", "/login", []))
  let cookie = try @cookie.SetCookie::parse(set_cookies(signed)[0]) catch {
    _ => abort("the response carries a set-cookie")
  } noraise {
    c => c
  }
  let from_session = @mid.BackendFn(fn(scope) {
    match @mid.session(scope).get("user") {
      Some(name) => @mid.Identity::of(Json::object(Map([("name", name)])))
      None => @mid.Identity::anonymous()
    }
  })
  let app = sessions.wrap(@mid.Auth::new(from_session).wrap(whoami()))
  let known = drive(
    app,
    http("GET", "/", [("cookie", "session=" + cookie.value)]),
  )
  assert_eq(body(known), b"ada")
  assert_eq(body(drive(app, http("GET", "/", []))), b"nobody")
}

///|
/// The layer sees a WebSocket handshake with the same keys, since a chat
/// connection is identified by the same request that opened it.
async test "auth: a websocket handshake is identified too" {
  let layer = @mid.Auth::new(bearer(Map([("t0ken", "ada")])))
  let seen : Array[String] = []
  let app : @spec.AsgiApp = async fn(scope, _receive, send) {
    seen.push(identity_name(scope).unwrap_or("nobody"))
    send(@spec.WebSocketAccept(subprotocol=None, headers=[]))
    send(@spec.WebSocketClose(code=1000, reason=""))
  }
  let scope = @spec.WebSocket(
    @spec.WebSocketScope::new(path="/chat", headers=[
      ("authorization", "Bearer t0ken"),
    ]),
  )
  ignore(drive(layer.wrap(app), scope, inbound=[@spec.WebSocketConnect]))
  assert_eq(seen, ["ada"])
}

///|
/// The lifespan has no credentials and no identity; the layer leaves it alone.
async test "auth: a lifespan scope passes through" {
  let layer = @mid.Auth::new(bearer(Map([])))
  let events = drive(
    layer.wrap(async fn(_scope, _receive, send) {
      send(@spec.LifespanStartupComplete)
    }),
    @spec.Lifespan(@spec.LifespanScope::new()),
    inbound=[@spec.LifespanStartup],
  )
  assert_eq(events, [@spec.LifespanStartupComplete])
}

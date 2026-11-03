///|
/// A session and an identity, carried by cookies:
///
///     moon run src/examples/19-session --target native
///
/// A login writes the session, the response signs it into a cookie, and the next
/// request reads it back — no store on the server, only the secret. The identity
/// is resolved from that session by a backend, once per connection, so every
/// handler below reads the same `user` without asking again.
#coverage.skip
async fn main {
  tour() catch {
    e => println("failed: \{e}")
  }
}

///|
/// The seconds since the epoch this example pretends it is, so the signed cookie
/// and its `Max-Age` come out the same on every run.
let fixed_now : Int64 = 1_700_000_000L

///|
/// Answers `POST /login` by putting a name in the session, `POST /logout` by
/// emptying it, and `GET /me` with whatever identity the auth layer resolved.
/// A login answers with a `303`, the way a form post does, so the browser's next
/// request is a `GET`.
#coverage.skip
let app : @moonasgi.AsgiApp = async fn(scope, receive, send) {
  let (http_method, path) = match scope {
    Http(h) => (h.http_method, h.path)
    _ => ("", "")
  }
  // Drain the request body: a server hands it over only when asked.
  let mut more = true
  while more {
    match receive() {
      HttpRequest(more_body~, ..) => more = more_body
      _ => more = false
    }
  }
  match (http_method, path) {
    ("POST", "/login") => {
      @mid.session(scope)["user"] = Json::string("ada")
      send(
        HttpResponseStart(
          status=303,
          headers=[("location", "/me")],
          trailers=false,
        ),
      )
      send(HttpResponseBody(body=b"", more_body=false))
    }
    ("POST", "/logout") => {
      // An emptied session tells the client to drop its cookie.
      @mid.session(scope).clear()
      send(
        HttpResponseStart(
          status=303,
          headers=[("location", "/me")],
          trailers=false,
        ),
      )
      send(HttpResponseBody(body=b"", more_body=false))
    }
    ("GET", "/me") => {
      let who = match @mid.user(scope) {
        Some(Object(fields)) =>
          match fields.get("name") {
            Some(String(name)) => name
            _ => "nobody"
          }
        _ => "nobody"
      }
      send(HttpResponseStart(status=200, headers=[], trailers=false))
      send(
        HttpResponseBody(body=@utf8.encode("you are " + who), more_body=false),
      )
    }
    _ => {
      send(HttpResponseStart(status=404, headers=[], trailers=false))
      send(HttpResponseBody(body=b"not found", more_body=false))
    }
  }
}

///|
/// The rule that turns a session into an identity: whoever the session names is
/// the user of the connection.
#coverage.skip
let from_session : &@mid.Backend = @mid.BackendFn(fn(scope) {
  match @mid.session(scope).get("user") {
    Some(name) => @mid.Identity::of(Json::object(Map([("name", name)])))
    None => @mid.Identity::anonymous()
  }
})

///|
#coverage.skip
async fn tour() -> Unit {
  let sessions = @mid.Sessions::new(secret=b"a secret only the server knows", clock=fn() {
    fixed_now
  })
  // The session layer is the outer one: the backend inside it reads what it wrote.
  let service = sessions.wrap(@mid.Auth::new(from_session).wrap(app))
  let client = @testing.Client::new(service, follow_redirects=true, clock=fn() {
    fixed_now
  })
  println("before logging in:     " + client.get("/me").text())
  // The login's own answer is the redirect, and the redirect is followed to /me.
  println("after logging in:      " + client.post("/login").text())
  println(
    "the jar holds:         " + client.cookies().map(fn(p) { p.0 }).join(", "),
  )
  // What the signature buys: a cookie a client edited is not a session.
  let cookie = client.cookie("session").unwrap_or("")
  let edited = "x" + cookie[1:].to_owned()
  let stranger = @testing.Client::new(service, clock=fn() { fixed_now })
  println(
    "with an edited cookie: " +
    stranger.get("/me", headers=[("cookie", "session=" + edited)]).text(),
  )
  println("after logging out:     " + client.post("/logout").text())
  println(
    "the jar holds:         " + client.cookies().map(fn(p) { p.0 }).join(", "),
  )
}

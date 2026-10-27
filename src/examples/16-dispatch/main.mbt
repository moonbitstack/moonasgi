///|
/// Three applications behind one, the way a single server carries an API, an
/// MCP endpoint and a site:
///
///     moon run src/examples/16-dispatch --target native
///
/// `mount` sends each request to the application whose path prefix it falls
/// under, longest prefix first, and tells that application where it is mounted
/// through `root_path`. `hosts` does the same by host name. The lifespan reaches
/// every application, so each opens what it needs at startup. Around the whole
/// thing, `ProxyHeaders` restores the client a reverse proxy saw and `BodyLimit`
/// refuses oversized uploads.
#coverage.skip
async fn main {
  tour() catch {
    e => println("failed: \{e}")
  }
}

///|
/// An application that names itself, the path it was given and where it is
/// mounted, and says when its lifespan starts and stops.
#coverage.skip
fn named(name : String) -> @spec.AsgiApp {
  async fn(scope, receive, send) {
    match scope {
      Http(hs) => {
        let client = match hs.client {
          Some((host, _)) => host
          None => "-"
        }
        let text = "\{name}: path \{hs.path}, mounted at \{hs.root_path}, client \{client}, \{hs.scheme}"
        send(HttpResponseStart(status=200, headers=[], trailers=false))
        send(HttpResponseBody(body=@utf8.encode(text), more_body=false))
      }
      Lifespan(_) =>
        while true {
          match receive() {
            LifespanStartup => {
              println("  \{name} started")
              send(LifespanStartupComplete)
            }
            LifespanShutdown => {
              println("  \{name} stopped")
              send(LifespanShutdownComplete)
              break
            }
            _ => break
          }
        }
      WebSocket(_) => send(WebSocketClose(code=1000, reason=""))
    }
  }
}

///|
#coverage.skip
async fn tour() -> Unit {
  // One application per prefix; the site takes everything else.
  let site = @dispatch.mount(
    [
      ("/api", named("api")),
      ("/api/v2", named("api v2")),
      ("/mcp", named("mcp")),
    ],
    fallback=named("site"),
  )
  // A second host serves only the documentation.
  let by_host = @dispatch.hosts(
    [("docs.example.com", named("docs"))],
    fallback=site,
  )
  // Behind a reverse proxy on this machine, with uploads capped at 64 bytes.
  let app = @mid.stack(
    [@mid.ProxyHeaders::new(), @mid.BodyLimit::new(limit=64)],
    by_host,
  )
  let client = @testing.Client::new(app, client=Some(("127.0.0.1", 50000)))
  client.lifespan(async fn() {
    println("requests:")
    for path in ["/api/users", "/api/v2/users", "/mcp", "/apis", "/"] {
      println("  GET \{path} -> " + client.get(path).text())
    }
    let docs = client.get("/guide", headers=[("host", "docs.example.com")])
    println("  GET docs.example.com/guide -> " + docs.text())
    let proxied = client.get("/api/me", headers=[
      ("x-forwarded-for", "203.0.113.7"),
      ("x-forwarded-proto", "https"),
    ])
    println("  GET /api/me through the proxy -> " + proxied.text())
    let big = client.post("/api/upload", body=Bytes::make(100, b'x'))
    println("  POST 100 bytes -> \{big.status} \{big.text()}")
    println("lifespan:")
  })
}

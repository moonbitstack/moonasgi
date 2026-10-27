///|
/// Run `app` on `scope`, feeding it `inbound` and collecting what it sends.
async fn drive(
  app : @spec.AsgiApp,
  scope : @spec.Scope,
  inbound? : Array[@spec.Event],
) -> Array[@spec.Event] {
  let queue = inbound.unwrap_or([HttpRequest(body=b"", more_body=false)])
  let out : Array[@spec.Event] = []
  app(
    scope,
    async fn() {
      @async.pause()
      if queue.length() > 0 {
        queue.remove(0)
      } else {
        HttpDisconnect
      }
    },
    async fn(e) {
      @async.pause()
      out.push(e)
    },
  )
  out
}

///|
fn http(
  verb : String,
  path : String,
  headers : Array[(String, String)],
  scheme? : String,
  query? : String,
) -> @spec.Scope {
  Http(
    @spec.HttpScope::new(
      http_method=verb,
      path~,
      headers~,
      scheme=scheme.unwrap_or("http"),
      query_string=@utf8.encode(query.unwrap_or("")),
    ),
  )
}

///|
/// An application that answers with `body` in the given pieces, under `headers`.
fn answering(
  pieces : Array[Bytes],
  headers? : Array[(String, String)],
) -> @spec.AsgiApp {
  async fn(_, receive, send) {
    ignore(receive())
    send(
      HttpResponseStart(
        status=200,
        headers=headers.unwrap_or([("content-type", "text/plain")]),
        trailers=false,
      ),
    )
    for i, piece in pieces {
      send(HttpResponseBody(body=piece, more_body=i < pieces.length() - 1))
    }
  }
}

///|
fn start(events : Array[@spec.Event]) -> (Int32, Array[(String, String)]) raise {
  for e in events {
    match e {
      HttpResponseStart(status~, headers~, ..)
      | WebSocketHttpResponseStart(status~, headers~, ..) =>
        return (status, headers)
      _ => ()
    }
  }
  fail("no start")
}

///|
fn body(events : Array[@spec.Event]) -> Bytes {
  let out = Buffer()
  for e in events {
    match e {
      HttpResponseBody(body~, ..) | WebSocketHttpResponseBody(body~, ..) =>
        out.write_bytes(body)
      _ => ()
    }
  }
  out.to_bytes()
}

///|
fn value(headers : Array[(String, String)], name : String) -> String? {
  headers.iter().find_first(h => h.0 == name).map(h => h.1)
}

///|
let hello : @spec.AsgiApp = answering([b"hello"])

///|
async test "cors: a request without an origin is untouched" {
  let app = @mid.Cors::new(origins=["https://a.example"]).wrap(hello)
  let (status, headers) = start(drive(app, http("GET", "/", [])))
  assert_eq(status, 200)
  assert_eq(value(headers, "access-control-allow-origin"), None)
}

///|
async test "cors: a listed origin is echoed with vary, an unlisted one gets nothing" {
  let app = @mid.Cors::new(origins=["https://a.example"], expose=["x-total"]).wrap(
    hello,
  )
  let (_, ok) = start(
    drive(app, http("GET", "/", [("origin", "https://a.example")])),
  )
  assert_eq(value(ok, "access-control-allow-origin"), Some("https://a.example"))
  assert_eq(value(ok, "vary"), Some("Origin"))
  assert_eq(value(ok, "access-control-expose-headers"), Some("x-total"))
  let (_, no) = start(
    drive(app, http("GET", "/", [("origin", "https://b.example")])),
  )
  assert_eq(value(no, "access-control-allow-origin"), None)
}

///|
async test "cors: any origin is a star, unless the request carries a cookie" {
  let app = @mid.Cors::new(origins=["*"]).wrap(hello)
  let (_, plain) = start(
    drive(app, http("GET", "/", [("origin", "https://b.example")])),
  )
  assert_eq(value(plain, "access-control-allow-origin"), Some("*"))
  let (_, cookie) = start(
    drive(
      app,
      http("GET", "/", [("origin", "https://b.example"), ("cookie", "s=1")]),
    ),
  )
  assert_eq(
    value(cookie, "access-control-allow-origin"),
    Some("https://b.example"),
  )
}

///|
async test "cors: a preflight is answered here, 200 when allowed, 400 naming what is not" {
  let app = @mid.Cors::new(
    origins=["https://a.example"],
    methods=["GET", "POST"],
    headers=["x-token"],
    credentials=true,
  ).wrap(hello)
  let preflight = (origin, verb, asked) => {
    http("OPTIONS", "/", [
      ("origin", origin),
      ("access-control-request-method", verb),
      ("access-control-request-headers", asked),
    ])
  }
  let ok = drive(
    app,
    preflight("https://a.example", "POST", "X-Token, content-type"),
  )
  let (status, headers) = start(ok)
  assert_eq(status, 200)
  assert_eq(body(ok), b"OK")
  assert_eq(
    value(headers, "access-control-allow-origin"),
    Some("https://a.example"),
  )
  assert_eq(value(headers, "access-control-allow-methods"), Some("GET, POST"))
  assert_eq(
    value(headers, "access-control-allow-headers"),
    Some("accept, accept-language, content-language, content-type, x-token"),
  )
  assert_eq(value(headers, "access-control-allow-credentials"), Some("true"))
  assert_eq(value(headers, "access-control-max-age"), Some("600"))
  let no = drive(app, preflight("https://b.example", "DELETE", "x-other"))
  assert_eq(start(no).0, 400)
  assert_eq(body(no), b"Disallowed CORS origin, method, headers")
}

///|
async test "cors: allowed headers star echoes what the preflight asked for" {
  let app = @mid.Cors::new(origins=["*"], headers=["*"]).wrap(hello)
  let (status, headers) = start(
    drive(
      app,
      http("OPTIONS", "/", [
        ("origin", "https://z.example"),
        ("access-control-request-method", "GET"),
        ("access-control-request-headers", "x-anything"),
      ]),
    ),
  )
  assert_eq(status, 200)
  assert_eq(value(headers, "access-control-allow-headers"), Some("x-anything"))
  assert_eq(value(headers, "access-control-allow-origin"), Some("*"))
}

///|
let big : Bytes = Bytes::makei(4000, i => (i % 26 + 97).to_byte())

///|
async test "gzip: a large single body is compressed when gzip is accepted" {
  let app = @mid.gzip.wrap(answering([big]))
  let events = drive(app, http("GET", "/", [("accept-encoding", "gzip, br")]))
  let (_, headers) = start(events)
  assert_eq(value(headers, "content-encoding"), Some("gzip"))
  assert_eq(value(headers, "vary"), Some("Accept-Encoding"))
  let packed = body(events)
  assert_eq(value(headers, "content-length"), Some(packed.length().to_string()))
  assert_true(packed.length() < big.length())
  assert_eq(@gzip.gunzip(packed[:]), big)
}

///|
async test "gzip: small, unaccepted, already encoded, streamed and event-stream bodies pass" {
  let accept = [("accept-encoding", "gzip")]
  let cases : Array[(@spec.AsgiApp, Array[(String, String)])] = [
    (@mid.gzip.wrap(answering([b"tiny"])), accept),
    (@mid.gzip.wrap(answering([big])), []),
    (
      @mid.gzip.wrap(answering([big], headers=[("content-encoding", "br")])),
      accept,
    ),
    (@mid.gzip.wrap(answering([big, big])), accept),
    (
      @mid.gzip.wrap(
        answering([big], headers=[("content-type", "text/event-stream")]),
      ),
      accept,
    ),
  ]
  for case in cases {
    let (app, headers) = case
    let events = drive(app, http("GET", "/", headers))
    assert_true(
      value(start(events).1, "content-encoding") is (None | Some("br")),
    )
    assert_true(body(events).length() >= 4)
  }
  let lowered = @mid.Gzip::new(minimum=1).wrap(answering([b"tiny body"]))
  let (_, headers) = start(drive(lowered, http("GET", "/", accept)))
  assert_eq(value(headers, "content-encoding"), Some("gzip"))
}

///|
async test "trusted hosts: listed and wildcard hosts pass, others are refused" {
  let app = @mid.TrustedHosts::new(hosts=["a.example", "*.b.example"]).wrap(
    hello,
  )
  for host in ["a.example", "a.example:8080", "x.b.example"] {
    assert_eq(start(drive(app, http("GET", "/", [("host", host)]))).0, 200)
  }
  let refused = drive(app, http("GET", "/", [("host", "evil.example")]))
  assert_eq(start(refused).0, 400)
  assert_eq(body(refused), b"Invalid host header")
}

///|
async test "trusted hosts: a bare domain goes to its listed www, and a WebSocket is denied" {
  let app = @mid.TrustedHosts::new(hosts=["www.c.example"]).wrap(hello)
  let (status, headers) = start(
    drive(
      app,
      http("GET", "/path", [("host", "c.example")], query="q=1", scheme="https"),
    ),
  )
  assert_eq(status, 307)
  assert_eq(value(headers, "location"), Some("https://www.c.example/path?q=1"))
  let ws : @spec.Scope = WebSocket(
    @spec.WebSocketScope::new(path="/ws", headers=[("host", "evil.example")]),
  )
  let denied = drive(app, ws, inbound=[WebSocketConnect])
  assert_true(denied[0] is WebSocketHttpResponseStart(status=400, ..))
}

///|
async test "https redirect: plain schemes go to secure ones, default ports dropped" {
  let app = @mid.https_redirect.wrap(hello)
  let cases = [
    ("a.example", "https://a.example/p?x=1"),
    ("a.example:80", "https://a.example/p?x=1"),
    ("a.example:8080", "https://a.example:8080/p?x=1"),
  ]
  for case in cases {
    let (host, location) = case
    let (status, headers) = start(
      drive(app, http("POST", "/p", [("host", host)], query="x=1")),
    )
    assert_eq(status, 307)
    assert_eq(value(headers, "location"), Some(location))
  }
  assert_eq(
    start(drive(app, http("GET", "/", [("host", "a.example")], scheme="https"))).0,
    200,
  )
  let ws : @spec.Scope = WebSocket(
    @spec.WebSocketScope::new(path="/ws", headers=[("host", "a.example")]),
  )
  let (_, headers) = start(drive(app, ws, inbound=[WebSocketConnect]))
  assert_eq(value(headers, "location"), Some("wss://a.example/ws"))
}

///|
let broken : @spec.AsgiApp = async fn(_, _, _) {
  @async.pause()
  fail("boom")
}

///|
async test "server errors: a failure before the answer is a 500, and still raised" {
  let sent : Array[@spec.Event] = []
  let app = @mid.server_errors.wrap(broken)
  let raised = try
    app(
      http("GET", "/", []),
      async fn() {
        @async.pause()
        HttpDisconnect
      },
      async fn(e) {
        @async.pause()
        sent.push(e)
      },
    )
  catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(raised)
  assert_eq(start(sent).0, 500)
  assert_eq(body(sent), b"Internal Server Error")
}

///|
async test "server errors: debug shows the error, a handler writes its own answer, a started answer is left alone" {
  let run = async fn(app : @spec.AsgiApp) -> Array[@spec.Event] {
    let sent : Array[@spec.Event] = []
    app(
      http("GET", "/", []),
      async fn() {
        @async.pause()
        HttpDisconnect
      },
      async fn(e) {
        @async.pause()
        sent.push(e)
      },
    ) catch {
      _ => ()
    }
    sent
  }
  let debug = run(@mid.ServerErrors::new(debug=true).wrap(broken))
  assert_true(@utf8.decode_lossy(body(debug)[:]).contains("boom"))
  let handled = run(
    @mid.ServerErrors::new(handler=_ => (503, [("retry-after", "1")], "later")).wrap(
      broken,
    ),
  )
  assert_eq(start(handled).0, 503)
  assert_eq(body(handled), b"later")
  let late : @spec.AsgiApp = async fn(_, _, send) {
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    fail("after the start")
  }
  let started = run(@mid.server_errors.wrap(late))
  assert_eq(started.length(), 1)
  assert_eq(start(started).0, 200)
}

///|
async test "stack: the first layer is outermost, and a plain function is a layer" {
  let order : Array[String] = []
  let tag = (name : String) => {
    @mid.Wrap(inner => {
      async fn(scope, receive, send) {
        order.push(name)
        inner(scope, receive, send)
      }
    })
  }
  let app = @mid.stack([tag("outer"), tag("inner"), @mid.gzip], hello)
  ignore(drive(app, http("GET", "/", [])))
  assert_eq(order, ["outer", "inner"])
}

///|
test "three ways to say the same settings agree" {
  assert_eq(@mid.Cors::new(max_age=60), { ..@mid.cors, max_age: 60, })
  assert_eq(@mid.Gzip::new(level=1), { ..@mid.gzip, level: 1, })
  assert_eq(@mid.TrustedHosts::new(www_redirect=false), {
    ..@mid.trusted_hosts,
    www_redirect: false,
  })
}

///|
/// An application that answers with the client and scheme its scope carries.
fn reporting() -> @spec.AsgiApp {
  async fn(scope, _, send) {
    let (client, scheme) = match scope {
      Http(h) => (h.client, h.scheme)
      WebSocket(w) => (w.client, w.scheme)
      Lifespan(_) => (None, "")
    }
    let who = match client {
      Some((host, _)) => host
      None => "-"
    }
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(
      HttpResponseBody(body=@utf8.encode("\{who} \{scheme}"), more_body=false),
    )
  }
}

///|
fn from_peer(peer : String, headers : Array[(String, String)]) -> @spec.Scope {
  Http(
    @spec.HttpScope::new(
      http_method="GET",
      path="/",
      headers~,
      client=(peer, 50000),
    ),
  )
}

///|
fn body_text(events : Array[@spec.Event]) -> String {
  let out = StringBuilder()
  for e in events {
    if e is HttpResponseBody(body~, ..) {
      out.write_string(@utf8.decode_lossy(body[:]))
    }
  }
  out.to_string()
}

///|
async test "proxy headers: a trusted proxy names the client and the scheme" {
  let app = @mid.ProxyHeaders::new().wrap(reporting())
  let got = drive(
    app,
    from_peer("127.0.0.1", [
      ("x-forwarded-for", "203.0.113.7, 127.0.0.1"),
      ("x-forwarded-proto", "https"),
    ]),
  )
  assert_eq(body_text(got), "203.0.113.7 https")
}

///|
async test "proxy headers: an untrusted peer is taken at its word, not the header's" {
  let app = @mid.ProxyHeaders::new().wrap(reporting())
  let got = drive(
    app,
    from_peer("198.51.100.9", [
      ("x-forwarded-for", "1.2.3.4"),
      ("x-forwarded-proto", "https"),
    ]),
  )
  assert_eq(body_text(got), "198.51.100.9 http")
}

///|
async test "proxy headers: the rightmost untrusted hop, and RFC 7239 Forwarded" {
  let app = @mid.ProxyHeaders::new(trusted=["10.0.0.1", "10.0.0.2"]).wrap(
    reporting(),
  )
  let chained = drive(
    app,
    from_peer("10.0.0.1", [
      ("x-forwarded-for", "6.6.6.6, 203.0.113.7, 10.0.0.2"),
    ]),
  )
  assert_eq(body_text(chained), "203.0.113.7 http")
  let forwarded = drive(
    app,
    from_peer("10.0.0.1", [
      ("forwarded", "for=\"[2001:db8::7]:4711\";proto=https, for=10.0.0.2"),
    ]),
  )
  assert_eq(body_text(forwarded), "2001:db8::7 https")
  let anyone = @mid.ProxyHeaders::new(trusted=["*"]).wrap(reporting())
  let wild = drive(
    anyone,
    from_peer("9.9.9.9", [("x-forwarded-for", "203.0.113.7")]),
  )
  assert_eq(body_text(wild), "203.0.113.7 http")
}

///|
async test "proxy headers: a WebSocket's scheme becomes wss" {
  let app = @mid.ProxyHeaders::new().wrap(reporting())
  let scope = @spec.Scope::WebSocket(
    @spec.WebSocketScope::new(
      path="/",
      headers=[("x-forwarded-proto", "https")],
      client=("127.0.0.1", 1),
    ),
  )
  assert_eq(body_text(drive(app, scope, inbound=[])), "127.0.0.1 wss")
}

///|
/// An application that reads the whole body and answers with its length.
fn counting() -> @spec.AsgiApp {
  async fn(_, receive, send) {
    let mut total = 0
    while true {
      match receive() {
        HttpRequest(body~, more_body~) => {
          total += body.length()
          if !more_body {
            break
          }
        }
        _ => break
      }
    }
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(
      HttpResponseBody(body=@utf8.encode(total.to_string()), more_body=false),
    )
  }
}

///|
async test "body limit: a declared length over the limit never reaches the app" {
  let app = @mid.BodyLimit::new(limit=10).wrap(counting())
  let got = drive(app, http("POST", "/", [("content-length", "11")]))
  assert_true(got is [HttpResponseStart(status=413, ..), ..])
  assert_eq(body_text(got), "Content Too Large")
}

///|
async test "body limit: a streamed body over the limit is cut off with a 413" {
  let app = @mid.BodyLimit::new(limit=10).wrap(counting())
  let got = drive(app, http("POST", "/", []), inbound=[
    HttpRequest(body=b"123456", more_body=true),
    HttpRequest(body=b"789012", more_body=false),
  ])
  assert_true(got is [HttpResponseStart(status=413, ..), HttpResponseBody(..)])
  let fits = drive(app, http("POST", "/", [("content-length", "10")]), inbound=[
    HttpRequest(body=b"1234567890", more_body=false),
  ])
  assert_eq(body_text(fits), "10")
}

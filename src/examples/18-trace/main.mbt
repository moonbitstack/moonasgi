// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Watch a request cross the seam: every inbound event the application pulls and
/// every outbound event it pushes, in the order they happen, printed as JSON.
///
///     moon run src/examples/18-trace > docs/assets/traces.json
///
/// The documentation site plays this back as an event timeline. Nothing here is
/// scripted: each scenario drives the real cores — `to_asgi`, `ws_run`,
/// `run_lifespan`, `dispatch.mount`, `wsgi.to_asgi`, the middleware stack — with
/// a `receive` and a `send` that record what passes through them.
#coverage.skip
async fn main {
  @async.pause()
  let scenarios : Array[Json] = [
    hello(),
    chunked(),
    streaming(),
    layers(),
    routes(),
    boot(),
    legacy(),
    socket(),
    letters(),
  ]
  println(
    Json::object({ "scenarios": Json::array(scenarios) }).stringify(indent=2),
  )
}

///|
/// The steps one scenario recorded, in order.
struct Rec {
  steps : Array[Json]
}

///|
fn Rec::new() -> Rec {
  { steps: [], }
}

///|
fn Rec::add(
  self : Rec,
  lane : String,
  title : String,
  body : String,
  note : String,
) -> Unit {
  self.steps.push(
    Json::object({
      "lane": Json::string(lane),
      "title": Json::string(title),
      "body": Json::string(body),
      "note": Json::string(note),
    }),
  )
}

///|
/// A scenario as the page needs it: what was asked, what happened, what came back.
fn scenario(
  id : String,
  title : String,
  request : String,
  blurb : String,
  rec : Rec,
  result : String,
) -> Json {
  Json::object({
    "id": Json::string(id),
    "title": Json::string(title),
    "request": Json::string(request),
    "blurb": Json::string(blurb),
    "result": Json::string(result),
    "steps": Json::array(rec.steps),
  })
}

///|
/// The connection over which one scenario runs: the inbound events still to be
/// pulled, and the outbound ones already pushed.
struct Driver {
  inbound : Array[@spec.Event]
  out : Array[@spec.Event]
  rec : Rec
  mut at : Int32
}

///|
fn Driver::new(inbound : Array[@spec.Event], rec : Rec) -> Driver {
  { inbound, out: [], rec, at: 0, }
}

///|
/// The `receive` an application is handed: it records the pull, and returns the
/// next event the server would have delivered.
fn Driver::receive(self : Driver) -> @spec.Receive {
  async fn() {
    @async.pause()
    let event = self.inbound[self.at]
    self.at = self.at + 1
    self.rec.add(
      "in",
      event_title(event),
      event_body(event),
      "the application pulls the next event in",
    )
    event
  }
}

///|
/// The `send` an application is handed: it records the push.
fn Driver::send(self : Driver) -> @spec.Send {
  async fn(event) {
    @async.pause()
    self.out.push(event)
    self.rec.add(
      "out",
      event_title(event),
      event_body(event),
      "the application pushes it back to the server",
    )
  }
}

///|
fn event_title(event : @spec.Event) -> String {
  match event {
    HttpRequest(_) => "http.request"
    HttpDisconnect => "http.disconnect"
    HttpResponseStart(_) => "http.response.start"
    HttpResponseBody(_) => "http.response.body"
    HttpResponseTrailers(_) => "http.response.trailers"
    HttpResponsePush(_) => "http.response.push"
    HttpResponsePathSend(_) => "http.response.pathsend"
    HttpResponseZeroCopySend(_) => "http.response.zerocopysend"
    HttpResponseDebug(_) => "http.response.debug"
    HttpResponseEarlyHint(_) => "http.response.early_hint"
    WebSocketConnect => "websocket.connect"
    WebSocketReceive(_) => "websocket.receive"
    WebSocketDisconnect(_) => "websocket.disconnect"
    WebSocketAccept(_) => "websocket.accept"
    WebSocketSendText(_) => "websocket.send"
    WebSocketSendBytes(_) => "websocket.send"
    WebSocketClose(_) => "websocket.close"
    WebSocketHttpResponseStart(_) => "websocket.http.response.start"
    WebSocketHttpResponseBody(_) => "websocket.http.response.body"
    LifespanStartup => "lifespan.startup"
    LifespanShutdown => "lifespan.shutdown"
    LifespanStartupComplete => "lifespan.startup.complete"
    LifespanStartupFailed(_) => "lifespan.startup.failed"
    LifespanShutdownComplete => "lifespan.shutdown.complete"
    LifespanShutdownFailed(_) => "lifespan.shutdown.failed"
    Other(type_~, ..) => type_
  }
}

///|
fn event_body(event : @spec.Event) -> String {
  match event {
    HttpRequest(body~, more_body~) =>
      "body \{body.length()} B · more_body \{more_body}"
    HttpResponseStart(status~, headers~, trailers~) =>
      "\{status} · \{headers.length()} headers · trailers \{trailers}"
    HttpResponseBody(body~, more_body~) =>
      "body \{body.length()} B · more_body \{more_body}"
    HttpResponseTrailers(headers~, ..) => "\{headers.length()} headers"
    HttpResponsePush(path~, ..) => path
    HttpResponseEarlyHint(links~) => "\{links.length()} links"
    WebSocketReceive(text~, bytes~) =>
      match (text, bytes) {
        (Some(s), _) => "text · \{@utf8.encode(s).length()} B"
        (None, Some(b)) => "binary · \{b.length()} B"
        _ => ""
      }
    WebSocketDisconnect(code~, reason~) =>
      "code \{code} · reason \{reason.unwrap_or("none")}"
    WebSocketAccept(subprotocol~, headers~) =>
      "subprotocol \{subprotocol.unwrap_or("none")} · \{headers.length()} headers"
    WebSocketSendText(text) => "text · \{@utf8.encode(text).length()} B"
    WebSocketSendBytes(bytes) => "binary · \{bytes.length()} B"
    WebSocketClose(code~, reason~) => "code \{code} · \{reason}"
    LifespanStartupFailed(message~) | LifespanShutdownFailed(message~) =>
      message
    _ => ""
  }
}

///|
fn scope_line(scope : @spec.HttpScope) -> String {
  "\{scope.http_method} \{scope.path} · HTTP/\{scope.http_version} · \{scope.scheme}"
}

///|
/// A `Handler` lifted onto the seam, driven once: the plainest possible request.
async fn hello() -> Json {
  @async.pause()
  let rec = Rec::new()
  let greet : @moonasgi.Handler = fn(request) {
    rec.add(
      "app",
      "the handler runs",
      "\{request.http_method} \{request.path}",
      "it sees a plain request, not a scope: method, path, headers, body",
    )
    @moonasgi.Response::text("hello from the seam")
  }
  let scope = @spec.HttpScope::new(
    http_method="GET",
    path="/notes",
    scheme="http",
    headers=[("host", "example.test"), ("accept", "text/plain")],
    client=("203.0.113.7", 52333),
  )
  rec.add(
    "scope",
    "scope",
    scope_line(scope),
    "the server builds one scope per request and hands it over",
  )
  let driver = Driver::new([HttpRequest(body=b"", more_body=false)], rec)
  @moonasgi.to_asgi(greet)(Http(scope), driver.receive(), driver.send())
  scenario(
    "hello", "A handler answers", "GET /notes", "One handler, lifted onto the seam. The scope goes in, the body is pulled, two events come out.",
    rec, "200 · 19 B · hello from the seam",
  )
}

///|
/// A body that arrives in pieces: `receive` is pulled twice before the answer.
async fn chunked() -> Json {
  @async.pause()
  let rec = Rec::new()
  let echo : @moonasgi.Handler = fn(request) {
    rec.add(
      "app",
      "the handler runs",
      "\{request.body.length()} B of body",
      "the seam drained every chunk first, so the handler reads one buffer",
    )
    @moonasgi.Response::new(
      201,
      [("content-type", "application/json")],
      request.body,
    )
  }
  let scope = @spec.HttpScope::new(http_method="POST", path="/items", headers=[
    ("host", "example.test"),
    ("content-type", "application/json"),
  ])
  rec.add(
    "scope",
    "scope",
    scope_line(scope),
    "a streamed upload, cut into two events",
  )
  let driver = Driver::new(
    [
      HttpRequest(body=b"{\"name\": ", more_body=true),
      HttpRequest(body=b"\"ada\"}", more_body=false),
    ],
    rec,
  )
  @moonasgi.to_asgi(echo)(Http(scope), driver.receive(), driver.send())
  scenario(
    "chunked", "A body arrives in pieces", "POST /items", "The client sends the body in two events. The application pulls until `more_body` is false.",
    rec, "201 · 15 B · {\"name\": \"ada\"}",
  )
}

///|
/// A streaming answer: early hints first, then the body in chunks, then trailers.
fn streaming() -> Json {
  let rec = Rec::new()
  let scope = @spec.HttpScope::new(
    http_method="GET",
    path="/feed",
    scheme="http",
  )
  rec.add(
    "scope",
    "scope",
    scope_line(scope) + " · early_hint and trailers advertised",
    "the server said it honours both extensions, so the response may use them",
  )
  let in_flight = Driver::new([HttpRequest(body=b"", more_body=false)], rec)
  in_flight.rec.add(
    "in", "http.request", "body 0 B · more_body false", "no request body to read",
  )
  let response = @moonasgi.StreamingResponse::new(
    chunks=[b"tick 1\n", b"tick 2\n", b"tick 3\n"],
    headers=[("content-type", "text/plain; charset=utf-8")],
    trailers=[("x-checksum", "9f2c")],
    early_hints=[["</style.css>; rel=preload; as=style"]],
  )
  for event in response.events() {
    in_flight.out.push(event)
    in_flight.rec.add(
      "out",
      event_title(event),
      event_body(event),
      "lowered from the streaming response, in wire order",
    )
  }
  scenario(
    "streaming", "A streamed answer", "GET /feed", "A 103 goes out before the headers, three chunks follow, and the trailers close the body.",
    rec, "200 · 3 chunks · 21 B · trailers x-checksum",
  )
}

///|
/// Middleware around an application: the request goes in through every layer and
/// the answer comes back out through them in reverse.
async fn layers() -> Json {
  @async.pause()
  let rec = Rec::new()
  let app : @spec.AsgiApp = async fn(_, receive, send) {
    @async.pause()
    ignore(receive())
    rec.add(
      "app", "the application answers", "200 · 2 KiB of text", "the innermost thing in the stack is the only one that knows about the site",
    )
    send(
      HttpResponseStart(
        status=200,
        headers=[("content-type", "text/plain; charset=utf-8")],
        trailers=false,
      ),
    )
    send(HttpResponseBody(body=Bytes::make(2048, b'a'), more_body=false))
  }
  let around = fn(name : String, layer : &@mid.Layer) {
    @mid.Wrap(inner => {
      let wrapped = layer.wrap(inner)
      async fn(scope, receive, send) {
        @async.pause()
        rec.add(
          "mw",
          "→ " + name,
          "the request enters this layer",
          "each layer wraps the next, so the first given is the outermost",
        )
        wrapped(scope, receive, send)
        rec.add(
          "mw",
          "← " + name,
          "the answer leaves through it",
          "on the way out the order reverses",
        )
      }
    })
  }
  let stack : @spec.AsgiApp = @mid.stack(
    [
      around("ServerErrors", @mid.server_errors),
      around("Gzip", @mid.gzip),
      around("Cors", @mid.cors),
    ],
    app,
  )
  let scope = @spec.HttpScope::new(
    http_method="GET",
    path="/",
    scheme="https",
    headers=[
      ("host", "example.test"),
      ("accept-encoding", "gzip"),
      ("origin", "https://app.example.test"),
    ],
  )
  rec.add(
    "scope",
    "scope",
    scope_line(scope),
    "the layers below see the same scope",
  )
  stack(
    Http(scope),
    async fn() {
      @async.pause()
      HttpRequest(body=b"", more_body=false)
    },
    async fn(event) {
      @async.pause()
      rec.add(
        "out",
        event_title(event),
        event_body(event),
        "the stack let it through after the layers had their turn",
      )
    },
  )
  scenario(
    "layers", "Wrapped in middleware", "GET / · accept-encoding: gzip", "Server errors, gzip and CORS wrap the application. The request goes in, the compressed answer comes back out.",
    rec, "200 · 34 B gzip · 2 KiB before compression",
  )
}

///|
/// Several applications behind one: a path prefix picks one, a host name picks
/// another.
async fn routes() -> Json {
  @async.pause()
  let rec = Rec::new()
  let named = fn(name : String) -> @spec.AsgiApp {
    async fn(scope, receive, send) {
      @async.pause()
      let line = match scope {
        Http(hs) => "\{hs.http_method} \{hs.path} · root_path \{hs.root_path}"
        _ => ""
      }
      rec.add(
        "app", name, line, "the dispatcher rewrote the path below the prefix and extended root_path",
      )
      ignore(receive())
      send(
        HttpResponseStart(status=200, headers=[("x-app", name)], trailers=false),
      )
      send(HttpResponseBody(body=@utf8.encode(name), more_body=false))
    }
  }
  let by_path = @dispatch.mount([
    ("/api", named("the api")),
    ("/mcp", named("the mcp endpoint")),
  ])
  let api_scope = @spec.HttpScope::new(http_method="GET", path="/api/items")
  rec.add(
    "scope",
    "scope",
    scope_line(api_scope),
    "one server, three applications behind it",
  )
  let api = Driver::new([HttpRequest(body=b"", more_body=false)], rec)
  by_path(Http(api_scope), api.receive(), api.send())
  let by_host = @dispatch.hosts(
    [("docs.example.test", named("the docs host"))],
    fallback=by_path,
  )
  let docs_scope = @spec.HttpScope::new(http_method="GET", path="/", headers=[
    ("host", "docs.example.test"),
  ])
  rec.add(
    "scope", "scope", "GET / · host docs.example.test", "the same server, picking on the Host header this time",
  )
  let docs = Driver::new([HttpRequest(body=b"", more_body=false)], rec)
  by_host(Http(docs_scope), docs.receive(), docs.send())
  let unmatched = @spec.HttpScope::new(http_method="GET", path="/nowhere")
  rec.add("scope", "scope", scope_line(unmatched), "a path no prefix takes")
  let miss = Driver::new([HttpRequest(body=b"", more_body=false)], rec)
  by_path(Http(unmatched), miss.receive(), miss.send())
  scenario(
    "routes", "One server, several applications", "GET /api/items · GET / with host docs.example.test",
    "A prefix picks the API, a host name picks the docs site, and a path no prefix takes is answered 404.",
    rec, "200 the api · 200 the docs host · 404",
  )
}

///|
/// Startup and shutdown across every application behind one: in order on the way
/// up, in reverse on the way down.
async fn boot() -> Json {
  @async.pause()
  let rec = Rec::new()
  let service = fn(name : String) -> @spec.AsgiApp {
    async fn(scope, receive, send) {
      @async.pause()
      guard scope is Lifespan(_) else { return }
      guard receive() is LifespanStartup else { return }
      rec.add(
        "app",
        name + " starts",
        "opens what it needs",
        "startup runs in the order the applications were given",
      )
      send(LifespanStartupComplete)
      guard receive() is LifespanShutdown else { return }
      rec.add(
        "app",
        name + " stops",
        "releases what it opened",
        "shutdown runs in reverse, so what started last stops first",
      )
      send(LifespanShutdownComplete)
    }
  }
  let apps : Array[@spec.AsgiApp] = [
    service("the api"),
    service("the mcp endpoint"),
    service("the site"),
  ]
  rec.add(
    "scope", "scope", "lifespan · spec 2.0", "one lifespan run for all three applications behind the server",
  )
  let driver = Driver::new([LifespanStartup, LifespanShutdown], rec)
  @dispatch.lifespan(
    apps,
    @spec.LifespanScope::new(),
    driver.receive(),
    driver.send(),
  )
  scenario(
    "boot", "Booting three applications", "lifespan.startup · lifespan.shutdown",
    "One lifespan drives all three applications: startup in order, shutdown in reverse.",
    rec, "startup complete · shutdown complete",
  )
}

///|
/// A synchronous application adapted to the same event stream.
async fn legacy() -> Json {
  @async.pause()
  let rec = Rec::new()
  let app : @wsgi.WsgiApp = (environ, start_response) => {
    rec.add(
      "app",
      "the synchronous application runs",
      "\{environ.request_method} \{environ.path_info}",
      "it is handed CGI-style variables, not a scope, and yields its body",
    )
    ignore(start_response("200 OK", [("Content-Type", "text/plain")]))
    [@utf8.encode("hello from "), @utf8.encode(environ.path_info)].iter()
  }
  let scope = @spec.HttpScope::new(
    http_method="GET",
    path="/legacy/greet",
    root_path="/legacy",
  )
  rec.add(
    "scope",
    "scope",
    scope_line(scope) + " · root_path /legacy",
    "the adapter lowers the scope to the variables a synchronous application expects",
  )
  let driver = Driver::new([HttpRequest(body=b"", more_body=false)], rec)
  @wsgi.to_asgi(app)(Http(scope), driver.receive(), driver.send())
  scenario(
    "legacy", "A synchronous application", "GET /legacy/greet", "An application written the old synchronous way, adapted onto the same events as everything else.",
    rec, "200 · 24 B · hello from /greet",
  )
}

///|
/// A WebSocket connection: the handshake, two frames each way, a close.
fn socket() -> Json {
  let rec = Rec::new()
  let scope = @spec.WebSocketScope::new(
    path="/chat",
    subprotocols=["chat.v2", "chat.v1"],
    headers=[("host", "example.test")],
  )
  rec.add(
    "scope", "scope", "websocket /chat · offers chat.v2, chat.v1", "a WebSocket scope is the http one plus the subprotocols on offer",
  )
  let inbound : Array[@spec.Event] = [
    WebSocketConnect,
    WebSocketReceive(text=Some("hello"), bytes=None),
    WebSocketReceive(text=None, bytes=Some(b"\x01\x02")),
    WebSocketDisconnect(code=1000, reason=Some("done")),
  ]
  for event in inbound {
    rec.add(
      "in",
      event_title(event),
      event_body(event),
      "one event per thing the client did",
    )
  }
  let handler = @moonasgi.WebSocketHandler::new(
    on_connect=fn(scope) {
      let chosen = scope.select_subprotocol(["chat.v2"])
      rec.add(
        "app",
        "the handler accepts",
        "subprotocol \{chosen.unwrap_or("none")}",
        "it picks one of the subprotocols the client offered",
      )
      Accept(subprotocol=chosen, headers=[])
    },
    on_receive=fn(message) {
      match message {
        Text(text) => {
          rec.add(
            "app", "the handler echoes", text, "every frame is answered on the spot",
          )
          [SendText(text)]
        }
        Binary(bytes) => {
          rec.add(
            "app",
            "the handler acknowledges",
            "\{bytes.length()} B binary",
            "binary frames are answered in kind",
          )
          [SendBinary(bytes)]
        }
      }
    },
    on_disconnect=fn(code, reason) {
      rec.add(
        "app",
        "the handler sees the disconnect",
        "code \{code} · reason \{reason.unwrap_or("none")}",
        "the close code and reason arrive together",
      )
      []
    },
  )
  for event in @moonasgi.ws_run(handler, WebSocket(scope), inbound) {
    rec.add(
      "out",
      event_title(event),
      event_body(event),
      "the WebSocket core lowers what the handler returned",
    )
  }
  scenario(
    "socket", "A WebSocket conversation", "GET /chat · Upgrade: websocket", "A handshake with a subprotocol, one text frame and one binary frame each way, then a clean close.",
    rec, "accepted chat.v2 · 2 frames echoed",
  )
}

///|
fn h2_error(error : @spec.Http2HeaderError) -> String {
  match error {
    MissingMethod => "missing :method"
    MissingScheme => "missing :scheme"
    MissingPath => "missing :path"
    EmptyPath => "empty :path"
    DuplicatePseudoHeader(name) => "duplicate " + name
    UnknownPseudoHeader(name) => "unknown " + name
    PseudoHeaderAfterRegular(name) => name + " after an ordinary field"
  }
}

///|
/// The same request on a multiplexed transport: the request line arrives as
/// pseudo-headers and is lowered into the typed scope.
fn letters() -> Json {
  let rec = Rec::new()
  let block : Array[(String, String)] = [
    (":method", "POST"),
    (":scheme", "https"),
    (":authority", "example.test"),
    (":path", "/items?page=2"),
    ("content-type", "application/json"),
  ]
  for header in block {
    rec.add(
      "in",
      header.0,
      header.1,
      if header.0.has_prefix(":") {
        "a pseudo-header: part of the request line, not a header the application sees"
      } else {
        "an ordinary field, passed through as it came"
      },
    )
  }
  match @spec.HttpScope::from_h2_headers(block) {
    Ok(scope) => {
      rec.add("scope", "http_method", scope.http_method, "lowered from :method")
      rec.add(
        "scope",
        "path",
        scope.path,
        "lowered from :path, query split off",
      )
      rec.add(
        "scope",
        "query_string",
        @moonasgi.latin1_decode(scope.query_string),
        "the part after ? in :path",
      )
      rec.add(
        "scope",
        "headers",
        "\{scope.headers.length()} · host \{scope.headers[0].1}",
        "host is synthesised from :authority; no colon-prefixed header survives",
      )
    }
    Err(error) =>
      rec.add("scope", "rejected", h2_error(error), "a malformed set is named")
  }
  scenario(
    "letters", "A request on HTTP/2", "POST /items?page=2 · :authority example.test",
    "An HTTP/2 or HTTP/3 request carries its request line as pseudo-headers. Lowering them is part of the seam.",
    rec, "POST /items · page=2 · host example.test",
  )
}

<div align="center">

# moonasgi

**The ASGI 3.0 seam for MoonBit.**<br>
A scope goes in, an event stream comes out, and the transport stays out of your code.

<a href="https://moonbitstack.github.io/moonasgi/"><kbd> &nbsp;Documentation&nbsp; </kbd></a>
&nbsp;
<a href="https://moonbitstack.github.io/moonasgi/guide.html"><kbd> &nbsp;Guide&nbsp; </kbd></a>
&nbsp;
<a href="https://moonbitstack.github.io/moonasgi/api.html"><kbd> &nbsp;API reference&nbsp; </kbd></a>
&nbsp;
<a href="https://mooncakes.io/docs/moonbitstack/moonasgi"><kbd> &nbsp;mooncakes&nbsp; </kbd></a>

</div>

---

A server receives bytes and produces events. An application reads events and produces more. `moonasgi` is the agreement between them: three scopes, one event set, and the callables that carry them.

Nothing here owns a socket. That means the same application runs behind a real server, inside a test, and on every backend a MoonBit program compiles to.

## Install

```
moon add moonbitstack/moonasgi
```

## A first handler

```moonbit
let greet : @moonasgi.Handler = fn(_request) {
  @moonasgi.Response::text("hello")
}

let client = @moonasgi.TestClient::new(greet)
let response = client.get("/")

assert_eq(response.status, 200)
assert_eq(response.text(), "hello")
```

`TestClient` runs the handler in-process: it builds a scope, feeds the request in, and reassembles what comes out. No socket, no async runtime, no server.

## The interface

| Name | What it is |
|:--|:--|
| `Scope` | `Http` · `WebSocket` · `Lifespan` — the connection, as typed data |
| `Event` | Every message in both directions, one variant each, extensions included |
| `Receive` | `async () -> Event` — pull the next event in |
| `Send` | `async (Event) -> Unit` — push the next event out |
| `AsgiApp` | `async (Scope, Receive, Send) -> Unit` — an application |
| `Handler` | `(Request) -> Response` — the short form a server lifts onto `AsgiApp` |
| `Middleware` | `(Handler) -> Handler` — one handler wrapped around another |

The scopes and the event set are the specification itself: `HttpScope` carries the method, path, raw query, headers as string pairs, the peers, `root_path`, `state` and `extensions`; `WebSocketScope` adds the subprotocols on offer; `LifespanScope` carries the state a startup seeds.

## Running without a server

A synchronous core drives an application for each shape of connection, so a whole request can happen inside a test:

| Core | Drives |
|:--|:--|
| `run_http` | a `Handler` over a scope and an inbound event list |
| `run_http_scoped` | a scope-level application, with the full `HttpScope` |
| `run_http_stream` | a `StreamingResponse`, lowered to the wire order |
| `ws_run` | a WebSocket connection, connect to close |
| `run_lifespan` | startup and shutdown, in the order a server runs them |

```moonbit
let scope = @moonasgi.Scope::Http(
  @moonasgi.HttpScope::new(http_method="GET", path="/"),
)
let inbound = [@moonasgi.Event::HttpRequest(body=b"", more_body=false)]
let events = @moonasgi.run_http(greet, scope, inbound)

assert_eq(events.length(), 2)
assert_eq(@moonasgi.validate_events(scope, events) is None, true)
```

## Responses

```moonbit
let plain = @moonasgi.Response::text("hello")
let created = @moonasgi.Response::json(status=201, Json({ "id": 233 }))
let hand_built = @moonasgi.Response::new(204, [("x-trace", "1")], b"")

assert_eq(plain.header("content-type"), Some("text/plain; charset=utf-8"))
assert_eq(created.header("content-type"), Some("application/json"))
assert_eq(hand_built.status, 204)
```

A body sent in pieces, hints before the headers, or trailers at the end is a `StreamingResponse`:

```moonbit
let feed : @moonasgi.StreamHandler = fn(_request) {
  @moonasgi.StreamingResponse::new(
    status=200,
    headers=[("content-type", "text/event-stream")],
    chunks=[b"data: 233\n\n", b"data: done\n\n"],
    trailers=[("x-digest", "9f2c")],
    early_hints=[["</style.css>; rel=preload"]],
  )
}

let stream_client = @moonasgi.TestClient::from_stream(feed)
let stream = stream_client.get("/events")

assert_eq(stream.body, b"data: 233\n\ndata: done\n\n")
assert_eq(stream.trailer("x-digest"), Some("9f2c"))
assert_eq(stream.early_hints.length(), 1)
```

`events()` lowers it to the exact sequence a server writes: `103`, then the start, then each chunk, then the trailers. The client reassembles the chunks into one body and keeps the trailers and the hints apart, so a test can assert on any of them.

## WebSocket

```moonbit
let chat = @moonasgi.WebSocketHandler::new(
  on_connect=fn(_scope) {
    @ws.WsAccept::Accept(subprotocol=Some("chat.v1"), headers=[])
  },
  on_receive=fn(message) {
    match message {
      @ws.WsMessage::Text(text) => [@ws.WsSend::SendText("echo:" + text)]
      @ws.WsMessage::Binary(bytes) => [@ws.WsSend::SendBinary(bytes)]
    }
  },
)

let session = @moonasgi.TestClient::new(greet).websocket(
  path="/chat",
  handler=chat,
  send=[@ws.WsMessage::Text("hi")],
)

assert_eq(session.accepted, true)
assert_eq(session.subprotocol, Some("chat.v1"))
assert_eq(session.texts(), ["echo:hi"])
```

Connect can answer `Accept` (with a subprotocol and headers), `Reject` (a close code), or `DenyHttp` (a whole HTTP response). `ws_run` drives the same handler over a raw event list:

```moonbit
let raw = @moonasgi.ws_run(
  chat,
  @moonasgi.Scope::WebSocket(@moonasgi.WebSocketScope::new(path="/chat")),
  [
    @moonasgi.Event::WebSocketConnect,
    @moonasgi.Event::WebSocketReceive(text=Some("hi"), bytes=None),
    @moonasgi.Event::WebSocketDisconnect(code=1000, reason=None),
  ],
)

assert_eq(@moonasgi.validate_ws_response(raw) is None, true)
```

## Lifespan

```moonbit
let lifecycle = @moonasgi.LifespanHandler::new(
  on_startup=fn(scope) {
    scope.state["db_pool"] = Json::string("pool://main")
    Complete
  },
  on_shutdown=fn(_scope) { Complete },
)

let boot = @moonasgi.LifespanScope::new()
let replies = @moonasgi.run_lifespan(
  lifecycle,
  @moonasgi.Scope::Lifespan(boot),
  [@moonasgi.Event::LifespanStartup, @moonasgi.Event::LifespanShutdown],
)

assert_eq(replies.length(), 2)
assert_eq(boot.state.get("db_pool"), Some(Json::string("pool://main")))
```

Startup seeds `scope.state` in place. A server copies that map onto every request scope, so a pool or a loaded config reaches a handler without a global. A failed startup ends the boot: the server never proceeds to shutdown.

## Middleware

`mid` wraps any application, whatever built it.

| Middleware | What it does | Default |
|:--|:--|:--|
| `cors` | Answers preflights, echoes the origin, exposes headers | no origin, `GET` |
| `gzip` | Compresses a single-message body that is large enough | 500 octets, level 9 |
| `trusted_hosts` | Refuses other `Host` values, redirects to `www.` | any host, redirect on |
| `https_redirect` | `http` to `https`, `ws` to `wss`, by 307 | — |
| `proxy_headers` | Restores the client and scheme from a trusted proxy | trusts `127.0.0.1` |
| `body_limit` | Answers 413 over the limit, by length or as it streams | 1 MiB |
| `rate_limit` | Answers 429 with `Retry-After` when a client's token bucket is empty | 2 a second, bursts of 8, by client address |
| `server_errors` | A 500 when the answer has not started, then the error on | no detail |
| `sessions` | Signs the session into a cookie, and reads it back | 14 days, `SameSite=Lax` |
| `auth` | Resolves an identity once per connection, onto the scope | no backend |

The stack is a list, first element outermost, and it drives a whole request:

```moonbit
let app : @moonasgi.AsgiApp = async fn(_scope, receive, send) {
  ignore(receive())
  send(@moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false))
  send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
}

let stacked = @mid.stack(
  [
    @mid.server_errors,
    @mid.TrustedHosts::new(hosts=["example.com"]),
    @mid.cors,
    @mid.gzip,
  ],
  app,
)

let statuses : Array[Int32] = []
for host in ["example.com", "evil.example"] {
  stacked(
    @moonasgi.Scope::Http(
      @moonasgi.HttpScope::new(
        http_method="GET",
        path="/",
        headers=[("host", host)],
      ),
    ),
    async fn() { @moonasgi.Event::HttpRequest(body=b"", more_body=false) },
    async fn(event) {
      if event is @moonasgi.Event::HttpResponseStart(status~, ..) {
        statuses.push(status)
      }
    },
  )
}

assert_eq(statuses, [200, 400])
```

Each is a record, so a preset can be adjusted in place — `{ ..@mid.gzip, level: 1 }` says the same as `Gzip::new(level=1)`. Your own middleware is a `Wrap`, or a record implementing `Layer`, and stacks with the rest.

### Sessions and identity

A session lives in the cookie, signed with a secret, so a server keeps nothing: a restart loses no session, and a second server behind the same secret already knows every one of them. `session` is the map a handler reads and writes.

```moonbit
let sessions : @mid.Sessions = @mid.Sessions::new(
  secret=@utf8.encode("a secret only the server knows"),
)

let login : @moonasgi.AsgiApp = async fn(scope, receive, send) {
  ignore(receive())
  @mid.session(scope)["user"] = Json::string("ada")
  send(
    @moonasgi.Event::HttpResponseStart(
      status=303,
      headers=[("location", "/me")],
      trailers=false,
    ),
  )
  send(@moonasgi.Event::HttpResponseBody(body=b"", more_body=false))
}
```

The signature is the timestamped HMAC form Python's services already use, so a cookie either side wrote the other can read. An emptied session answers with a cookie that has already expired, and a cookie that does not verify is no session at all.

Identity is a separate step, and a backend answers it:

```moonbit
let backend : &@mid.Backend = @mid.BackendFn(fn(scope) {
  match @mid.session(scope).get("user") {
    Some(name) => @mid.Identity::of(Json::object(Map([("name", name)])))
    None => @mid.Identity::anonymous()
  }
})

let guarded = sessions.wrap(@mid.Auth::new(backend).wrap(login))
```

`user` and `auth` then sit in `scope.state` for every handler below, holding `null` when nobody was identified. Put the session layer outside the auth layer: the backend sees what it wrote.

## Several applications behind one

```moonbit
fn const_app(body : String) -> @moonasgi.AsgiApp {
  async fn(_scope, receive, send) {
    ignore(receive())
    send(@moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false))
    send(
      @moonasgi.Event::HttpResponseBody(
        body=@utf8.encode(body),
        more_body=false,
      ),
    )
  }
}
```

```moonbit
let mounted = @dispatch.mount([
  ("/api", const_app("api")),
  ("/mcp", const_app("mcp")),
])
let by_host = @dispatch.hosts(
  [("docs.example.com", const_app("docs"))],
  fallback=mounted,
)

let bodies : Array[String] = []
mounted(
  @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(http_method="GET", path="/api/items"),
  ),
  async fn() { @moonasgi.Event::HttpRequest(body=b"", more_body=false) },
  async fn(event) {
    if event is @moonasgi.Event::HttpResponseBody(body~, ..) {
      bodies.push(@utf8.decode_lossy(body))
    }
  },
)

assert_eq(bodies, ["api"])
```

`mount` matches whole path segments and prefers the longest prefix; the chosen application sees the path below its prefix, with `root_path` extended. `hosts` matches the `Host` header, and `*.example.com` covers a domain. A path or host nothing takes is answered 404, or a declined handshake on a WebSocket.

The lifespan reaches every application behind the dispatcher: startup in order, shutdown in reverse, and one failed startup fails the whole boot.

## Synchronous applications

```moonbit
let legacy : @wsgi.WsgiApp = (environ, start_response) => {
  ignore(start_response("200 OK", [("Content-Type", "text/plain")]))
  [@utf8.encode("hello from "), @utf8.encode(environ.path_info)].iter()
}

let legacy_app : @moonasgi.AsgiApp = @wsgi.to_asgi(legacy)
```

`Environ` carries the CGI variables as fields, and `to_map` gives them under their usual names. The request body is read before the application runs; each chunk it yields is sent as it comes, and the `write` callable works too.

```moonbit
let environ = @wsgi.Environ::of(
  @moonasgi.HttpScope::new(http_method="GET", path="/old"),
  b"",
)

assert_eq(environ.path_info, "/old")
assert_eq(environ.to_map().get("REQUEST_METHOD"), Some("GET"))
```

## Extensions

The optional parts of the specification are typed, not stringly keyed: `http.response.push`, `pathsend`, `zerocopysend`, `early_hint`, `debug`, `trailers`, `websocket.http.response`, and `tls`.

```moonbit
let extensions = @moonasgi.Extensions::none().enable_push().enable_early_hint()

assert_eq(extensions.http_response_push, true)
assert_eq(extensions.http_response_trailers, false)

let custom = @moonasgi.Extensions::none().enable("http.fullflush")
assert_eq(custom.get("http.fullflush") is Some(_), true)
```

A server advertises them on the scope's `extensions`, and an application checks the flag before emitting the matching event. An extension the specification does not name goes in the same map, by name.

## HTTP/2 and HTTP/3

`http_version` on a scope is `"1.0"`, `"1.1"`, `"2"` or `"3"`, and an application runs unchanged on any of them. The request line is the one place the transport shows through: on a multiplexed connection it arrives as pseudo-headers.

```moonbit
let parsed = @moonasgi.HttpScope::from_h2_headers([
  (":method", "POST"),
  (":scheme", "https"),
  (":authority", "example.test"),
  (":path", "/items?page=2"),
])

match parsed {
  Ok(scope) => {
    assert_eq(scope.http_method, "POST")
    assert_eq(scope.path, "/items")
    assert_eq(scope.query_string, b"page=2")
  }
  Err(_) => abort("the pseudo-headers did not parse")
}
```

The pseudo-headers are consumed into the typed fields, `host` is synthesised from `:authority`, and a malformed set is refused with the first thing wrong with it.

## Checking a run

The same ordering rules a server enforces are available to a test, and the harness runs them on itself — 436 round-trip and ordering checks:

```moonbit
let report = @moonasgi.run_conformance()

assert_eq(report.ok(), true)
assert_eq(report.failures.length(), 0)
```

An async application is driven the same way, one event at a time, with `testing`:

```moonbit
let minimal : @moonasgi.AsgiApp = async fn(_scope, receive, send) {
  ignore(receive())
  send(@moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false))
  send(@moonasgi.Event::HttpResponseBody(body=b"", more_body=false))
}

let stepped : Array[String] = []
@testing.communicate(
  minimal,
  @moonasgi.Scope::Http(@moonasgi.HttpScope::new(http_method="GET", path="/")),
  c => {
    c.send(@moonasgi.Event::HttpRequest(body=b"", more_body=false))
    while true {
      let event = c.receive() catch {
        @testing.Finished => break
        e => raise e
      }
      stepped.push(event.kind())
    }
  },
)

assert_eq(stepped, ["http.response.start", "http.response.body"])
```

## Packages

| Package | What is in it |
|:--|:--|
| `moonbitstack/moonasgi` | Everything below, re-exported under one import |
| `…/spec` | The scopes, the events, the extensions, the HTTP/2 lowering |
| `…/http` | `Request`, `Response`, `StreamingResponse`, the HTTP cores |
| `…/ws` | `WebSocketHandler`, `WsAccept`, `WsMessage`, `ws_run` |
| `…/lifespan` | `LifespanHandler` and `run_lifespan` |
| `…/client` | `TestClient` for handlers and WebSocket sessions |
| `…/cookie` | Request cookie pairs, `Set-Cookie` lines, and a jar |
| `…/mid` | The middleware stack and the layers above |
| `…/dispatch` | `mount`, `hosts` and a shared lifespan |
| `…/wsgi` | A synchronous application on the same events |
| `…/testing` | A real `AsgiApp` driven in-process, event by event |
| `…/conform` | The conformance harness and the ordering rules |

The seam itself has no dependencies. `mid` uses a compression package, a regular expression engine and a hash; `testing` and `dispatch` use an async runtime for their event loop.

## Examples

<details>
<summary><b>Twenty programs, one per feature</b></summary>

Each is a runnable package under [`src/examples`](src/examples):

```bash
moon run src/examples/00-hello
```

| # | Example | Shows |
|:--|:--|:--|
| 00 | [`hello`](src/examples/00-hello) | A handler, a test client, and the same handler on the raw seam |
| 01 | [`responses`](src/examples/01-responses) | Text, JSON, bytes, custom status and headers |
| 02 | [`request-methods`](src/examples/02-request-methods) | Every verb, the request line, a streamed body |
| 03 | [`middleware`](src/examples/03-middleware) | A chain of handler transformers, outermost first |
| 04 | [`streaming`](src/examples/04-streaming) | Chunks, trailers and 103 Early Hints |
| 05 | [`scope`](src/examples/05-scope) | The full scope a framework binds to |
| 06 | [`extensions`](src/examples/06-extensions) | Capability flags and the extension events |
| 07 | [`websocket`](src/examples/07-websocket) | Accept, reject, deny, echo |
| 08 | [`lifespan`](src/examples/08-lifespan) | Startup seeding state, and a failed boot |
| 09 | [`validate`](src/examples/09-validate) | Naming the first ordering violation |
| 10 | [`http2`](src/examples/10-http2) | Lowering a HEADERS block |
| 11 | [`headers`](src/examples/11-headers) | The latin-1 header codec |
| 12 | [`conformance`](src/examples/12-conformance) | The harness, run |
| 13 | [`legacy`](src/examples/13-legacy) | The older double-callable shape |
| 14 | [`stack`](src/examples/14-stack) | Real middleware around a real application |
| 15 | [`testing`](src/examples/15-testing) | An async application tested in-process |
| 16 | [`dispatch`](src/examples/16-dispatch) | Three applications behind one |
| 17 | [`wsgi`](src/examples/17-wsgi) | A synchronous application, mounted |
| 18 | [`trace`](src/examples/18-trace) | Every event of a request, in order |
| 19 | [`session`](src/examples/19-session) | A session in a signed cookie, and an identity read from it |

</details>

## License

Apache-2.0.

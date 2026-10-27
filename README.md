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
println("\{response.status} \{response.text()}")
```

```
200 hello
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

The scopes and the event set are the specification itself: `HttpScope` carries the method, path, raw query, headers as byte pairs, the peers, `root_path`, `state` and `extensions`; `WebSocketScope` adds the subprotocols on offer; `LifespanScope` carries the state a startup seeds.

## Running without a server

Five cores drive an application synchronously, so a whole request can happen inside a test:

| Core | Drives |
|:--|:--|
| `run_http` | a `Handler` over a scope and an inbound event list |
| `run_http_scoped` | a scope-level application, with the full `HttpScope` |
| `run_http_stream` | a `StreamingResponse`, lowered to the wire order |
| `ws_run` | a WebSocket connection, connect to close |
| `run_lifespan` | startup and shutdown, in the order a server runs them |

```moonbit
let answer = @moonasgi.run_http(greet, scope, inbound)   // Array[Event]
```

## Responses

```moonbit
@moonasgi.Response::text("hello")                      // 200, text/plain
@moonasgi.Response::json(status=201, { "id": 233 })     // any status
@moonasgi.Response::new(204, [("x-trace", "1")], b"")   // headers and raw bytes
```

A body that arrives in pieces, hints before the headers, or trailers at the end is a `StreamingResponse`:

```moonbit
@moonasgi.StreamingResponse::new(
  status=200,
  headers=[("content-type", "text/event-stream")],
  chunks=[b"data: 233\n\n", b"data: done\n\n"],
  trailers=[("x-digest", "9f2c")],
  early_hints=[["</style.css>; rel=preload"]],
)
```

`events()` lowers it to the exact sequence a server writes: `103`, then the start, then each chunk, then the trailers.

## WebSocket

```moonbit
let handler = @moonasgi.WebSocketHandler::new(
  on_receive=fn(message) {
    match message {
      Text(text) => [SendText("echo:" + text)]
      Binary(bytes) => [SendBinary(bytes)]
    }
  },
)
```

Connect can answer `Accept` (with a subprotocol and headers), `Reject` (a close code), or `DenyHttp` (a whole HTTP response). `ws_run` drives a connection; `TestClient::websocket` captures it as a `WsTestSession`.

## Lifespan

```moonbit
let lifecycle = @moonasgi.LifespanHandler::new(
  on_startup=fn(scope) {
    scope.state["db_pool"] = Json::string("pool://main")
    Complete
  },
  on_shutdown=fn(_scope) { Complete },
)
```

Startup seeds `scope.state` in place. A server copies that map onto every request scope, so a pool or a loaded config reaches a handler without a global. A failed startup ends the boot.

## Middleware

`mid` wraps any application, whatever built it. Seven ship with the package:

| Middleware | What it does | Default |
|:--|:--|:--|
| `cors` | Answers preflights, echoes the origin, exposes headers | no origin, `GET` |
| `gzip` | Compresses a single-message body that is large enough | 500 octets, level 9 |
| `trusted_hosts` | Refuses other `Host` values, redirects to `www.` | any host, redirect on |
| `https_redirect` | `http` to `https`, `ws` to `wss`, by 307 | — |
| `proxy_headers` | Restores the client and scheme from a trusted proxy | trusts `127.0.0.1` |
| `body_limit` | Answers 413 over the limit, by length or as it streams | 1 MiB |
| `server_errors` | A 500 when the answer has not started, then the error on | no detail |

```moonbit
let app : @moonasgi.AsgiApp = async fn(_, receive, send) {
  ignore(receive())
  send(HttpResponseStart(status=200, headers=[], trailers=false))
  send(HttpResponseBody(body=b"ok", more_body=false))
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
```

Each is a record, so a preset can be adjusted in place — `{ ..@mid.gzip, level: 1 }` says the same as `Gzip::new(level=1)`. Your own middleware is a `Wrap`, or a record implementing `Layer`, and stacks with the rest.

## Several applications behind one

```moonbit
let app = @dispatch.mount([
  ("/api", api_app),
  ("/mcp", mcp_app),
])
let by_host = @dispatch.hosts([("docs.example.com", docs_app)], fallback=app)
```

`mount` matches whole path segments and prefers the longest prefix; the chosen application sees the path below its prefix, with `root_path` extended. `hosts` matches the `Host` header, and `*.example.com` covers a domain. A path or host nothing takes is answered 404, or a declined handshake on a WebSocket.

The lifespan reaches every application behind the dispatcher: startup in order, shutdown in reverse, and one failed startup fails the whole boot.

## Synchronous applications

```moonbit
let legacy : @wsgi.WsgiApp = (environ, start_response) => {
  ignore(start_response("200 OK", [("Content-Type", "text/plain")]))
  [@utf8.encode("hello from "), @utf8.encode(environ.path_info)].iter()
}

let app : @moonasgi.AsgiApp = @wsgi.to_asgi(legacy)
```

`Environ` carries the CGI variables as fields, and `to_map` gives them under their usual names. The request body is read before the application runs; each chunk it yields is sent as it comes.

## Extensions

The optional parts of the specification are typed, not stringly keyed: `http.response.push`, `pathsend`, `zerocopysend`, `early_hint`, `debug`, `trailers`, `websocket.http.response`, and `tls`. A server advertises them on the scope's `extensions`, and an application checks the flag before emitting the matching event. An extension the specification does not name goes in the same map, by name.

## HTTP/2 and HTTP/3

`http_version` on a scope is `"1.0"`, `"1.1"`, `"2"` or `"3"`, and an application runs unchanged on any of them. The request line is the one place the transport shows through: on a multiplexed connection it arrives as pseudo-headers.

```moonbit
let scope = @moonasgi.HttpScope::from_h2_headers([
  (":method", "POST"),
  (":scheme", "https"),
  (":authority", "example.test"),
  (":path", "/items?page=2"),
])
```

The pseudo-headers are consumed into the typed fields, `host` is synthesised from `:authority`, and a malformed set is refused with the first thing wrong with it.

## Packages

| Package | What is in it |
|:--|:--|
| `moonbitstack/moonasgi` | Everything below, re-exported under one import |
| `…/spec` | The scopes, the events, the extensions, the HTTP/2 lowering |
| `…/http` | `Request`, `Response`, `StreamingResponse`, the HTTP cores |
| `…/ws` | `WebSocketHandler`, `WsAccept`, `WsMessage`, `ws_run` |
| `…/lifespan` | `LifespanHandler` and `run_lifespan` |
| `…/client` | `TestClient` for handlers and WebSocket sessions |
| `…/mid` | The middleware stack and the seven above |
| `…/dispatch` | `mount`, `hosts` and a shared lifespan |
| `…/wsgi` | A synchronous application on the same events |
| `…/testing` | A real `AsgiApp` driven in-process, event by event |
| `…/conform` | The conformance harness and the ordering rules |

The seam itself has no dependencies. `mid` uses a compression package; `testing` and `dispatch` use an async runtime for their event loop.

## Examples

<details>
<summary><b>Nineteen programs, one per feature</b></summary>

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

</details>

## License

Apache-2.0.

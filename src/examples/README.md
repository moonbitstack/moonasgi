# Examples

A guided tour of the public `@moonasgi` seam. Each folder is a runnable `main`
package that uses the library's real API - read it, then run it.

```bash
moon run src/examples/00-hello
```

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 00 | [`hello`](00-hello/) | A `Handler` returns `200 hello`; the in-process `TestClient` drives it, then the same handler is dropped onto the raw `Scope`/`Event` seam and lifted onto the async `AsgiApp`. | `Handler`, `Response::text`/`Response::new`, `TestClient::new`/`get`/`post`, `Scope::Http`, `HttpScope::new`, `Event`, `run_http`, `to_asgi`/`AsgiApp` |
| 01 | [`responses`](01-responses/) | The three response bodies (text, json, raw bytes) with a custom status, header lookups on the request and response, and the `TestResponse` accessors. | `Response::text`/`json`/`new`/`header`, `Request::header`, `TestResponse::status`/`text`/`json`/`header` |
| 02 | [`request-methods`](02-request-methods/) | Every HTTP verb the client drives, the request line reaching the handler (method, path, query split, body), a streamed request body, and a `base_headers` merge. | `TestClient::get`/`head`/`delete`/`post`/`put`/`patch`/`request`, `Request` fields, `latin1_decode` |
| 03 | [`middleware`](03-middleware/) | A chain of `Middleware` composed as an onion over a base `Handler`, ordered outermost-first. | `Middleware`, `compose`, `Response::new`, `TestResponse::header` |
| 04 | [`streaming`](04-streaming/) | A multi-chunk body, response trailers, and 103 Early Hints; `events` lowers the stream to the wire sequence and the client reassembles it. | `StreamingResponse::new`/`events`, `StreamHandler`, `TestClient::from_stream`, `run_http_stream`, `TestResponse::trailer`/`early_hints` |
| 05 | [`scope`](05-scope/) | The raw scope seam a framework binds to: `run_http_scoped` hands the app the full `HttpScope` (root_path, peers, seeded state) and drains a chunked body; `AsgiVersion` negotiation. | `run_http_scoped`, `run_http_app`, `HttpScope` fields, `Response::events`, `AsgiVersion::http`/`lifespan`/`default`/`websocket`/`at_least` |
| 06 | [`extensions`](06-extensions/) | The ASGI extensions: capability flags plus the `tls` data on `Extensions`, and the push / pathsend / zerocopysend / debug / early-hint events the client captures. | `Extensions::none`/`enable_*`/`with_tls`, `TlsExtension`, `HttpResponsePush`/`PathSend`/`ZeroCopySend`/`Debug`/`EarlyHint`, `PushPromise`, `ZeroCopySend` |
| 07 | [`websocket`](07-websocket/) | A WebSocket handler answers the handshake three ways (accept + subprotocol, reject, deny-with-http) and echoes frames; captured as a `WsTestSession`. | `WebSocketHandler::new`/`echo`, `WsAccept`, `WsSend`, `WsMessage`, `select_subprotocol`, `TestClient::websocket`/`websocket_app`, `ws_run`/`ws_run_app`, `WsTestSession` |
| 08 | [`lifespan`](08-lifespan/) | Startup seeds `scope.state` in place, the full startup/shutdown cycle validates, and a failed startup short-circuits the boot. | `LifespanHandler::new`, `LifespanReply`, `run_lifespan`, `LifespanScope::new`, `validate_lifespan_replies` |
| 09 | [`validate`](09-validate/) | `validate_events` dispatches on the scope and names the first ordering violation as an `EventOrderError`; well-formed streams return `None`. | `validate_events`, `validate_http_response`/`ws_response`/`lifespan_replies`, `EventOrderError::describe` |
| 10 | [`http2`](10-http2/) | Lowering an HTTP/2 (and HTTP/3) HEADERS block onto an `HttpScope` - request line from the pseudo-headers, host from `:authority` - and rejecting a malformed set with the exact error. | `HttpScope::from_h2_headers`, `Http2HeaderError` |
| 11 | [`headers`](11-headers/) | The latin-1 header wire codec: every byte 0x00..0xFF round-trips losslessly across the seam boundary. | `latin1_decode`/`latin1_encode`, `headers_from_wire`/`headers_to_wire` |
| 12 | [`conformance`](12-conformance/) | The self-verifying harness that drives every `Event`, `Scope` field, and ordering rule through the synchronous cores and reports pass/fail. | `run_conformance`, `ConformanceReport::ok` |
| 13 | [`legacy`](13-legacy/) | ASGI 2.0's double-callable convention run synchronously with `run_legacy`, matching the single-callable path; the async lifts a server binds to are constructed at the seam. | `run_legacy`, `AsgiApplication`, `LegacyAsgiApp`, `double_to_single_callable`, `guarantee_single_callable`, `to_asgi`/`AsgiApp` |
| 14 | [`stack`](14-stack/) | Middleware from `mid` around an async application: a host check, a CORS preflight answered in the middleware, gzip, and a layer of our own beside them. Runs on native, wasm and js. | `mid.stack`, `Layer`, `Wrap`, `Cors::new`, `TrustedHosts::new`, `gzip`, `server_errors` |
| 15 | [`testing`](15-testing/) | An async application tested in-process: lifespan state read back by a request, a WebSocket echo, one exchange stepped through event by event, and a failing route's error reaching the test. Runs on native, wasm and js. | `testing.Client::new`/`lifespan`/`get`/`websocket`, `Session::send_text`/`receive_text`, `communicate`, `Communicator::send`/`receive`, `Finished` |
| 16 | [`dispatch`](16-dispatch/) | Three applications behind one by path prefix and a fourth by host name, every lifespan started and stopped, a reverse proxy's headers restored and an oversized upload refused. Runs on native, wasm and js. | `dispatch.mount`, `dispatch.hosts`, `ProxyHeaders`, `BodyLimit`, `testing.Client::lifespan` |
| 17 | [`wsgi`](17-wsgi/) | A synchronous application mounted under `/legacy`: a body yielded in pieces, the older `write` style, the CGI variables it is given, and a 404. Runs on native, wasm and js. | `wsgi.WsgiApp`, `StartResponse`, `Environ::to_map`, `wsgi.to_asgi`, `dispatch.mount` |

The `TestClient`, `run_http`, `ws_run`, and `run_lifespan` need no socket and run on
every backend, so examples 00 to 13 check and run under every target unchanged. Examples 14
to 17 drive async applications, so they run where moonbitlang/async has an event loop:
native, wasm and js.

---
name: moonasgi
description: "Answer HTTP and WebSocket traffic through the ASGI 3.0 seam in MoonBit: typed scopes and events, request and response, WebSocket sessions, lifespan startup state, the middleware stack, and driving a running application without a socket. Use when an application has to run behind an ASGI server, when a framework has to implement the seam itself, or when such an application has to be exercised in a test."
---

# moonasgi

```bash
moon add moonbitstack/moonasgi
```

```moonbit
// moon.pkg
import {
  "moonbitstack/moonasgi",
}
```

One import reaches the scopes, the events, the ergonomic request and response, the WebSocket handler, the lifespan handler, the in-process client and the ordering rules. `mid`, `dispatch`, `wsgi` and `testing` are separate packages, so a program that only needs the seam does not carry a compressor or an event loop.

## Answer a request

A `Handler` is a request in and a response out. `TestClient` drives one in-process, and a server lifts the same value onto the async seam with `to_asgi`.

```moonbit
let greet : @moonasgi.Handler = fn(request) {
  match (request.http_method, request.path) {
    ("GET", "/ping") => @moonasgi.Response::text("pong")
    ("POST", "/echo") => @moonasgi.Response::new(200, request.headers, request.body)
    _ => @moonasgi.Response::json(status=404, Json({ "detail": "not found" }))
  }
}

let client = @moonasgi.TestClient::new(greet)
let pong = client.get("/ping")
assert_eq(pong.status, 200)
assert_eq(pong.text(), "pong")
let echoed = client.post("/echo", body=b"hi")
assert_eq(echoed.body, b"hi")
```

The body is drained before the handler runs, however many `http.request` events it arrived in. A response that streams, carries trailers or announces early hints is a `StreamingResponse`, returned from a `StreamHandler` and driven by `TestClient::from_stream`.

## Implement the seam

An application proper takes a scope and the two callables. This is what a server calls, and what a framework implements when it wants the scope's `root_path`, `state` or `extensions`, which the ergonomic `Request` drops.

```moonbit
let app : @moonasgi.AsgiApp = async fn(scope, receive, send) {
  guard scope is @moonasgi.Scope::Http(hs) else { return }
  ignore(receive())
  let who = match hs.state.get("greeting") {
    Some(Json::String(text)) => text
    _ => "hello"
  }
  send(
    @moonasgi.Event::HttpResponseStart(
      status=200,
      headers=[("content-type", "text/plain; charset=utf-8")],
      trailers=false,
    ),
  )
  send(
    @moonasgi.Event::HttpResponseBody(
      body=@utf8.encode(who + " from " + hs.path),
      more_body=false,
    ),
  )
}
```

Nothing blocks: each `send` is an async call, so an application may await between two events. Check `hs.extensions.http_response_early_hint` and the other flags before emitting an extension event — a server that did not advertise it is not obliged to accept it.

## Answer a WebSocket

Connect, receive and disconnect are three functions; what connect returns decides the handshake.

```moonbit
let chat = @moonasgi.WebSocketHandler::new(
  on_connect=fn(scope) {
    match scope.select_subprotocol(["chat.v1", "chat.v2"]) {
      Some(chosen) => @ws.WsAccept::Accept(subprotocol=Some(chosen), headers=[])
      None => @ws.WsAccept::Reject(code=1008, reason="no subprotocol in common")
    }
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
  subprotocols=["chat.v1"],
  send=[@ws.WsMessage::Text("hi")],
)
assert_eq(session.subprotocol, Some("chat.v1"))
assert_eq(session.texts(), ["echo:hi"])
```

`DenyHttp` answers the handshake with a whole HTTP response, which is how a rejected upgrade keeps its status and body. A handler that receives `Text` and `Binary` in the same connection must not assume which comes first.

## Stack the middleware

A layer is a record; `stack` folds a list from the last to the first, so the first entry is outermost and sees the request first, the response last.

```moonbit
let guarded = @mid.stack(
  [
    @mid.server_errors,
    @mid.TrustedHosts::new(hosts=["example.com"]),
    @mid.cors,
    @mid.gzip,
    @mid.BodyLimit::new(limit=1 << 20),
  ],
  app,
)
```

Each preset is a plain value: `{ ..@mid.gzip, level: 1 }` narrows one field and keeps the rest. Your own layer is `@mid.Wrap(wrapper)` around a function, or a record implementing `@mid.Layer`, and it stacks beside the shipped ones.

## Say what a client may still send

A rate limit that answers `429` alone leaves a well-behaved client guessing. `headers=true` adds the two fields of `draft-ietf-httpapi-ratelimit-headers` to every answer: the policy's quota and what this request leaves of it.

```moonbit
let limited = @mid.RateLimit::new(
  rate=2.0,
  burst=8.0,
  headers=true,
  name="permin",
).wrap(app)
```

That answers `RateLimit-Policy: "permin";q=8;w=4` and `RateLimit: "permin";r=7;t=1`: eight requests over the four seconds the bucket takes to fill, seven left, one second before the next.

A server with its own limiter builds the fields from the two records instead — `@mid.RateLimitPolicy` and `@mid.ServiceLimit`, each with `encode`:

```moonbit
let policy : @mid.RateLimitPolicy = {
  name: "peruser",
  quota: 100,
  window: Some(60),
  unit: None,
  key: None,
  extra: [],
}
assert_eq(policy.encode(), "\"peruser\";q=100;w=60")
```

A field is a list of items joined with `,`; `unit` is `"content-bytes"` or `"concurrent-requests"` when the quota is not counted in requests, and `key` is a partition key as bytes, written base64.

## Things that catch people out

- `state` seeded at lifespan startup is copied onto every request and WebSocket scope; writing to `scope.state` from inside a request changes that request only.
- `raw_path` may be `None`, and `path` is percent-decoded while `raw_path` is not. Do not decode twice.
- `path` does not include the query string; it is in `query_string` as bytes, undecoded.
- Headers are a list of pairs, in arrival order, names lowercased. A repeated header is two entries, not a folded value.
- `send` raises `@spec.Closed` once the connection is gone. A stream that keeps writing after the client leaves will surface it.
- A `Handler` is lifted by `to_asgi`; anything that needs more than one response event must be written as an `AsgiApp` directly, or returned as a `StreamingResponse`.
- `dispatch.mount` matches whole segments and rewrites `path`, `raw_path` and `root_path`; the mounted application never sees the prefix in `path`.
- The quota fields count whole seconds: `t` is until the next request may pass, not until the bucket is full, and a policy whose window is under a second carries no `w` rather than a rounded-up lie.

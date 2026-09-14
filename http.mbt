///|
/// An inbound HTTP request in ergonomic form: the request line, headers, and the
/// fully-read body. The sugar over `HttpScope` plus a drained `Receive`, so a
/// `Handler` never touches the async transport directly.
pub(all) struct Request {
  http_method : String
  path : String
  query_string : Bytes
  headers : Array[(String, String)]
  body : Bytes
} derive(Eq)

///|
/// An outbound HTTP response: status, headers, and the full body. Mutable so
/// middleware can decorate it before the server serialises it into
/// `HttpResponseStart` + `HttpResponseBody`.
pub(all) struct Response {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
} derive(Eq)

///|
/// A streamed outbound response: the status line, headers, an ordered list of
/// body `chunks` each emitted as its own `HttpResponseBody`, and optional
/// trailing `trailers`. Models ASGI response streaming (multiple body messages
/// with `more_body: true`) and the `http.response.trailers` extension without
/// an async transport. `events` lowers it to the exact event sequence a server
/// would send. `early_hints` (the `http.response.early_hint` extension) are the
/// `103 Early Hints` messages emitted ahead of the final response, each element
/// a list of `Link` header values.
pub(all) struct StreamingResponse {
  status : Int
  headers : Array[(String, String)]
  chunks : Array[Bytes]
  trailers : Array[(String, String)]
  early_hints : Array[Array[String]]
} derive(Eq)

///|
/// Build a `StreamingResponse`. `status` defaults to `200`, `headers`,
/// `trailers` and `early_hints` to empty; `chunks` is the ordered body, each
/// element becoming one `HttpResponseBody` frame.
pub fn StreamingResponse::new(
  chunks~ : Array[Bytes],
  status? : Int = 200,
  headers? : Array[(String, String)] = [],
  trailers? : Array[(String, String)] = [],
  early_hints? : Array[Array[String]] = [],
) -> StreamingResponse {
  { status, headers, chunks, trailers, early_hints, }
}

///|
/// Lower a streamed response to the outbound events a server sends: one
/// `HttpResponseEarlyHint` per early-hint message (before the response starts),
/// then an `HttpResponseStart` (with `trailers` set when any are present), then
/// one `HttpResponseBody` per chunk — `more_body: true` on all but the last —
/// and, if there are trailers, a terminating `HttpResponseTrailers`. An empty
/// `chunks` still yields a single empty final body, so the stream is always
/// well-formed.
pub fn StreamingResponse::events(self : StreamingResponse) -> Array[Event] {
  let has_trailers = self.trailers.length() > 0
  let out : Array[Event] = []
  for links in self.early_hints {
    out.push(HttpResponseEarlyHint(links~))
  }
  out.push(
    HttpResponseStart(
      status=self.status,
      headers=self.headers,
      trailers=has_trailers,
    ),
  )
  if self.chunks.length() == 0 {
    out.push(HttpResponseBody(body=b"", more_body=false))
  } else {
    for i = 0; i < self.chunks.length(); i = i + 1 {
      let last = i == self.chunks.length() - 1
      out.push(HttpResponseBody(body=self.chunks[i], more_body=!last))
    }
  }
  if has_trailers {
    out.push(HttpResponseTrailers(headers=self.trailers, more_trailers=false))
  }
  out
}

///|
/// The ergonomic request→response function most handlers are written as. The
/// synchronous sugar the suite lifts onto `AsgiApp` at the server boundary.
pub type Handler = (Request) -> Response

///|
/// A streaming handler: produces a `StreamingResponse` (multi-chunk body,
/// optional trailers) instead of a single buffered `Response`. Driven by
/// `run_http_stream` and the `TestClient`.
pub type StreamHandler = (Request) -> StreamingResponse

///|
/// A handler transformer that wraps a downstream `Handler` to add cross-cutting
/// behaviour. Composed as an onion where the first registered is outermost.
pub type Middleware = (Handler) -> Handler

///|
/// Build a response from raw bytes.
pub fn Response::new(
  status : Int,
  headers : Array[(String, String)],
  body : Bytes,
) -> Response {
  { status, headers, body, }
}

///|
/// Look up the first header matching `name`, following ASGI's lowercased-name
/// convention.
pub fn Request::header(self : Request, name : String) -> String? {
  for pair in self.headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Look up the first response header matching `name`, same convention as
/// `Request::header`.
pub fn Response::header(self : Response, name : String) -> String? {
  for pair in self.headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Compose middlewares over a base handler. The first element is the outermost
/// wrapper, matching registration order.
pub fn compose(middlewares : Array[Middleware], base : Handler) -> Handler {
  let mut handler = base
  for i = middlewares.length() - 1; i >= 0; i = i - 1 {
    handler = middlewares[i](handler)
  }
  handler
}

///|
/// A `text/plain; charset=utf-8` response whose body is the UTF-8 encoding of
/// `body`. The ergonomic constructor for the common string reply.
pub fn Response::text(status? : Int = 200, body : String) -> Response {
  {
    status,
    headers: [("content-type", "text/plain; charset=utf-8")],
    body: @utf8.encode(body),
  }
}

///|
/// An `application/json` response whose body is the UTF-8 encoding of `value`
/// serialised with `Json::stringify`. The ergonomic constructor for a JSON reply.
pub fn Response::json(status? : Int = 200, value : Json) -> Response {
  {
    status,
    headers: [("content-type", "application/json")],
    body: @utf8.encode(value.stringify()),
  }
}

///|
/// Why a body drain stopped: the request body finished, the client went away
/// mid-request, or the stream ran out without either. A long-polling or streaming
/// handler cares about the difference — `Disconnected` means nothing it sends will
/// arrive, so cleanup is all that is left to do.
pub(all) enum Drain {
  Complete
  Disconnected
  Truncated
} derive(Eq, Debug)

///|
/// Fold one inbound event into the body buffer, returning whether more chunks
/// should be pulled. `HttpRequest` appends its bytes and continues while
/// `more_body`; a disconnect or a stray frame ends the drain.
/// Shared by the async `to_asgi` loop and the synchronous `run_http` driver so
/// both drain identically.
fn absorb(buf : Buffer, event : Event) -> Bool {
  match event {
    HttpRequest(body~, more_body~) => {
      buf.write_bytes(body[:])
      more_body
    }
    _ => false
  }
}

///|
/// Drain a body out of `inbound`, reporting why it stopped.
fn drain_body_events(buf : Buffer, inbound : Array[Event]) -> Drain {
  for event in inbound {
    if event is HttpDisconnect {
      return Disconnected
    }
    if !absorb(buf, event) {
      return Complete
    }
  }
  Truncated
}

///|
/// Assemble the ergonomic `Request` from an http scope and its fully-drained
/// body.
fn build_request(scope : HttpScope, body : Bytes) -> Request {
  {
    http_method: scope.http_method,
    path: scope.path,
    query_string: scope.query_string,
    headers: scope.headers,
    body,
  }
}

///|
/// Serialise a `Response` into the outbound event pair a server sends: an
/// `HttpResponseStart` carrying status and headers (no trailers), then a single
/// `HttpResponseBody` with the whole body and `more_body: false`. The public
/// `Response::events` for callers that want the lowered form directly.
pub fn Response::events(self : Response) -> Array[Event] {
  [
    HttpResponseStart(status=self.status, headers=self.headers, trailers=false),
    HttpResponseBody(body=self.body, more_body=false),
  ]
}

///|
/// The scope-aware sans-transport core: drain the http request body from
/// `inbound` (accumulating `HttpRequest` chunks until `more_body` is false) and
/// hand `app` the full `HttpScope` alongside the assembled body, returning the
/// outbound events `app` emits. This is the seam a framework binds to — a
/// framework reads what the ergonomic `Request` drops: `root_path` (for mounted
/// sub-apps), `extensions` (to gate a feature on what the server advertises),
/// `client`/`server` peers, the `asgi` handshake, and `state` (the map a
/// lifespan startup seeds and the server copies onto every request scope). It is
/// the synchronous analog of the ASGI `(scope, receive, send)` callable for the
/// common drain-then-handle shape; `run_http_app` is the `Request`-level wrapper
/// over it. Non-http scopes yield `[]`.
pub fn run_http_scoped(
  app : (HttpScope, Bytes) -> Array[Event],
  scope : Scope,
  inbound : Array[Event],
) -> Array[Event] {
  match scope {
    Http(hs) => {
      let buf = Buffer()
      let _ = drain_body_events(buf, inbound)
      app(hs, buf.to_bytes())
    }
    _ => []
  }
}

///|
/// `run_http_scoped`, but the app also learns why the body drain stopped. A handler
/// that holds a connection open — long polling, a slow upload — needs to tell "the
/// client sent everything" from "the client went away", which the plain form cannot:
/// it runs the handler to completion either way and the response goes nowhere.
/// Non-http scopes yield `[]`.
pub fn run_http_scoped_drain(
  app : (HttpScope, Bytes, Drain) -> Array[Event],
  scope : Scope,
  inbound : Array[Event],
) -> Array[Event] {
  match scope {
    Http(hs) => {
      let buf = Buffer()
      let why = drain_body_events(buf, inbound)
      app(hs, buf.to_bytes(), why)
    }
    _ => []
  }
}

///|
/// The `Request`-level sans-transport core: drain the http request body from
/// `inbound`, hand the assembled `Request` to `app`, and return the outbound
/// events `app` emits. The ergonomic wrapper over `run_http_scoped` for apps
/// that only need the request line, headers, and body — every server and the
/// `TestClient` drive a `Handler` through it. Non-http scopes yield `[]`.
pub fn run_http_app(
  app : (Request) -> Array[Event],
  scope : Scope,
  inbound : Array[Event],
) -> Array[Event] {
  run_http_scoped(fn(hs, body) { app(build_request(hs, body)) }, scope, inbound)
}

///|
/// The synchronous counterpart of `to_asgi`: drive a `Handler` over an already
/// materialised inbound event sequence and return the outbound events a server
/// would send — `[HttpResponseStart, HttpResponseBody]` for an http scope, `[]`
/// otherwise. A thin `run_http_app` wrapper over `Response::events`, the
/// sans-transport core `to_asgi` mirrors with async `receive`/`send`.
pub fn run_http(
  handler : Handler,
  scope : Scope,
  inbound : Array[Event],
) -> Array[Event] {
  run_http_app(fn(req) { handler(req).events() }, scope, inbound)
}

///|
/// Drive a streaming `StreamHandler` over an inbound event sequence, returning
/// the full outbound stream — `HttpResponseStart`, one `HttpResponseBody` per
/// chunk (`more_body: true` on all but the last), and a trailing
/// `HttpResponseTrailers` when the response carries trailers. The streaming
/// counterpart of `run_http`.
pub fn run_http_stream(
  handler : StreamHandler,
  scope : Scope,
  inbound : Array[Event],
) -> Array[Event] {
  run_http_app(fn(req) { handler(req).events() }, scope, inbound)
}

///|
/// Lift a synchronous `Handler` onto the load-bearing `AsgiApp` the server binds
/// to. For an http scope it drains the request body — looping `receive()` and
/// accumulating `HttpRequest` chunks until `more_body` is false — assembles a
/// `Request`, runs the handler, then emits `HttpResponseStart` followed by a
/// single `HttpResponseBody`. Non-http scopes (websocket, lifespan) are no-ops:
/// this sugar covers request→response handlers only. Shares its drain, request
/// assembly, and response serialisation with `run_http`, which tests the same
/// logic without the async transport.
pub fn to_asgi(handler : Handler) -> AsgiApp {
  (scope, receive, send) => {
    match scope {
      Http(hs) => {
        let buf = Buffer()
        while absorb(buf, receive()) {

        }
        let resp = handler(build_request(hs, buf.to_bytes()))
        for event in resp.events() {
          send(event)
        }
      }
      _ => ()
    }
  }
}

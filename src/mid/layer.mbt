// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Something that wraps one ASGI application in another: CORS, compression, a host check, or the
/// caller's own. Every middleware here is a record that implements it, so a caller's middleware
/// stacks with them on equal terms.
pub(open) trait Layer {
  fn wrap(Self, @spec.AsgiApp) -> @spec.AsgiApp
}

///|
/// A middleware written as a plain function from application to application.
pub(all) struct Wrap((@spec.AsgiApp) -> @spec.AsgiApp)

///|
pub impl Layer for Wrap with fn wrap(self, app) {
  let Wrap(f) = self
  f(app)
}

///|
/// `app` inside `layers`, the first outermost: it sees the request first and the response last,
/// the order Starlette's `middleware=[...]` gives.
pub fn stack(layers : Array[&Layer], app : @spec.AsgiApp) -> @spec.AsgiApp {
  let mut out = app
  for i = layers.length() - 1; i >= 0; i = i - 1 {
    out = layers[i].wrap(out)
  }
  out
}

///|
/// What the host and redirect checks read from an HTTP or WebSocket scope.
priv struct View {
  websocket : Bool
  scheme : String
  headers : Array[(String, String)]
  target : String
  server : (String, Int32?)?
}

///|
fn view(scope : @spec.Scope) -> View? {
  match scope {
    Http(h) =>
      Some({
        websocket: false,
        scheme: h.scheme,
        headers: h.headers,
        target: target(h.root_path, h.path, h.query_string),
        server: h.server,
      })
    WebSocket(w) =>
      Some({
        websocket: true,
        scheme: w.scheme,
        headers: w.headers,
        target: target(w.root_path, w.path, w.query_string),
        server: w.server,
      })
    Lifespan(_) => None
  }
}

///|
fn target(root : String, path : String, query : Bytes) -> String {
  let q = @utf8.decode_lossy(query[:])
  root + path + (if q == "" { "" } else { "?" + q })
}

///|
/// The value of the request header `name`, matched without regard to case.
fn header(headers : Array[(String, String)], name : String) -> String? {
  for h in headers {
    if h.0.to_lower() == name {
      return Some(h.1)
    }
  }
  None
}

///|
/// The headers with `name` set to `value`, replacing any earlier value.
fn put(
  headers : Array[(String, String)],
  name : String,
  value : String,
) -> Array[(String, String)] {
  [..headers.filter(h => h.0.to_lower() != name), (name, value)]
}

///|
/// The headers with `token` added to `vary`, once.
fn vary(
  headers : Array[(String, String)],
  token : String,
) -> Array[(String, String)] {
  match header(headers, "vary") {
    None => [..headers, ("vary", token)]
    Some(v) =>
      if v.split(",").any(t => t.trim(chars=" ").to_lower() == token.to_lower()) {
        headers
      } else {
        put(headers, "vary", "\{v}, \{token}")
      }
  }
}

///|
/// Answer without the application: a status, headers and a plain-text body. On a WebSocket the
/// answer denies the handshake, by the `websocket.http.response` extension, as Starlette's
/// responses do on a WebSocket scope.
async fn respond(
  send : @spec.Send,
  status : Int32,
  headers : Array[(String, String)],
  body : String,
  websocket~ : Bool = false,
) -> Unit {
  let bytes = @utf8.encode(body)
  let all = [
    ..headers,
    ("content-type", "text/plain; charset=utf-8"),
    ("content-length", bytes.length().to_string()),
  ]
  if websocket {
    send(WebSocketHttpResponseStart(status~, headers=all, trailers=false))
    send(WebSocketHttpResponseBody(body=bytes, more_body=false))
  } else {
    send(HttpResponseStart(status~, headers=all, trailers=false))
    send(HttpResponseBody(body=bytes, more_body=false))
  }
}

///|
/// A 307 to `location`: the method and body are kept, as Starlette's `RedirectResponse` does.
async fn redirect(
  send : @spec.Send,
  location : String,
  websocket : Bool,
) -> Unit {
  respond(send, 307, [("location", location)], "", websocket~)
}

///|
pub extend Wrap with Layer::{wrap}

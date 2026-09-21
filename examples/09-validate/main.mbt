// Copyright 2026 Leo Cheng
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// Event-ordering validation. ASGI pins the order an app may emit messages in;
/// `validate_events` dispatches on the scope to the http / websocket / lifespan
/// validator and names the first violation as an `EventOrderError`
/// (`describe` renders it). A well-formed stream returns `None`.
///
///     moon run examples/09-validate
#coverage.skip
fn main {
  let report = fn(label : String, err : @moonasgi.EventOrderError?) -> Unit {
    match err {
      None => println(label + " -> OK")
      Some(e) => println(label + " -> " + e.describe())
    }
  }
  let http = @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(http_method="GET", path="/"),
  )
  // A well-formed response: start, then a single final body.
  let good = [
    @spec.HttpResponseStart(status=200, headers=[], trailers=false),
    @spec.HttpResponseBody(body=b"ok", more_body=false),
  ]
  report("http start+body", @moonasgi.validate_events(http, good))
  // Malformed http streams, each named by its exact violation.
  report(
    "http body before start",
    @moonasgi.validate_http_response([
      @spec.HttpResponseBody(body=b"x", more_body=false),
    ]),
  )
  report(
    "http duplicate start",
    @moonasgi.validate_events(http, [
      @spec.HttpResponseStart(status=200, headers=[], trailers=false),
      @spec.HttpResponseStart(status=200, headers=[], trailers=false),
    ]),
  )
  report(
    "http incomplete body",
    @moonasgi.validate_events(http, [
      @spec.HttpResponseStart(status=200, headers=[], trailers=false),
      @spec.HttpResponseBody(body=b"x", more_body=true),
    ]),
  )
  // WebSocket ordering: a frame before the handshake is accepted.
  let ws = @moonasgi.Scope::WebSocket(@moonasgi.WebSocketScope::new(path="/ws"))
  report(
    "ws frame before accept",
    @moonasgi.validate_ws_response([@spec.WebSocketSendText("x")]),
  )
  report(
    "ws accept+close",
    @moonasgi.validate_events(ws, [
      @spec.WebSocketAccept(subprotocol=None, headers=[]),
      @spec.WebSocketClose(code=1000, reason=""),
    ]),
  )
  // Lifespan ordering: a shutdown reply before the startup reply.
  let ls = @moonasgi.Scope::Lifespan(@moonasgi.LifespanScope::new())
  report(
    "ls shutdown before startup",
    @moonasgi.validate_lifespan_replies([@spec.LifespanShutdownComplete]),
  )
  report(
    "ls startup+shutdown",
    @moonasgi.validate_events(ls, [
      @spec.LifespanStartupComplete,
      @spec.LifespanShutdownComplete,
    ]),
  )
}

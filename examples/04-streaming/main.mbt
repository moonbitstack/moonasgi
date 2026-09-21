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
/// `StreamingResponse` / `StreamHandler`: a multi-chunk body, response trailers,
/// and 103 Early Hints. `events` lowers it to the exact wire sequence a server
/// sends; `TestClient::from_stream` and `run_http_stream` drive it and the
/// client reassembles the chunks into one contiguous body.
///
///     moon run examples/04-streaming
#coverage.skip
fn main {
  let header = fn(r : @moonasgi.TestResponse, n : String) -> String {
    match r.header(n) {
      Some(v) => v
      None => "-"
    }
  }
  let sse : @moonasgi.StreamHandler = fn(_req) {
    @moonasgi.StreamingResponse::new(
      status=200,
      headers=[("content-type", "text/event-stream")],
      chunks=[b"data: 233\n\n", b"data: 666\n\n", b"data: done\n\n"],
      trailers=[("x-digest", "heke1228")],
      early_hints=[["</a.css>; rel=preload"], ["</b.js>; rel=preload"]],
    )
  }
  // events() lowers the stream to the exact outbound event sequence.
  let events = sse({
    http_method: "GET",
    path: "/events",
    query_string: b"",
    headers: [],
    body: b"",
  }).events()
  let well_formed = @moonasgi.validate_http_response(events) is None
  println("lowered to \{events.length()} events; well-formed: \{well_formed}")
  // The client reassembles the chunks into one contiguous body.
  let c = @moonasgi.TestClient::from_stream(sse)
  let r = c.get("/events")
  println("status  = \{r.status} (\{header(r, "content-type")})")
  println("body    = " + r.text())
  let digest = match r.trailer("x-digest") {
    Some(v) => v
    None => "-"
  }
  println("trailer x-digest = " + digest)
  println("early hints: \{r.early_hints.length()} messages")
  for hint in r.early_hints {
    println("  " + hint.join(", "))
  }
  // run_http_stream drives the same handler at the raw Scope/Event seam.
  let scope = @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(http_method="GET", path="/events"),
  )
  let raw = @moonasgi.run_http_stream(sse, scope, [
    @spec.HttpRequest(body=b"", more_body=false),
  ])
  println("run_http_stream -> \{raw.length()} events")
}

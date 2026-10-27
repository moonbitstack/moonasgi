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
/// The `Request` a handler reads and every verb the `TestClient` drives it with:
/// `get` / `head` / `delete` / `post` / `put` / `patch`, plus `request` for a
/// streamed body. Shows the request line reaching the handler intact - method,
/// path, query split off the target, body, and a `base_headers` merge.
///
///     moon run src/examples/02-request-methods
#coverage.skip
fn main {
  // Echo the request line and body back as text so every verb is observable.
  let app : @moonasgi.Handler = fn(req) {
    let auth = match req.header("authorization") {
      Some(v) => v
      None => "none"
    }
    let query = @moonasgi.latin1_decode(req.query_string)
    let body = @moonasgi.latin1_decode(req.body)
    @moonasgi.Response::text(
      "\{req.http_method} \{req.path}?\{query} body=\{body} auth=\{auth}",
    )
  }
  // base_headers are merged ahead of each request's own headers.
  let c = @moonasgi.TestClient::new(app, base_headers=[
    ("authorization", "Bearer heke1228"),
  ])
  println("GET    -> " + c.get("/items?q=moonbit&n=3").text())
  println("HEAD   -> " + c.head("/items").text())
  println("DELETE -> " + c.delete("/items/233").text())
  println("POST   -> " + c.post("/items", body=b"qwq").text())
  println("PUT    -> " + c.put("/items/233", body=b"hhh").text())
  println("PATCH  -> " + c.patch("/items/233", body=b"emm").text())
  // A streamed request body: several HttpRequest frames drain into one body.
  let streamed = c.request(http_method="POST", path="/upload", chunks=[
    b"chunk-233;", b"chunk-666",
  ])
  println("POST (streamed) -> " + streamed.text())
}

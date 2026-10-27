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
/// The response constructors and the reads made against them: `Response::text`
/// (with a custom status), `Response::json`, and `Response::new` for a raw-bytes
/// body; `Request::header` to read an inbound header; and the `TestResponse`
/// accessors a test asserts on - `status`, `text`, `json`, `header`.
///
///     moon run src/examples/01-responses
#coverage.skip
fn main {
  let ctype = fn(r : @moonasgi.TestResponse) -> String {
    match r.header("content-type") {
      Some(v) => v
      None => "-"
    }
  }
  let app : @moonasgi.Handler = fn(req) {
    match req.path {
      "/text" => @moonasgi.Response::text(status=201, "created")
      "/json" => @moonasgi.Response::json({ "id": 233, "user": "heke1228" })
      "/bytes" =>
        @moonasgi.Response::new(
          200,
          [("content-type", "application/octet-stream")],
          b"\x00\x01\x02\x33",
        )
      "/whoami" => {
        let who = match req.header("x-user") {
          Some(u) => u
          None => "anon"
        }
        @moonasgi.Response::text(who)
      }
      _ => @moonasgi.Response::text(status=404, "no route")
    }
  }
  let c = @moonasgi.TestClient::new(app)
  let t = c.get("/text")
  println("GET /text    -> \{t.status} \{t.text()} (\{ctype(t)})")
  let j = c.get("/json")
  let parsed = try j.json() catch {
    _ => Json("")
  } noraise {
    v => v
  }
  let user = match parsed {
    Object(m) =>
      match m.get("user") {
        Some(String(u)) => u
        _ => "?"
      }
    _ => "?"
  }
  println("GET /json    -> \{j.status} \{j.text()} (json.user=\{user})")
  let b = c.get("/bytes")
  println("GET /bytes   -> \{b.status} \{b.body.length()} bytes (\{ctype(b)})")
  let w = c.get("/whoami", headers=[("x-user", "lfanke")])
  println("GET /whoami  -> \{w.status} \{w.text()}")
  let miss = c.get("/nope")
  println("GET /nope    -> \{miss.status} \{miss.text()}")
}

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
/// Hello, ASGI. A `Handler` answers `200 hello`, and the in-process
/// `TestClient` drives it end to end - no socket, every backend. Then the same
/// handler is dropped down onto the raw seam: a typed `Scope::Http` and the
/// `Event` stream `run_http` lowers the response to, the shape a real server
/// serialises. The final line lifts the handler onto the async `AsgiApp`
/// (`Receive`/`Send`) that the mooncat server binds.
///
///     moon run examples/00-hello
#coverage.skip
fn main {
  let greet : @moonasgi.Handler = fn(req) {
    match (req.http_method, req.path) {
      ("POST", "/echo") => @moonasgi.Response::new(200, req.headers, req.body)
      _ => @moonasgi.Response::text("hello")
    }
  }
  let client = @moonasgi.TestClient::new(greet)
  let hello = client.get("/")
  println("GET /       -> \{hello.status} \{hello.text()}")
  let echo = client.post("/echo", body=b"heke1228")
  println("POST /echo  -> \{echo.status} \{echo.text()}")
  let scope = @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(http_method="GET", path="/"),
  )
  let inbound = [@moonasgi.Event::HttpRequest(body=b"", more_body=false)]
  for ev in @moonasgi.run_http(greet, scope, inbound) {
    match ev {
      @spec.HttpResponseStart(status~, ..) =>
        println("event       -> HttpResponseStart \{status}")
      @spec.HttpResponseBody(body~, ..) =>
        println("event       -> HttpResponseBody \{body.length()} bytes")
      _ => ()
    }
  }
  let _ : @moonasgi.AsgiApp = @moonasgi.to_asgi(greet)
}

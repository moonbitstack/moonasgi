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
/// `Middleware` and `compose`: a chain of handler transformers wrapped as an
/// onion over a base `Handler`. `compose` orders them outermost-first, so the
/// first registered runs last on the way out and its header lands nearest the
/// top of the response.
///
///     moon run src/examples/03-middleware
#coverage.skip
fn main {
  // Each middleware stamps one header on the way out.
  let stamp = fn(name : String, value : String) -> @moonasgi.Middleware {
    fn(next) {
      fn(req) {
        let r = next(req)
        @moonasgi.Response::new(r.status, [(name, value), ..r.headers], r.body)
      }
    }
  }
  let base : @moonasgi.Handler = fn(req) {
    @moonasgi.Response::text("handled \{req.path}")
  }
  let app = @moonasgi.compose(
    [
      stamp("x-request-id", "req-233"),
      stamp("x-cors", "*"),
      stamp("x-log", "hit"),
    ],
    base,
  )
  let r = @moonasgi.TestClient::new(app).get("/orders")
  println("status = \{r.status}")
  println("body   = " + r.text())
  for name in ["x-request-id", "x-cors", "x-log"] {
    let v = match r.header(name) {
      Some(x) => x
      None => "-"
    }
    println(name + " = " + v)
  }
}

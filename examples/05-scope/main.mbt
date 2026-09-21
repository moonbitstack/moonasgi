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
/// The raw `Scope` seam a framework binds to. `run_http_scoped` hands the app
/// the full `HttpScope` - the `root_path`, `client`/`server` peers, and the
/// lifespan-seeded `state` the ergonomic `Request` drops - and drains a chunked
/// body first. `run_http_app` is the `Request`-level wrapper over it. Closes with
/// `AsgiVersion` negotiation: each sub-protocol carries its own `spec_version`,
/// compared numerically by `at_least`.
///
///     moon run examples/05-scope
#coverage.skip
fn main {
  // Bound at the scope level: read root_path and the seeded state off the scope.
  let app = fn(
    hs : @moonasgi.HttpScope,
    body : Bytes,
  ) -> Array[@moonasgi.Event] {
    let prefix = match hs.state.get("greeting") {
      Some(String(s)) => s
      _ => "Hello"
    }
    let name = @moonasgi.latin1_decode(body)
    @moonasgi.Response::text("\{prefix}, \{name}! (root=\{hs.root_path})").events()
  }
  let scope = @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(
      http_method="POST",
      path="/greet",
      root_path="/api",
      client=("203.0.113.7", 52333),
      server=("mooncat", Some(8080)),
      state=Map([("greeting", "Bonjour".to_json())]),
    ),
  )
  // The body arrives as two frames; run_http_scoped drains them before the app.
  let out = @moonasgi.run_http_scoped(app, scope, [
    @spec.HttpRequest(body=b"heke", more_body=true),
    @spec.HttpRequest(body=b"1228", more_body=false),
  ])
  for ev in out {
    match ev {
      @spec.HttpResponseStart(status~, ..) => println("start -> \{status}")
      @spec.HttpResponseBody(body~, ..) =>
        println("body  -> " + @moonasgi.latin1_decode(body))
      _ => ()
    }
  }
  // run_http_app is the Request-level wrapper over the same core.
  let via_req = @moonasgi.run_http_app(
    fn(req) {
      @moonasgi.Response::text("via Request: \{req.http_method} \{req.path}").events()
    },
    scope,
    [@spec.HttpRequest(body=b"", more_body=false)],
  )
  println("run_http_app -> \{via_req.length()} events")
  // spec_version negotiation: each sub-protocol carries its own handshake.
  let http = @moonasgi.AsgiVersion::http()
  let life = @moonasgi.AsgiVersion::lifespan()
  println("http spec_version     = \{http.spec_version}")
  println("lifespan spec_version = \{life.spec_version}")
  println("default == http       = \{@moonasgi.AsgiVersion::default() == http}")
  println(
    "websocket == http     = \{@moonasgi.AsgiVersion::websocket() == http}",
  )
  println("http >= 2.3           = \{http.at_least(major=2, minor=3)}")
  println("http >= 2.6           = \{http.at_least(major=2, minor=6)}")
}

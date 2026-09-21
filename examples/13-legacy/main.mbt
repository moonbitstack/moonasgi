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
/// The two calling conventions a 3.0 server normalizes. `run_legacy` is the
/// synchronous core of ASGI 2.0's double-callable shape - `application(scope)`
/// returns an instance that folds the inbound stream - and it yields exactly
/// what the single-callable `run_http` yields. The async lifts a real server
/// binds to (`to_asgi`, `double_to_single_callable`, `guarantee_single_callable`
/// over `AsgiApplication`) are constructed here; running one needs an async
/// runtime, so the synchronous cores above stand in for their semantics.
///
///     moon run examples/13-legacy
#coverage.skip
fn main {
  let handler : @moonasgi.Handler = fn(req) {
    @moonasgi.Response::text("legacy \{req.http_method} \{req.path}")
  }
  let scope = @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(http_method="POST", path="/l"),
  )
  let inbound = [@spec.HttpRequest(body=b"heke1228", more_body=false)]

  // The double-callable convention, run synchronously: the outer call takes the
  // scope, the returned instance folds the inbound event stream.
  let out = @moonasgi.run_legacy(
    fn(sc) { fn(inb) { @moonasgi.run_http(handler, sc, inb) } },
    scope,
    inbound,
  )
  for ev in out {
    match ev {
      @spec.HttpResponseStart(status~, ..) => println("start -> \{status}")
      @spec.HttpResponseBody(body~, ..) =>
        println("body  -> " + @moonasgi.latin1_decode(body))
      _ => ()
    }
  }
  let single = @moonasgi.run_http(handler, scope, inbound)
  println("legacy == single-callable: \{out == single}")

  // The async lifts a server binds to, constructed (not run) at the seam.
  let legacy_app : @moonasgi.LegacyAsgiApp = fn(_sc) { fn(_recv, _send) {  } }
  let _ : @moonasgi.AsgiApp = @moonasgi.double_to_single_callable(legacy_app)
  let _ : @moonasgi.AsgiApp = @moonasgi.guarantee_single_callable(
    @moonasgi.AsgiApplication::Single(@moonasgi.to_asgi(handler)),
  )
  let _ : @moonasgi.AsgiApp = @moonasgi.guarantee_single_callable(
    @moonasgi.AsgiApplication::Legacy(legacy_app),
  )
  println(
    "async lifts constructed: to_asgi, double_to_single_callable, guarantee_single_callable",
  )
}

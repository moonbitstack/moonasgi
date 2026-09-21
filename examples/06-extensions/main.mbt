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
/// The ASGI extensions: a server advertises capabilities on the scope's
/// `Extensions` (the `enable_*` flags plus `with_tls`), and an app emits the
/// matching extension events - server push, path-send, zero-copy send, debug,
/// and 103 Early Hints. The `TestClient` captures each as a typed field on the
/// `TestResponse` (`pushes`, `pathsend`, `zerocopysend`, `debug`, `early_hints`).
///
///     moon run examples/06-extensions
#coverage.skip
fn main {
  // A server-advertised capability set, including the tls extension's data.
  let tls : @moonasgi.TlsExtension = {
    server_cert: Some("-----BEGIN CERTIFICATE-----"),
    client_cert_chain: [],
    client_cert_name: Some("CN=heke1228"),
    client_cert_error: None,
    tls_version: Some(772),
    cipher_suite: Some(4865),
  }
  let ext = @moonasgi.Extensions::none()
    .enable_push()
    .enable_trailers()
    .enable_pathsend()
    .enable_zerocopysend()
    .enable_early_hint()
    .enable_debug()
    .enable_websocket_http_response()
    .with_tls(tls)
  println(
    "push=\{ext.http_response_push} pathsend=\{ext.http_response_pathsend} zerocopy=\{ext.http_response_zerocopysend}",
  )
  println(
    "trailers=\{ext.http_response_trailers} early_hint=\{ext.http_response_early_hint} debug=\{ext.http_response_debug}",
  )
  println(
    "ws_http_response=\{ext.websocket_http_response} tls_present=\{ext.tls is Some(_)}",
  )
  // An app that uses the push, early-hint, debug and pathsend extensions.
  let c = @moonasgi.TestClient::from_app(
    fn(_req) {
      [
        @spec.HttpResponseEarlyHint(links=["</hero.css>; rel=preload"]),
        @spec.HttpResponsePush(path="/hero.css", headers=[
          ("accept", "text/css"),
        ]),
        @spec.HttpResponseDebug(info={ "route": "qwq", "ms": 233 }),
        @spec.HttpResponseStart(status=200, headers=[], trailers=false),
        @spec.HttpResponsePathSend(path="/var/www/hero.html"),
      ]
    },
    extensions=ext,
  )
  let r = c.get("/")
  println("status = \{r.status}")
  println(
    "early hints = \{r.early_hints.length()}, pushes = \{r.pushes.length()}",
  )
  for p in r.pushes {
    let accept = match p.header("accept") {
      Some(v) => v
      None => "-"
    }
    println("  push \{p.path} (accept=\{accept})")
  }
  match r.pathsend {
    Some(path) => println("pathsend -> " + path)
    None => ()
  }
  for d in r.debug {
    println("debug -> " + d.stringify())
  }
  // The zerocopysend extension: an app hands the server an open fd and a range.
  let z = @moonasgi.TestClient::from_app(fn(_req) {
    [
      @spec.HttpResponseStart(status=200, headers=[], trailers=false),
      @spec.HttpResponseZeroCopySend(
        fd=233,
        offset=Some(0),
        count=Some(66666),
        more_body=false,
      ),
    ]
  })
  match z.get("/download").zerocopysend {
    Some(zc) => {
      let offset = match zc.offset {
        Some(o) => o.to_string()
        None => "cur"
      }
      let count = match zc.count {
        Some(n) => n.to_string()
        None => "eof"
      }
      println("zerocopysend -> fd=\{zc.fd} offset=\{offset} count=\{count}")
    }
    None => ()
  }
}

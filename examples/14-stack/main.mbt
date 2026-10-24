// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Middleware from `mid` around an application, and one of our own beside them:
///
///     moon run examples/14-stack --target native
///
/// The application answers 4 KB of text. The stack refuses an unlisted host, answers a CORS
/// preflight itself, compresses the answer for a client that accepts gzip, and times every
/// request with a layer written here.
#coverage.skip
async fn main {
  let app : @spec.AsgiApp = async fn(_, receive, send) {
    ignore(receive())
    send(
      HttpResponseStart(
        status=200,
        headers=[("content-type", "text/plain")],
        trailers=false,
      ),
    )
    send(HttpResponseBody(body=Bytes::make(4096, b'a'), more_body=false))
  }
  let seen : Array[String] = []
  let timing = @mid.Wrap(inner => {
    async fn(scope, receive, send) {
      if scope is Http(h) {
        seen.push("\{h.http_method} \{h.path}")
      }
      inner(scope, receive, send)
    }
  })
  let stacked = @mid.stack(
    [
      @mid.server_errors,
      @mid.TrustedHosts::new(hosts=["example.com"]),
      @mid.Cors::new(origins=["https://app.example.com"], methods=["GET", "PUT"]),
      @mid.gzip,
      timing,
    ],
    app,
  )
  for
    request in [
      ("GET", [("host", "example.com"), ("accept-encoding", "gzip")]),
      ("GET", [("host", "evil.example")]),
      (
        "OPTIONS",
        [
          ("host", "example.com"),
          ("origin", "https://app.example.com"),
          ("access-control-request-method", "PUT"),
        ],
      ),
    ] {
    let (verb, headers) = request
    let scope : @spec.Scope = Http(
      @spec.HttpScope::new(http_method=verb, path="/", headers~),
    )
    let answer : Array[@spec.Event] = []
    stacked(
      scope,
      async fn() {
        @async.pause()
        HttpRequest(body=b"", more_body=false)
      },
      async fn(e) {
        @async.pause()
        answer.push(e)
      },
    )
    for e in answer {
      match e {
        HttpResponseStart(status~, headers~, ..) => {
          let encoding = headers
            .iter()
            .find_first(h => h.0 == "content-encoding")
            .map(h => h.1)
            .unwrap_or("none")
          println("\{verb}: \{status}, content-encoding \{encoding}")
        }
        HttpResponseBody(body~, ..) => println("  body \{body.length()} bytes")
        _ => ()
      }
    }
  }
  println("reached the application: " + seen.join(", "))
}

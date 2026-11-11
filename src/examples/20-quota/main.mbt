// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A rate limit that says what it grants, in the two fields a client reads:
///
///     moon run src/examples/20-quota --target native
///
/// Eight requests pass at once and the ninth is refused, the clock moved by hand
/// so the output is the same on every run. Every answer, refused or not, carries
/// the quota left and how long that holds.
#coverage.skip
async fn main {
  let now : Ref[Int64] = Ref(0L)
  let app : @spec.AsgiApp = async fn(_, receive, send) {
    ignore(receive())
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(HttpResponseBody(body=b"hello", more_body=false))
  }
  let limited = @mid.RateLimit::new(rate=2.0, burst=8.0, headers=true, clock=fn() {
    now.val
  }).wrap(app)
  let policy : Ref[String] = Ref("")
  let left : Ref[String] = Ref("")
  let retry : Ref[String] = Ref("")
  let ask = async fn(label : String) {
    let answer : Array[@spec.Event] = []
    limited(
      Http(
        @spec.HttpScope::new(
          http_method="GET",
          path="/",
          client=("203.0.113.7", 50000),
        ),
      ),
      async fn() {
        @async.pause()
        HttpRequest(body=b"", more_body=false)
      },
      async fn(event) {
        @async.pause()
        answer.push(event)
      },
    )
    for event in answer {
      if event is HttpResponseStart(status~, headers~, ..) {
        retry.val = ""
        for header in headers {
          match header.0 {
            "ratelimit-policy" => policy.val = header.1
            "ratelimit" => left.val = header.1
            "retry-after" => retry.val = header.1
            _ => ()
          }
        }
        let wait = if retry.val == "" {
          ""
        } else {
          ", retry-after " + retry.val
        }
        println("\{label}: \{status}  ratelimit \{left.val}\{wait}")
      }
    }
  }
  for i = 1; i <= 8; i = i + 1 {
    ask("\{i}")
  }
  ask("9")
  now.val = 1_000_000_000L
  ask("10, a second later")
  println("the policy every answer states: " + policy.val)
}

// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The quota fields a rate limit can advertise: what the policy grants, and what
// is left after the request that just passed (or did not).

///|
/// A rate limit that advertises its quota, on a clock the test moves by hand.
fn advertising(
  now : Ref[Int64],
  rate~ : Double = 2.0,
  burst~ : Double = 8.0,
  name~ : String = "default",
) -> @spec.AsgiApp {
  @mid.RateLimit::new(rate~, burst~, name~, headers=true, clock=() => now.val).wrap(
    hello,
  )
}

///|
async test "rate limit: the fields state the policy and what is left" {
  let now = Ref(0L)
  let app = advertising(now)
  let (status, headers) = start(drive(app, from_peer("10.0.0.1", [])))
  assert_eq(status, 200)
  // Eight requests over the four seconds it takes the bucket to fill: two a second.
  assert_eq(value(headers, "ratelimit-policy"), Some("\"default\";q=8;w=4"))
  // Seven left, and half a second until the eighth comes back, which the field
  // states as one whole second.
  assert_eq(value(headers, "ratelimit"), Some("\"default\";r=7;t=1"))
  let (_, next) = start(drive(app, from_peer("10.0.0.1", [])))
  assert_eq(value(next, "ratelimit"), Some("\"default\";r=6;t=1"))
}

///|
async test "rate limit: a refused request states nothing left and when one is back" {
  let now = Ref(0L)
  let app = advertising(now)
  for _ in 0..<8 {
    ignore(start(drive(app, from_peer("10.0.0.1", []))))
  }
  let (status, headers) = start(drive(app, from_peer("10.0.0.1", [])))
  assert_eq(status, 429)
  assert_eq(value(headers, "ratelimit"), Some("\"default\";r=0;t=1"))
  assert_eq(value(headers, "retry-after"), Some("1"))
  // The two agree on the moment a request may pass, as the specification's own
  // throttled example notes they may.
  now.val = 500_000_000L
  let (_, after) = start(drive(app, from_peer("10.0.0.1", [])))
  assert_eq(value(after, "ratelimit"), Some("\"default\";r=0;t=1"))
}

///|
async test "rate limit: the fields are off unless the layer asks for them" {
  let now = Ref(0L)
  let app = @mid.RateLimit::new(burst=1.0, clock=() => now.val).wrap(hello)
  let (status, headers) = start(drive(app, from_peer("10.0.0.1", [])))
  assert_eq(status, 200)
  assert_eq(value(headers, "ratelimit-policy"), None)
  assert_eq(value(headers, "ratelimit"), None)
  let (status, refused) = start(drive(app, from_peer("10.0.0.1", [])))
  assert_eq(status, 429)
  assert_eq(value(refused, "ratelimit"), None)
  assert_eq(value(refused, "ratelimit-policy"), None)
  // What a refused request is always told stays.
  assert_eq(value(refused, "retry-after"), Some("1"))
}

///|
async test "rate limit: the policy name is the caller's" {
  let now = Ref(0L)
  let app = advertising(now, name="permin")
  let (_, headers) = start(drive(app, from_peer("10.0.0.1", [])))
  assert_eq(value(headers, "ratelimit-policy"), Some("\"permin\";q=8;w=4"))
  assert_eq(value(headers, "ratelimit"), Some("\"permin\";r=7;t=1"))
}

///|
async test "rate limit: a request with no key carries no fields" {
  let now = Ref(0L)
  let app = @mid.RateLimit::new(burst=1.0, headers=true, key=_ => None, clock=() => {
    now.val
  }).wrap(hello)
  for _ in 0..<5 {
    let (status, headers) = start(drive(app, from_peer("10.0.0.1", [])))
    assert_eq(status, 200)
    assert_eq(value(headers, "ratelimit"), None)
  }
}

///|
async test "rate limit: the window is whole seconds, rounded up" {
  // One request every two seconds: a bucket of one that takes two seconds to
  // fill, so the policy is one request per two seconds.
  let slow = Ref(0L)
  let (_, headers) = start(
    drive(advertising(slow, rate=0.5, burst=1.0), from_peer("10.0.0.1", [])),
  )
  assert_eq(value(headers, "ratelimit-policy"), Some("\"default\";q=1;w=2"))
  assert_eq(value(headers, "ratelimit"), Some("\"default\";r=0;t=2"))
}

///|
async test "rate limit: a window under a second is left out of the policy" {
  // A hundred a second in a bucket of one refills in ten milliseconds. The
  // policy field counts whole seconds, so it states the quota without a window
  // rather than claiming one request a second.
  let now = Ref(0L)
  let (_, headers) = start(
    drive(advertising(now, rate=100.0, burst=1.0), from_peer("10.0.0.1", [])),
  )
  assert_eq(value(headers, "ratelimit-policy"), Some("\"default\";q=1"))
  assert_eq(value(headers, "ratelimit"), Some("\"default\";r=0;t=1"))
}

///|
async test "rate limit: a bucket that never refills states no window" {
  let now = Ref(0L)
  let app = advertising(now, rate=0.0, burst=2.0)
  let (_, first) = start(drive(app, from_peer("10.0.0.1", [])))
  assert_eq(value(first, "ratelimit-policy"), Some("\"default\";q=2"))
  assert_eq(value(first, "ratelimit"), Some("\"default\";r=1"))
  let (_, second) = start(drive(app, from_peer("10.0.0.1", [])))
  assert_eq(value(second, "ratelimit"), Some("\"default\";r=0"))
  // Nothing accrues, so there is no moment to promise the client.
  let (status, refused) = start(drive(app, from_peer("10.0.0.1", [])))
  assert_eq(status, 429)
  assert_eq(value(refused, "ratelimit"), Some("\"default\";r=0"))
}

///|
async test "rate limit: the fields leave a WebSocket to pass through" {
  let now = Ref(0L)
  let seen : Ref[Bool] = Ref(false)
  let app = @mid.RateLimit::new(headers=true, clock=() => now.val).wrap(fn(
    scope,
    _receive,
    _send,
  ) {
    if scope is WebSocket(_) {
      seen.val = true
    }
  })
  let scope : @spec.Scope = @spec.WebSocket(
    @spec.WebSocketScope::new(path="/events", client=("10.0.0.1", 50000)),
  )
  app(scope, fn() { WebSocketConnect }, fn(_) { () })
  assert_eq(seen.val, true)
}

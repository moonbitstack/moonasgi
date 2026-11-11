///|
/// Requests per client, as a token bucket: `rate` a second on average, with bursts of
/// up to `burst` after a quiet spell. A request that finds its client's bucket empty is
/// answered `429` with `Retry-After`, without calling the application. WebSocket and
/// lifespan scopes pass through.
///
/// Behind a proxy every request arrives from the proxy's address; put `ProxyHeaders`
/// outside this layer so that `key` reads the client's own.
///
/// With `headers` the answer also carries `RateLimit-Policy` and `RateLimit`
/// (draft-ietf-httpapi-ratelimit-headers): the quota the policy grants, and what is left
/// of it after this request. Both are off by default, because they cost a header pair on
/// every response and name a policy the caller may not want published.
pub(all) struct RateLimit {
  /// Requests a second each client accrues.
  rate : Double
  /// The most requests a client may make at once after a quiet spell, and never
  /// under one: a bucket that holds less than a request passes nothing.
  burst : Double
  /// The most clients tracked at once. A new client beyond it first evicts every
  /// client whose bucket has refilled, which loses nothing, and then the one tracked
  /// longest.
  clients : Int32
  /// Which bucket a request draws from; `None` lets it through unlimited.
  key : (@spec.Scope) -> String?
  /// The time in nanoseconds.
  clock : () -> Int64
  /// Whether to answer with `RateLimit-Policy` and `RateLimit` as well.
  headers : Bool
  /// The policy name both fields carry: what a client matches what is left against
  /// the quota it was granted under.
  name : String
}

///|
/// The address a request came from: the key `rate_limit` uses.
pub fn client_address(scope : @spec.Scope) -> String? {
  match scope {
    Http(hs) => hs.client.map(c => c.0)
    _ => None
  }
}

///|
/// One request every half second with bursts of eight, tower-governor's default;
/// room for 160 000 clients, about what nginx keeps in the 10 MB `limit_req_zone`
/// its documentation sets up. The quota fields stay off.
pub let rate_limit : RateLimit = {
  rate: 2.0,
  burst: 8.0,
  clients: 160_000,
  key: client_address,
  clock: () => (@env.now() * 1_000_000UL).reinterpret_as_int64(),
  headers: false,
  name: "default",
}

///|
pub fn RateLimit::new(
  rate~ : Double = rate_limit.rate,
  burst~ : Double = rate_limit.burst,
  clients~ : Int32 = rate_limit.clients,
  key~ : (@spec.Scope) -> String? = rate_limit.key,
  clock~ : () -> Int64 = rate_limit.clock,
  headers~ : Bool = rate_limit.headers,
  name~ : String = rate_limit.name,
) -> RateLimit {
  { rate, burst, clients, key, clock, headers, name, }
}

///|
pub impl Layer for RateLimit with fn wrap(self, app) {
  let buckets : Map[String, @moonward.Bucket] = Map([])
  // The bucket holds whole requests, so a burst under one is raised to one.
  let capacity = self.burst.max(1.0)
  // The same policy answers every request this layer answers, so its field is
  // written once, when the stack is built.
  let policy = if self.headers {
    Some(self.quota_policy(capacity))
  } else {
    None
  }
  (scope, receive, send) => {
    guard scope is Http(_) && (self.key)(scope) is Some(who) else {
      app(scope, receive, send)
      return
    }
    let now = (self.clock)()
    let bucket = match buckets.get(who) {
      Some(bucket) => bucket
      None => {
        self.make_room(buckets, now)
        let bucket = @moonward.Bucket::new(self.rate, burst=capacity, now~)
        buckets[who] = bucket
        bucket
      }
    }
    if bucket.take(now) {
      match policy {
        Some(field) =>
          app(
            scope,
            receive,
            advertised(send, field, self.service_limit(bucket, capacity, now)),
          )
        None => app(scope, receive, send)
      }
    } else {
      let wait = bucket.next(now).nanos
      // Retry-After counts whole seconds, so a partial one rounds up (RFC 9110 §10.2.3).
      let seconds = ((wait + 999_999_999L) / 1_000_000_000L).max(1L)
      let headers = [("retry-after", seconds.to_string())]
      match policy {
        Some(field) => {
          headers.push(("ratelimit-policy", field))
          headers.push(("ratelimit", self.service_limit(bucket, capacity, now)))
        }
        None => ()
      }
      respond(send, 429, headers, "Too Many Requests")
    }
  }
}

///|
pub extend RateLimit with Layer::{wrap}

///|
/// The quota this layer grants as a `RateLimit-Policy` item: what a bucket holds,
/// over the time it takes to fill from empty.
fn RateLimit::quota_policy(self : RateLimit, capacity : Double) -> String {
  // A window under a second cannot be stated in whole seconds, and rounding one
  // up would claim a slower quota than the layer enforces, so such a policy
  // carries no window at all.
  let window = if self.rate <= 0.0 {
    None
  } else {
    let seconds = capacity / self.rate
    if seconds < 1.0 {
      None
    } else {
      Some(ceil_seconds(seconds))
    }
  }
  RateLimitPolicy::{
    name: self.name,
    quota: capacity.to_int64(),
    window,
    unit: None,
    key: None,
    extra: [],
  }.encode()
}

///|
/// What this request leaves behind as a `RateLimit` item: the requests the client
/// may still make, and how long that holds.
fn RateLimit::service_limit(
  self : RateLimit,
  bucket : @moonward.Bucket,
  capacity : Double,
  now : Int64,
) -> String {
  let tokens = bucket.tokens(now).max(0.0)
  let remaining = tokens.to_int64()
  // The window is until one more request may pass: what the client waits for
  // before its allowance grows. A bucket that never refills gives none, and
  // neither does one already holding everything it can hold.
  let window = if self.rate <= 0.0 || (remaining + 1).to_double() > capacity {
    None
  } else {
    let span = bucket.next(now, n=(remaining + 1).to_double())
    Some(ceil_seconds(span.nanos.to_double() / 1.0e9))
  }
  ServiceLimit::{ name: self.name, remaining, window, key: None, extra: [], }.encode()
}

///|
/// Whole seconds, a partial one rounded up: the fields have no sub-second
/// precision, and a client that waits the shorter time is refused again.
fn ceil_seconds(seconds : Double) -> Int64 {
  let whole = seconds.to_int64()
  if whole.to_double() < seconds {
    whole + 1
  } else {
    whole
  }
}

///|
/// `send` with the two quota fields written into the response's headers. The
/// application's own headers keep their order and the fields go last.
fn advertised(send : @spec.Send, policy : String, limit : String) -> @spec.Send {
  event => {
    match event {
      HttpResponseStart(status~, headers~, trailers~) =>
        send(
          HttpResponseStart(
            status~,
            headers=[
              ..headers,
              ("ratelimit-policy", policy),
              ("ratelimit", limit),
            ],
            trailers~,
          ),
        )
      other => send(other)
    }
  }
}

///|
/// Keep the table under `clients` before a new client joins it.
fn RateLimit::make_room(
  self : RateLimit,
  buckets : Map[String, @moonward.Bucket],
  now : Int64,
) -> Unit {
  let room = self.clients.max(1)
  guard buckets.length() >= room else { return }
  let full = []
  for who, bucket in buckets {
    if bucket.tokens(now) >= self.burst.max(1.0) {
      full.push(who)
    }
  }
  for who in full {
    buckets.remove(who)
  }
  while buckets.length() >= room {
    let mut first = None
    for who, _ in buckets {
      first = Some(who)
      break
    }
    guard first is Some(who) else { break }
    buckets.remove(who)
  }
}

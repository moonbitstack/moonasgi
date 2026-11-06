///|
/// Requests per client, as a token bucket: `rate` a second on average, with bursts of
/// up to `burst` after a quiet spell. A request that finds its client's bucket empty is
/// answered `429` with `Retry-After`, without calling the application. WebSocket and
/// lifespan scopes pass through.
///
/// Behind a proxy every request arrives from the proxy's address; put `ProxyHeaders`
/// outside this layer so that `key` reads the client's own.
pub(all) struct RateLimit {
  /// Requests a second each client accrues.
  rate : Double
  /// The most requests a client may make at once after a quiet spell.
  burst : Double
  /// The most clients tracked at once. A new client beyond it first evicts every
  /// client whose bucket has refilled, which loses nothing, and then the one tracked
  /// longest.
  clients : Int32
  /// Which bucket a request draws from; `None` lets it through unlimited.
  key : (@spec.Scope) -> String?
  /// The time in nanoseconds.
  clock : () -> Int64
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
/// its documentation sets up.
pub let rate_limit : RateLimit = {
  rate: 2.0,
  burst: 8.0,
  clients: 160_000,
  key: client_address,
  clock: () => (@env.now() * 1_000_000UL).reinterpret_as_int64(),
}

///|
pub fn RateLimit::new(
  rate~ : Double = rate_limit.rate,
  burst~ : Double = rate_limit.burst,
  clients~ : Int32 = rate_limit.clients,
  key~ : (@spec.Scope) -> String? = rate_limit.key,
  clock~ : () -> Int64 = rate_limit.clock,
) -> RateLimit {
  { rate, burst, clients, key, clock, }
}

///|
pub impl Layer for RateLimit with fn wrap(self, app) {
  let buckets : Map[String, @moonward.Bucket] = Map([])
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
        let bucket = @moonward.Bucket::new(self.rate, burst=self.burst, now~)
        buckets[who] = bucket
        bucket
      }
    }
    if bucket.take(now) {
      app(scope, receive, send)
    } else {
      let wait = bucket.next(now).nanos
      // Retry-After counts whole seconds, so a partial one rounds up (RFC 9110 §10.2.3).
      let seconds = ((wait + 999_999_999L) / 1_000_000_000L).max(1L)
      respond(
        send,
        429,
        [("retry-after", seconds.to_string())],
        "Too Many Requests",
      )
    }
  }
}

///|
pub extend RateLimit with Layer::{wrap}

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

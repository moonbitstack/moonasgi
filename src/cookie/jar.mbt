// Where a client keeps what servers told it to keep, RFC 6265 §5.
//
// A jar is not a bag of pairs: a cookie belongs to a domain and a path, so the
// same name can mean two things at once. The rules that decide which of them a
// request carries — and which set-cookie replaces which — are here, so an
// in-process client and a real browser answer the same way.

///|
/// One stored cookie. A cookie the server gave a `Domain` belongs to that domain
/// and to everything below it; one without belongs to the host that sent it and
/// to nothing else (§5.1.3).
pub struct Entry {
  name : String
  value : String
  domain : String
  host_only : Bool
  path : String
  expires : Int64?
  secure : Bool
}

///|
/// The cookies a client holds. `store` takes what a response said, `header`
/// gives back the `Cookie` header a request to a host and path would carry.
pub struct Jar {
  entries : Array[Entry]
}

///|
/// An empty jar.
pub fn Jar::new() -> Jar {
  { entries: [], }
}

///|
/// How many cookies the jar holds, expired ones included until they are read.
pub fn Jar::length(self : Jar) -> Int32 {
  self.entries.length()
}

///|
/// Forget everything, as a client does when it is told to.
pub fn Jar::clear(self : Jar) -> Unit {
  self.entries.clear()
}

///|
/// Keep one cookie as `host` sent it at `now` (seconds since the epoch). A
/// `Domain` that does not cover the host is refused, as a browser refuses it
/// (§5.3): a server cannot hand out a cookie for somebody else's domain. A
/// `Max-Age` of zero or less, or an `Expires` already past, deletes the cookie of
/// the same name, domain and path instead of storing it.
pub fn Jar::store(
  self : Jar,
  cookie : SetCookie,
  host~ : String,
  now~ : Int64,
  default_path? : String,
) -> Unit {
  let host = host.to_lower()
  let domain = match cookie.domain {
    Some(domain) => domain
    None => host
  }
  // A domain cookie for a host it does not cover would be a cookie planted on
  // somebody else; the jar drops it, which is what §5.3 step 6 ends in.
  if cookie.domain is Some(_) && !covers(domain, host) {
    return
  }
  let path = match cookie.path {
    Some(path) => path
    None => default_path.unwrap_or("/")
  }
  let at = self.index_of(cookie.name, domain, path)
  if cookie.expired(now~) {
    if at >= 0 {
      ignore(self.entries.remove(at))
    }
    return
  }
  let expires = match cookie.max_age {
    Some(seconds) => Some(now + seconds.to_int64())
    None => cookie.expires
  }
  let entry = {
    name: cookie.name,
    value: cookie.value,
    domain,
    host_only: cookie.domain is None,
    path,
    expires,
    secure: cookie.secure,
  }
  if at >= 0 {
    self.entries[at] = entry
  } else {
    self.entries.push(entry)
  }
}

///|
/// Keep a cookie the caller made up rather than read: a value a test plants
/// before the first request, or one a login flow would otherwise have had to
/// earn. `domain` left out makes it a host-only cookie for `host`.
pub fn Jar::set(
  self : Jar,
  name~ : String,
  value~ : String,
  host~ : String,
  domain? : String,
  path~ : String = "/",
  expires? : Int64,
  secure~ : Bool = false,
) -> Unit {
  let (domain, host_only) = match domain {
    Some(domain) => (domain.to_lower(), false)
    None => (host.to_lower(), true)
  }
  let at = self.index_of(name, domain, path)
  let entry = { name, value, domain, host_only, path, expires, secure, }
  if at >= 0 {
    self.entries[at] = entry
  } else {
    self.entries.push(entry)
  }
}

///|
/// The cookies a request to `host` for `path` carries, in the order a browser
/// sends them: the longest path first, then the oldest first (§5.4). `secure`
/// cookies stay behind unless the request is over TLS. Expired cookies are
/// dropped on the way, so a jar that is only ever read still forgets.
pub fn Jar::pairs(
  self : Jar,
  host~ : String,
  path~ : String,
  now~ : Int64,
  secure~ : Bool = false,
) -> Array[(String, String)] {
  let host = host.to_lower()
  let kept : Array[Entry] = []
  for entry in self.entries {
    let live = match entry.expires {
      Some(deadline) => deadline > now
      None => true
    }
    if live {
      kept.push(entry)
    }
  }
  // Reading is also when a jar forgets, so it does not grow for the life of the
  // client just because nobody wrote to it.
  if kept.length() != self.entries.length() {
    self.entries.clear()
    self.entries.push_iter(kept.iter())
  }
  let carried : Array[(Int32, Entry)] = []
  for i, entry in kept {
    if entry.secure && !secure {
      continue
    }
    if !domain_match(host, entry) || !path_match(path, entry.path) {
      continue
    }
    carried.push((i, entry))
  }
  // The longest path first, as a browser sends them (§5.4); the arrival order
  // breaks ties, so a jar answers the same way twice.
  carried.sort_by(fn(a, b) {
    if a.1.path.length() != b.1.path.length() {
      return b.1.path.length() - a.1.path.length()
    }
    a.0 - b.0
  })
  carried.map(fn(pair) { (pair.1.name, pair.1.value) })
}

///|
/// The `Cookie` header a request to `host` for `path` carries, or `None` when it
/// carries no cookies at all.
pub fn Jar::header(
  self : Jar,
  host~ : String,
  path~ : String,
  now~ : Int64,
  secure~ : Bool = false,
) -> String? {
  let pairs = self.pairs(host~, path~, now~, secure~)
  if pairs.length() == 0 {
    return None
  }
  Some(pairs.map(fn(pair) { pair.0 + "=" + pair.1 }).join("; "))
}

///|
/// The value of `name` among the cookies a request to `host` for `path` would
/// carry, so a test can ask what the client holds without writing a header.
pub fn Jar::get(
  self : Jar,
  name : String,
  host~ : String,
  path~ : String,
  now~ : Int64,
  secure~ : Bool = false,
) -> String? {
  for pair in self.pairs(host~, path~, now~, secure~) {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Where the cookie with this name, domain and path sits, or -1 — a later
/// `Set-Cookie` replaces the earlier one rather than piling up beside it (§5.3
/// step 11).
fn Jar::index_of(
  self : Jar,
  name : String,
  domain : String,
  path : String,
) -> Int32 {
  for i, entry in self.entries {
    if entry.name == name && entry.domain == domain && entry.path == path {
      return i
    }
  }
  -1
}

///|
/// Whether a cookie set for `domain` is sent to `host`: the same name, or a name
/// below it on a label boundary. `example.com` covers `www.example.com` and not
/// `notexample.com` (§5.1.3).
fn covers(domain : String, host : String) -> Bool {
  if host == domain {
    return true
  }
  host.has_suffix("." + domain)
}

///|
/// Whether a stored cookie reaches this request.
fn domain_match(host : String, entry : Entry) -> Bool {
  if entry.host_only {
    host == entry.domain
  } else {
    covers(entry.domain, host)
  }
}

///|
/// Whether a cookie stored for `cookie_path` is sent with a request for
/// `path` (§5.1.4): an equal path, or a prefix that ends on a `/` boundary.
fn path_match(path : String, cookie_path : String) -> Bool {
  if path == cookie_path {
    return true
  }
  if !path.has_prefix(cookie_path) {
    return false
  }
  if cookie_path.has_suffix("/") {
    return true
  }
  path.length() > cookie_path.length() && path[cookie_path.length()] == '/'
}

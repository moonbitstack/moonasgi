// A session a server can trust without remembering anything: the data travels in
// the cookie, signed so a client cannot edit it.
//
// The signing is the timestamped HMAC form itsdangerous produces — SHA-1 over
// `value.timestamp`, the key derived from the secret the way Django derives it —
// so a cookie this layer wrote is one a Python service can read, and one it wrote
// is readable here. The payload is the session as JSON, base64url without
// padding.

///|
/// The key in `scope.state` a session lives under. A handler reads it through
/// `session`, which is the same thing with the awkward parts taken out.
let session_key : String = "session"

///|
/// Where `itsdangerous.Signer` draws its key from: the salt, the word `signer`,
/// and the secret, digested (its `django-concat` derivation).
let signer_salt : Bytes = b"itsdangerous.Signer"

///|
/// Data a client carries across requests, signed so it cannot be edited.
///
/// The session is read off the request's cookie into `scope.state`, where a
/// handler reads and writes it with `session`; the response that ends the request
/// carries it back. Nothing is stored on the server, so the secret is the whole
/// of the security: a client that does not have it cannot make a session that
/// verifies, and one that does have it can read every session it ever signed.
pub(all) struct Sessions {
  secret : Bytes
  cookie : String
  max_age : Int32?
  path : String
  same_site : String
  https_only : Bool
  domain : String?
  clock : () -> Int64
}

///|
/// Build a `Sessions` layer around `secret`.
///
/// The defaults are the ones a web framework ships with: a cookie named
/// `session`, good for fourteen days, `Path=/`, `SameSite=Lax`, not `Secure` (a
/// server behind TLS that never answers over plain HTTP turns `https_only` on).
/// `clock` is the current time in seconds since the epoch, `env.now` when it is
/// not given; a test passes its own so a signed cookie it built by hand verifies.
pub fn Sessions::new(
  secret~ : Bytes,
  cookie~ : String = "session",
  max_age~ : Int32? = Some(1_209_600),
  path~ : String = "/",
  same_site~ : String = "lax",
  https_only~ : Bool = false,
  domain? : String,
  clock? : () -> Int64,
) -> Sessions {
  {
    secret,
    cookie,
    max_age,
    path,
    same_site,
    https_only,
    domain,
    clock: clock.unwrap_or(fn() { (@env.now() / 1000UL).reinterpret_as_int64() }),
  }
}

///|
/// The session data of a connection, live: a handler that writes to the returned
/// map is writing what the response cookie will carry. A connection with no
/// session, or one whose cookie did not verify, starts empty.
///
/// The map is the one in `scope.state`, so it survives the hop from a middleware
/// to the application that reads it.
pub fn session(scope : @spec.Scope) -> Map[String, Json] {
  let state = state_of(scope)
  match state.get(session_key) {
    Some(Object(fields)) => fields
    _ => {
      let fields = Map([])
      state[session_key] = Json::object(fields)
      fields
    }
  }
}

///|
/// The `state` of any scope. All three carry one, and all three are the same map
/// the application will read.
fn state_of(scope : @spec.Scope) -> Map[String, Json] {
  match scope {
    Http(h) => h.state
    WebSocket(w) => w.state
    Lifespan(l) => l.state
  }
}

///|
/// The headers of an http or websocket scope; a lifespan run has none.
fn scope_headers(scope : @spec.Scope) -> Array[(String, String)] {
  match scope {
    Http(h) => h.headers
    WebSocket(w) => w.headers
    Lifespan(_) => []
  }
}

///|
/// The request's `cookie` header, or an empty string when it sent none.
fn cookie_header(scope : @spec.Scope) -> String {
  match header(scope_headers(scope), "cookie") {
    Some(value) => value
    None => ""
  }
}

///|
/// Read the session out of a request's cookie: the data the cookie carried, or an
/// empty session when there was no cookie, the signature did not verify, the
/// timestamp has aged out, or the payload was not the JSON object this layer
/// wrote. Every one of those is a client that has no session, which is what a
/// request with no cookie has too.
pub impl Layer for Sessions with fn wrap(self, app) {
  (scope, receive, send) => {
    let state = state_of(scope)
    let now = (self.clock)()
    let loaded = self.read(cookie_header(scope), now~)
    let carried = loaded.length() > 0
    state[session_key] = Json::object(loaded)
    app(scope, receive, event => {
      match event {
        HttpResponseStart(status~, headers~, trailers~) => {
          let data = match state.get(session_key) {
            Some(Object(fields)) => fields
            _ => Map([])
          }
          let set_cookie = self.answer(data, now~, carried~)
          let headers = match set_cookie {
            Some(cookie) => [..headers, ("set-cookie", cookie)]
            None => headers
          }
          send(HttpResponseStart(status~, headers~, trailers~))
        }
        // A WebSocket handshake's response headers can carry a cookie, but the
        // session of a connection is read, not written: the request that opened
        // it already answered with whatever it changed. A denial response is an
        // HTTP response and takes one, as the http path does.
        WebSocketHttpResponseStart(status~, headers~, trailers~) => {
          let data = match state.get(session_key) {
            Some(Object(fields)) => fields
            _ => Map([])
          }
          let headers = match self.answer(data, now~, carried~) {
            Some(cookie) => [..headers, ("set-cookie", cookie)]
            None => headers
          }
          send(WebSocketHttpResponseStart(status~, headers~, trailers~))
        }
        other => send(other)
      }
    })
  }
}

///|
/// The session a `Cookie` header carries, or an empty one.
fn Sessions::read(
  self : Sessions,
  header : String,
  now~ : Int64,
) -> Map[String, Json] {
  let raw = match @cookie.find(header, self.cookie) {
    Some(raw) => raw
    None => return Map([])
  }
  let payload = match self.unsign(raw, now~) {
    Some(payload) => payload
    None => return Map([])
  }
  let text = try @utf8.decode(base64url_decode(payload)) catch {
    _ => return Map([])
  } noraise {
    text => text
  }
  match
    (try @moonjson.loads(text, @moonjson.strict) catch {
      _ => return Map([])
    } noraise {
      value => value
    }) {
    Object(fields) => fields
    _ => Map([])
  }
}

///|
/// The `Set-Cookie` value this response carries, if any: the session signed, or —
/// when a request arrived with one and left without — a cookie that tells the
/// client to drop it.
fn Sessions::answer(
  self : Sessions,
  data : Map[String, Json],
  now~ : Int64,
  carried~ : Bool,
) -> String? {
  if data.length() > 0 {
    // base64url, as the cookie value's own alphabet allows and as every dotted
    // value must be: the signature is the field after the last dot, and a JSON
    // text may contain dots of its own.
    let value = base64url(@utf8.encode(@moonjson.dumps(Json::object(data))))
    let value = self.sign(value, now~)
    return Some(
      @cookie.SetCookie::new(
        name=self.cookie,
        value~,
        path=self.path,
        domain?=self.domain,
        max_age?=self.max_age,
        secure=self.https_only,
        same_site=self.same_site,
      ).encode(),
    )
  }
  if carried {
    // The client holds a session the application has emptied. A date in the past
    // and a `Max-Age` of zero both say the same thing, and a client that knows
    // only one of them still drops the cookie.
    return Some(
      @cookie.SetCookie::new(
        name=self.cookie,
        value="null",
        path=self.path,
        domain?=self.domain,
        max_age=0,
        expires=0L,
        secure=self.https_only,
        same_site=self.same_site,
      ).encode(),
    )
  }
  None
}

///|
/// `value` with the timestamp it was signed at and its signature: three
/// dot-separated fields, the layout itsdangerous writes.
fn Sessions::sign(self : Sessions, value : String, now~ : Int64) -> String {
  let stamp = base64url(short_int(now))
  let signed = value + "." + stamp
  signed + "." + base64url(self.mac(signed))
}

///|
/// The value `signed` carries, when its signature verifies and it is not older
/// than `max_age`. A tampered value, a signature made with another secret, and
/// one that has aged out all read the same way: no value.
fn Sessions::unsign(self : Sessions, signed : String, now~ : Int64) -> String? {
  // The signature is the last field and the timestamp the one before it, so the
  // value itself may contain dots (a JSON payload does not, but a caller's value
  // might).
  let last = signed.rev_find(".")
  let sig_at = match last {
    Some(at) => at
    None => return None
  }
  let rest = signed[0:sig_at]
  let sig = signed[sig_at + 1:]
  let second = rest.rev_find(".")
  let stamp_at = match second {
    Some(at) => at
    None => return None
  }
  if !same_bytes(base64url_decode(sig), self.mac(rest)) {
    return None
  }
  let stamp = match base64url_int(rest[stamp_at + 1:]) {
    Some(stamp) => stamp
    None => return None
  }
  match self.max_age {
    Some(age) => if now - stamp > age.to_int64() { return None }
    None => ()
  }
  Some(rest[0:stamp_at].to_owned())
}

///|
/// The key the signature is made with: `SHA1(salt ‖ "signer" ‖ secret)`, the
/// derivation itsdangerous calls `django-concat`. Deriving it rather than signing
/// with the secret itself keeps one secret usable by several signers.
fn Sessions::key(self : Sessions) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(signer_salt[:])
  buf.write_bytes(b"signer"[:])
  buf.write_bytes(self.secret[:])
  @sha1.hash(buf.to_bytes())
}

///|
/// The HMAC-SHA1 of `value` under this layer's key.
fn Sessions::mac(self : Sessions, value : StringView) -> Bytes {
  @hmac.mac(self.key()[:], @utf8.encode(value)[:], fn() { @sha1.Hasher::new() })
}

///|
/// `value` as base64url without padding: one of the three alphabets a cookie
/// value may carry untouched, the other two being alphanumerics and `-_.`.
fn base64url(bytes : Bytes) -> String {
  @base64.encode(bytes, kind=Url, padding=false)
}

///|
/// The bytes `text` stands for. A cookie this layer wrote is url-safe and
/// unpadded; one a Python service wrote is standard base64 with padding, and it is
/// read all the same — the value is whatever a client showed up holding. Text that
/// is neither yields nothing, which a signature check answers as "no" rather than
/// with a panic.
fn base64url_decode(text : StringView) -> Bytes {
  let bytes = try Some(@base64.decode(text, kind=Url, padding=false)) catch {
    _ => None
  } noraise {
    bytes => bytes
  }
  match bytes {
    Some(bytes) => bytes
    None =>
      try @base64.decode(text, kind=Std, padding=true) catch {
        _ => b""
      } noraise {
        bytes => bytes
      }
  }
}

///|
/// The integer a base64url field stands for, read as itsdangerous writes it: a
/// big-endian number with the leading zero bytes dropped.
fn base64url_int(text : StringView) -> Int64? {
  let bytes = base64url_decode(text)
  if bytes.length() > 8 {
    return None
  }
  let mut value = 0L
  for i = 0; i < bytes.length(); i = i + 1 {
    value = (value << 8) | bytes[i].to_int64()
  }
  Some(value)
}

///|
/// A timestamp as itsdangerous writes it: eight big-endian bytes with the leading
/// zeros removed.
fn short_int(value : Int64) -> Bytes {
  let out : Array[Byte] = []
  let mut started = false
  for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
    let byte = ((value >> shift) & 0xFFL).to_int()
    if !started && byte == 0 {
      continue
    }
    started = true
    out.push(byte.to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Whether two byte strings are equal, comparing every byte even once they
/// differ: a signature check that returns early tells an attacker how much of a
/// forged signature was right.
fn same_bytes(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut difference = 0
  for i = 0; i < a.length(); i = i + 1 {
    difference = difference | (a[i].to_int() ^ b[i].to_int())
  }
  difference == 0
}

///|
pub extend Sessions with Layer::{wrap}

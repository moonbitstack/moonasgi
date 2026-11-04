// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Cross-origin resource sharing, per the Fetch standard §3.2.
///
/// `origins`, `methods` and `headers` are allow-lists, and `"*"` in one allows anything. A
/// preflight is answered here: 200 with the negotiated headers, or 400 naming what was refused.
/// Other cross-origin responses get `access-control-allow-origin` when the origin is allowed.
/// With `credentials` the origin is echoed rather than `*`, as the standard requires.
///
/// `origin_regex` is for a site that cannot list its origins: a staging host per
/// branch, a tenant per customer. It is matched whole against the `Origin` header,
/// after the list, so a listed origin is answered without the expression being
/// compiled.
#derive(Eq, Debug)
pub(all) struct Cors {
  origins : Array[String]
  origin_regex : String?
  methods : Array[String]
  headers : Array[String]
  credentials : Bool
  expose : Array[String]
  max_age : Int32
}

///|
pub extend Cors with Eq::{equal, not_equal}

///|
pub extend Cors with Debug::{to_repr}

///|
/// The defaults: no origin allowed, `GET` only, the safelisted headers only, no credentials,
/// preflights cached for ten minutes.
pub let cors : Cors = {
  origins: [],
  origin_regex: None,
  methods: ["GET"],
  headers: [],
  credentials: false,
  expose: [],
  max_age: 600,
}

///|
pub fn Cors::new(
  origins~ : Array[String] = cors.origins,
  origin_regex? : String,
  methods~ : Array[String] = cors.methods,
  headers~ : Array[String] = cors.headers,
  credentials~ : Bool = cors.credentials,
  expose~ : Array[String] = cors.expose,
  max_age~ : Int32 = cors.max_age,
) -> Cors {
  { origins, origin_regex, methods, headers, credentials, expose, max_age, }
}

///|
/// The request headers a preflight need not ask for (Fetch standard, CORS-safelisted).
let safelisted : Array[String] = [
  "accept", "accept-language", "content-language", "content-type",
]

///|
let all_methods : Array[String] = [
  "DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT",
]

///|
/// Dictionary order. `String`'s own order puts shorter strings first, and the header list
/// reads better sorted by name.
fn lexical(a : String, b : String) -> Int32 {
  let n = @cmp.minimum(a.length(), b.length())
  for i in 0..<n {
    if a[i] != b[i] {
      return a[i].to_int() - b[i].to_int()
    }
  }
  a.length() - b.length()
}

///|
fn Cors::any_origin(self : Cors) -> Bool {
  self.origins.contains("*")
}

///|
/// Whether `origin` is allowed, given the expression the layer compiled when it
/// was built. A pattern that does not compile matches nothing: a broken pattern
/// closes the door rather than opening it.
fn Cors::allows_origin(
  self : Cors,
  origin : String,
  pattern : @moonregex.Pattern?,
) -> Bool {
  if self.any_origin() || self.origins.contains(origin) {
    return true
  }
  match pattern {
    Some(pattern) => matches(pattern, origin)
    None => false
  }
}

///|
fn Cors::allowed_methods(self : Cors) -> Array[String] {
  if self.methods.contains("*") {
    all_methods
  } else {
    self.methods
  }
}

///|
fn Cors::preflight(
  self : Cors,
  origin : String,
  requested : String,
  asked : String?,
  pattern : @moonregex.Pattern?,
) -> (Int32, Array[(String, String)], String) {
  let explicit = !self.any_origin() || self.credentials
  let allowed_headers = {
    let names = safelisted.copy()
    for h in self.headers {
      let lower = h.to_lower()
      if !names.contains(lower) {
        names.push(lower)
      }
    }
    names.sort_by(lexical)
    names
  }
  let any_header = self.headers.contains("*")
  let out : Array[(String, String)] = []
  if explicit {
    out.push(("vary", "Origin"))
  } else {
    out.push(("access-control-allow-origin", "*"))
  }
  out.push(("access-control-allow-methods", self.allowed_methods().join(", ")))
  out.push(("access-control-max-age", self.max_age.to_string()))
  if !any_header {
    out.push(("access-control-allow-headers", allowed_headers.join(", ")))
  }
  if self.credentials {
    out.push(("access-control-allow-credentials", "true"))
  }
  let refused : Array[String] = []
  if self.allows_origin(origin, pattern) {
    if explicit {
      out.push(("access-control-allow-origin", origin))
    }
  } else {
    refused.push("origin")
  }
  if !self.allowed_methods().contains(requested) {
    refused.push("method")
  }
  match asked {
    Some(list) if any_header => {
      let rest = out.filter(h => h.0 != "access-control-allow-headers")
      out.clear()
      out.push_iter([..rest, ("access-control-allow-headers", list)].iter())
    }
    Some(list) =>
      for name in list.split(",") {
        if !allowed_headers.contains(name.trim(chars=" ").to_owned().to_lower()) {
          refused.push("headers")
          break
        }
      }
    None => ()
  }
  if refused.length() > 0 {
    (400, out, "Disallowed CORS " + refused.join(", "))
  } else {
    (200, out, "OK")
  }
}

///|
/// The headers every cross-origin answer carries, and the allow-origin when it is due.
fn Cors::simple(
  self : Cors,
  headers : Array[(String, String)],
  origin : String,
  cookie : Bool,
  pattern : @moonregex.Pattern?,
) -> Array[(String, String)] {
  let mut out = headers
  if self.any_origin() {
    out = put(out, "access-control-allow-origin", "*")
  }
  if self.credentials {
    out = put(out, "access-control-allow-credentials", "true")
  }
  if self.expose.length() > 0 {
    out = put(out, "access-control-expose-headers", self.expose.join(", "))
  }
  // A request with a cookie must not be answered with `*`; one from a listed origin is
  // answered with that origin.
  if (self.any_origin() && cookie) ||
    (!self.any_origin() && self.allows_origin(origin, pattern)) {
    out = vary(put(out, "access-control-allow-origin", origin), "Origin")
  }
  out
}

///|
pub impl Layer for Cors with fn wrap(self, app) {
  // Compiled once, when the stack is built, rather than on every request.
  let pattern = match self.origin_regex {
    Some(text) => compile(text)
    None => None
  }
  (scope, receive, send) => {
    guard scope is Http(h) && header(h.headers, "origin") is Some(origin) else {
      app(scope, receive, send)
      return
    }
    if h.http_method == "OPTIONS" &&
      header(h.headers, "access-control-request-method") is Some(requested) {
      let (status, headers, body) = self.preflight(
        origin,
        requested,
        header(h.headers, "access-control-request-headers"),
        pattern,
      )
      respond(send, status, headers, body)
      return
    }
    let cookie = header(h.headers, "cookie") is Some(_)
    app(scope, receive, event => {
      match event {
        HttpResponseStart(status~, headers~, trailers~) =>
          send(
            HttpResponseStart(
              status~,
              headers=self.simple(headers, origin, cookie, pattern),
              trailers~,
            ),
          )
        other => send(other)
      }
    })
  }
}

///|
pub extend Cors with Layer::{wrap}

///|
/// Whether the whole of `origin` matches the expression: an origin is one value,
/// not a prefix of one, so `https://a.example` must not answer for
/// `https://a.example.evil`.
fn matches(pattern : @moonregex.Pattern, origin : String) -> Bool {
  let found = try pattern.full(origin) catch {
    _ => return false
  } noraise {
    matched => matched
  }
  found is Some(_)
}

///|
/// An origin expression, compiled in the dialect of the Python `re` module its
/// users write these in — that is where the patterns come from, and a Python
/// expression that means one thing must mean the same thing here.
fn compile(text : String) -> @moonregex.Pattern? {
  try @moonregex.compile(text, dialect=@moonregex.python) catch {
    _ => None
  } noraise {
    pattern => Some(pattern)
  }
}

///|
/// A `Set-Cookie` line that could not be read: an empty name, or a name with a
/// separator in it. The text is left empty for the first and names the attribute
/// for the others.
pub(all) suberror Refused {
  Refused(String)
} derive(Eq, Debug)

///|
/// One cookie as a server sends it: the pair and the attributes that decide where
/// it is kept and when it goes away.
///
/// `path` / `domain` / `expires` are `None` when the attribute was not sent, which
/// is not the same as sending the default: a cookie with no `Path` belongs to the
/// directory of the request that set it (RFC 6265 §5.1.4), not to `/`.
pub(all) struct SetCookie {
  name : String
  value : String
  path : String?
  domain : String?
  max_age : Int32?
  expires : Int64?
  secure : Bool
  http_only : Bool
  same_site : String?
}

///|
/// Build a `Set-Cookie`. `http_only` is on by default, the safe side for a cookie
/// that is meant to be read by a server and not by a script; a cookie a page has
/// to see passes `http_only=false`.
pub fn SetCookie::new(
  name~ : String,
  value~ : String,
  path? : String,
  domain? : String,
  max_age? : Int32,
  expires? : Int64,
  secure~ : Bool = false,
  http_only~ : Bool = true,
  same_site? : String,
) -> SetCookie {
  { name, value, path, domain, max_age, expires, secure, http_only, same_site, }
}

///|
/// The wire form: the pair, then the attributes that were set, in the order a
/// server usually writes them. A `Set-Cookie` with `max_age` 0 or below is a
/// deletion, and is written with the epoch in `Expires` so a client that only
/// knows that attribute still drops it.
pub fn SetCookie::encode(self : SetCookie) -> String {
  let out = StringBuilder()
  out.write_string(self.name)
  out.write_char('=')
  out.write_string(self.value)
  match self.path {
    Some(path) => {
      out.write_string("; Path=")
      out.write_string(path)
    }
    None => ()
  }
  match self.domain {
    Some(domain) => {
      out.write_string("; Domain=")
      out.write_string(domain)
    }
    None => ()
  }
  match self.max_age {
    Some(seconds) => {
      out.write_string("; Max-Age=")
      out.write_string(seconds.to_string())
    }
    None => ()
  }
  match self.expires {
    Some(seconds) => {
      out.write_string("; Expires=")
      out.write_string(http_date(seconds))
    }
    None => ()
  }
  if self.secure {
    out.write_string("; Secure")
  }
  if self.http_only {
    out.write_string("; HttpOnly")
  }
  match self.same_site {
    Some(same_site) => {
      out.write_string("; SameSite=")
      out.write_string(same_site)
    }
    None => ()
  }
  out.to_string()
}

///|
/// Read one `Set-Cookie` line: the pair before the first `;`, then the attributes
/// this struct has fields for. An attribute the specification does not name, and
/// one with a value it cannot parse, is skipped — a browser ignores what it does
/// not understand and keeps the cookie, and so does this.
pub fn SetCookie::parse(text : String) -> SetCookie raise Refused {
  let mut name = ""
  let mut value = ""
  let mut path : String? = None
  let mut domain : String? = None
  let mut max_age : Int32? = None
  let mut expires : Int64? = None
  let mut secure = false
  let mut http_only = false
  let mut same_site : String? = None
  for i, part in text.split(";") {
    let part = part.trim(chars=" \t")
    if part == "" {
      continue
    }
    let (key, raw_value) = split_once(part, '=')
    let key = key.trim(chars=" \t")
    if i == 0 {
      if key == "" {
        raise Refused("cookie name is empty")
      }
      name = key.to_owned()
      value = raw_value.trim(chars=" \t").to_owned()
      continue
    }
    match key.to_lower() {
      "path" => path = Some(raw_value.trim(chars=" \t").to_owned())
      "domain" => {
        let d = raw_value.trim(chars=" \t").to_lower()
        // A leading dot says "this domain and below", which is what a domain
        // cookie means anyway (RFC 6265 §4.1.2.3).
        domain = Some(
          if d.has_prefix(".") {
            d[1:].to_owned()
          } else {
            d.to_owned()
          },
        )
      }
      "max-age" => max_age = Some(parse_int(raw_value.trim(chars=" \t")))
      "expires" => {
        let text = raw_value.trim(chars=" \t")
        let seconds = try @moondate.http(text).epoch() catch {
          _ => None
        } noraise {
          v => v
        }
        match seconds {
          Some(seconds) => expires = Some(seconds)
          None => ()
        }
      }
      "secure" => secure = true
      "httponly" => http_only = true
      "samesite" =>
        same_site = Some(raw_value.trim(chars=" \t").to_lower().to_owned())
      _ => ()
    }
  }
  if name == "" {
    raise Refused("cookie name is empty")
  }
  { name, value, path, domain, max_age, expires, secure, http_only, same_site, }
}

///|
/// Whether this cookie is to be dropped at `now`, in seconds since the epoch.
/// `Max-Age` wins over `Expires` (RFC 6265 §5.3), and a `Max-Age` of 0 or less is
/// a deletion whatever the date says.
pub fn SetCookie::expired(self : SetCookie, now~ : Int64) -> Bool {
  match self.max_age {
    Some(seconds) => seconds <= 0
    None =>
      match self.expires {
        Some(deadline) => deadline <= now
        None => false
      }
  }
}

///|
/// The pairs a request sent in its `Cookie` header, in the order sent, with
/// duplicates kept — the first is what a lookup returns, as a browser does.
/// Anything without a `=`, or with an empty name, is skipped: a header is written
/// by whoever sent it, and one bad pair says nothing about the rest.
pub fn parse(header : String) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for part in header.split(";") {
    let part = part.trim(chars=" \t")
    if part == "" {
      continue
    }
    let (name, value) = split_once(part, '=')
    let name = name.trim(chars=" \t")
    if name == "" {
      continue
    }
    out.push((name.to_owned(), value.trim(chars=" \t").to_owned()))
  }
  out
}

///|
/// The value of `name` in a `Cookie` header, without splitting the whole header
/// when the caller wants one cookie.
pub fn find(header : String, name : String) -> String? {
  for pair in parse(header) {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Split on the first `sep`; a string without one is all key and an empty value,
/// which is how a valueless attribute and a cookie with no `=` both arrive.
fn split_once(text : StringView, sep : Char) -> (StringView, StringView) {
  for i, c in text {
    if c == sep {
      return (text[0:i], text[i + 1:])
    }
  }
  (text, "")
}

///|
/// `value` as a signed integer, or 0 for anything that is not one.
fn parse_int(text : StringView) -> Int32 {
  let mut sign = 1
  let mut at = 0
  if text.length() > 0 && (text[0] == '-' || text[0] == '+') {
    if text[0] == '-' {
      sign = -1
    }
    at = 1
  }
  let mut n = 0
  while at < text.length() {
    let c = text[at].to_int()
    if c < 48 || c > 57 {
      return 0
    }
    n = n * 10 + (c - 48)
    at = at + 1
  }
  sign * n
}

///|
/// Seconds since the epoch as the `Expires` attribute writes them, in UTC.
fn http_date(seconds : Int64) -> String {
  @moondate.Moment::of_epoch(seconds, zone=@moondate.Utc).strftime(
    "%a, %d %b %Y %H:%M:%S GMT",
  )
}

///|
pub extend Refused with Eq::{equal, not_equal}

///|
pub extend Refused with Debug::{to_repr}

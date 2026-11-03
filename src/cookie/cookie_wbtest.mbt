///|
/// A `Cookie` request header as the pairs a handler reads, in the order sent.
test "cookie: a request header splits into pairs" {
  assert_eq(parse("sid=abc; theme=dark;  flag "), [
    ("sid", "abc"),
    ("theme", "dark"),
    ("flag", ""),
  ])
  // A value may carry `=`; only the first one separates.
  assert_eq(parse("jwt=a.b.c=="), [("jwt", "a.b.c==")])
  // An empty header, and one whose pairs have no names, carry nothing.
  assert_eq(parse(""), [])
  assert_eq(parse(" ; =x; "), [])
}

///|
/// The first of two cookies with the same name is the one a lookup returns, as a
/// browser reads them.
test "cookie: a duplicate name reads as the first one" {
  assert_eq(find("sid=first; sid=second", "sid"), Some("first"))
  assert_eq(find("theme=dark", "sid"), None)
}

///|
/// A whole `Set-Cookie` line: every attribute this codec models, and nothing it
/// does not.
test "cookie: a set-cookie line parses into its attributes" {
  let line = "sid=abc; Path=/app; Domain=.Example.COM; Max-Age=600; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=Lax; Partitioned"
  let cookie = try SetCookie::parse(line) catch {
    _ => abort("the line parses")
  } noraise {
    c => c
  }
  assert_eq(cookie.name, "sid")
  assert_eq(cookie.value, "abc")
  assert_eq(cookie.path, Some("/app"))
  // A leading dot on a domain means the same thing without it.
  assert_eq(cookie.domain, Some("example.com"))
  assert_eq(cookie.max_age, Some(600))
  assert_eq(cookie.expires, Some(0))
  assert_eq(cookie.secure, true)
  assert_eq(cookie.http_only, true)
  assert_eq(cookie.same_site, Some("lax"))
}

///|
/// A line with only a pair: every attribute is unset, not defaulted. A cookie
/// with no `Path` belongs to the directory that set it, so the difference shows.
test "cookie: a bare pair sets no attribute at all" {
  let cookie = try SetCookie::parse("a=b") catch {
    _ => abort("the line parses")
  } noraise {
    c => c
  }
  assert_eq(cookie.path, None)
  assert_eq(cookie.domain, None)
  assert_eq(cookie.max_age, None)
  assert_eq(cookie.expires, None)
  assert_eq(cookie.secure, false)
  assert_eq(cookie.http_only, false)
  assert_eq(cookie.same_site, None)
  assert_eq(cookie.encode(), "a=b")
}

///|
/// Encoding writes the attributes that were set, in a fixed order, and the epoch
/// in `Expires` as an HTTP date.
test "cookie: encoding writes the attributes that were set" {
  let cookie = SetCookie::new(
    name="sid",
    value="abc",
    path="/app",
    domain="example.com",
    max_age=600,
    expires=0L,
    secure=true,
    http_only=true,
    same_site="Lax",
  )
  assert_eq(
    cookie.encode(),
    "sid=abc; Path=/app; Domain=example.com; Max-Age=600; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=Lax",
  )
  // The default is a cookie a script cannot read.
  assert_eq(SetCookie::new(name="a", value="b").encode(), "a=b; HttpOnly")
  assert_eq(
    SetCookie::new(name="a", value="b", http_only=false).encode(),
    "a=b",
  )
}

///|
/// A line with no name is refused: there is nothing to store it under.
test "cookie: a set-cookie line with no name is refused" {
  let refused = try SetCookie::parse("=abc") catch {
    Refused(_) => true
  } noraise {
    _ => false
  }
  assert_eq(refused, true)
}

///|
/// `Max-Age` wins over `Expires`: zero or less deletes now, a positive one pushes
/// the deadline out from the moment it was received.
test "cookie: max-age decides expiry over the date" {
  let now = 1_700_000_000L
  assert_eq(SetCookie::new(name="a", value="b", max_age=0).expired(now~), true)
  assert_eq(
    SetCookie::new(name="a", value="b", max_age=600).expired(now~),
    false,
  )
  assert_eq(
    SetCookie::new(name="a", value="b", expires=now - 1L).expired(now~),
    true,
  )
  assert_eq(
    SetCookie::new(name="a", value="b", expires=now).expired(now~),
    true,
  )
  assert_eq(SetCookie::new(name="a", value="b").expired(now~), false)
}

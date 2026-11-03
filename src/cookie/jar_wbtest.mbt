///|
/// A jar answers for the host and path a request names, not for every cookie it
/// holds: a cookie set by one host is not offered to another.
test "jar: a host-only cookie reaches its own host and nothing else" {
  let jar = Jar::new()
  jar.set(name="sid", value="abc", host="app.example.com", path="/")
  assert_eq(jar.pairs(host="app.example.com", path="/", now=0L), [
    ("sid", "abc"),
  ])
  assert_eq(jar.pairs(host="api.example.com", path="/", now=0L), [])
  assert_eq(jar.pairs(host="example.com", path="/", now=0L), [])
  assert_eq(jar.header(host="api.example.com", path="/", now=0L), None)
  assert_eq(
    jar.header(host="app.example.com", path="/", now=0L),
    Some("sid=abc"),
  )
}

///|
/// A cookie with a `Domain` reaches the name it names and every name below it,
/// on a label boundary: `example.com` does not cover `notexample.com`, and a
/// host-only cookie does not reach a subdomain of the host that set it.
test "jar: a domain cookie covers the domain and its subdomains" {
  let jar = Jar::new()
  jar.store(
    SetCookie::new(name="sid", value="abc", domain="example.com"),
    host="app.example.com",
    now=0L,
  )
  assert_eq(jar.pairs(host="app.example.com", path="/", now=0L), [
    ("sid", "abc"),
  ])
  assert_eq(jar.pairs(host="example.com", path="/", now=0L), [("sid", "abc")])
  assert_eq(jar.pairs(host="deep.app.example.com", path="/", now=0L), [
    ("sid", "abc"),
  ])
  assert_eq(jar.pairs(host="notexample.com", path="/", now=0L), [])
  assert_eq(jar.pairs(host="example.com.evil", path="/", now=0L), [])
}

///|
/// A server cannot hand out a cookie for a domain that does not cover the host it
/// is answering for: the jar drops it rather than storing it.
test "jar: a cookie for somebody else's domain is refused" {
  let jar = Jar::new()
  jar.store(
    SetCookie::new(name="sid", value="abc", domain="example.com"),
    host="evil.test",
    now=0L,
  )
  assert_eq(jar.length(), 0)
  assert_eq(jar.pairs(host="example.com", path="/", now=0L), [])
}

///|
/// A cookie with no `Path` belongs to the directory of the request that set it,
/// and reaches the paths below that directory, on a `/` boundary.
test "jar: a cookie with no path belongs to the request's directory" {
  let jar = Jar::new()
  jar.store(
    SetCookie::new(name="sid", value="abc"),
    host="example.com",
    now=0L,
    default_path="/app/",
  )
  assert_eq(jar.pairs(host="example.com", path="/app/dashboard", now=0L), [
    ("sid", "abc"),
  ])
  assert_eq(jar.pairs(host="example.com", path="/app", now=0L), [])
  assert_eq(jar.pairs(host="example.com", path="/apple", now=0L), [])
  assert_eq(jar.pairs(host="example.com", path="/", now=0L), [])
}

///|
/// The longest path comes first, as a browser sends them, so a server reading the
/// header sees the most specific cookie first.
test "jar: the longest path is sent first" {
  let jar = Jar::new()
  jar.set(name="wide", value="1", host="example.com", path="/")
  jar.set(name="narrow", value="2", host="example.com", path="/app")
  jar.set(name="narrower", value="3", host="example.com", path="/app/deep")
  assert_eq(
    jar.header(host="example.com", path="/app/deep/x", now=0L),
    Some("narrower=3; narrow=2; wide=1"),
  )
}

///|
/// A second `set-cookie` for the same name, domain and path replaces the first
/// instead of piling up beside it, and a different path is a different cookie.
test "jar: a repeated cookie replaces the one it matches" {
  let jar = Jar::new()
  jar.store(SetCookie::new(name="sid", value="one"), host="example.com", now=0L)
  jar.store(SetCookie::new(name="sid", value="two"), host="example.com", now=0L)
  assert_eq(jar.length(), 1)
  assert_eq(jar.get("sid", host="example.com", path="/", now=0L), Some("two"))
  jar.store(
    SetCookie::new(name="sid", value="three", path="/app"),
    host="example.com",
    now=0L,
  )
  assert_eq(jar.length(), 2)
  assert_eq(
    jar.get("sid", host="example.com", path="/app", now=0L),
    Some("three"),
  )
  assert_eq(jar.get("sid", host="example.com", path="/", now=0L), Some("two"))
}

///|
/// A cookie that has run out is not sent, and a `Max-Age` of zero deletes it. The
/// jar forgets an expired cookie when it is read, so it does not grow forever.
test "jar: an expired cookie is dropped, at the deadline and on deletion" {
  let jar = Jar::new()
  let now = 1_700_000_000L
  jar.store(SetCookie::new(name="a", value="1", max_age=60), host="h", now~)
  jar.store(SetCookie::new(name="b", value="2", max_age=600), host="h", now~)
  assert_eq(jar.header(host="h", path="/", now=now + 59L), Some("a=1; b=2"))
  // Max-Age is inclusive of the second it expires in, as RFC 6265 §5.3 counts it.
  assert_eq(jar.header(host="h", path="/", now=now + 60L), Some("b=2"))
  assert_eq(jar.length(), 1)
  jar.store(SetCookie::new(name="b", value="2", max_age=0), host="h", now~)
  assert_eq(jar.length(), 0)
  assert_eq(jar.header(host="h", path="/", now~), None)
}

///|
/// A `secure` cookie waits for TLS: a plain request does not carry it, and one
/// that says it is secure does.
test "jar: a secure cookie waits for a secure request" {
  let jar = Jar::new()
  jar.store(
    SetCookie::new(name="sid", value="abc", secure=true),
    host="h",
    now=0L,
  )
  assert_eq(jar.pairs(host="h", path="/", now=0L), [])
  assert_eq(jar.pairs(host="h", path="/", now=0L, secure=true), [("sid", "abc")])
}

///|
/// A cookie kept past the end of a request is a cookie the client still holds:
/// clearing the jar is the only way to forget it, as in a browser.
test "jar: clearing forgets everything" {
  let jar = Jar::new()
  jar.set(name="a", value="1", host="h")
  jar.set(name="b", value="2", host="h")
  assert_eq(jar.length(), 2)
  jar.clear()
  assert_eq(jar.length(), 0)
  assert_eq(jar.header(host="h", path="/", now=0L), None)
}

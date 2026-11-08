// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A malformed pseudo-header set is refused with the exact reason, so a
/// transport can answer rather than hand a framework a scope with a missing
/// request-line field or a `:`-prefixed header: RFC 7540 §8.1.2.3 makes every
/// one of these a malformed request.
test "from_h2_headers names a missing request-line field" {
  assert_eq(
    HttpScope::from_h2_headers([(":scheme", "https"), (":path", "/")])
    is Err(MissingMethod),
    true,
  )
  assert_eq(
    HttpScope::from_h2_headers([(":method", "GET"), (":path", "/")])
    is Err(MissingScheme),
    true,
  )
  assert_eq(
    HttpScope::from_h2_headers([(":method", "GET"), (":scheme", "https")])
    is Err(MissingPath),
    true,
  )
  // RFC 7540 allows an empty `:path` only for `OPTIONS *`, which the transport
  // answers itself; it never lowers to a scope.
  assert_eq(
    HttpScope::from_h2_headers([
      (":method", "OPTIONS"),
      (":scheme", "https"),
      (":path", ""),
    ])
    is Err(EmptyPath),
    true,
  )
}

///|
/// A repeated pseudo-header, an unknown one, and one that follows an ordinary
/// field are each named, with the offending header.
test "from_h2_headers names a repeated, unknown or displaced pseudo-header" {
  assert_eq(
    HttpScope::from_h2_headers([
      (":method", "GET"),
      (":method", "GET"),
      (":scheme", "https"),
      (":path", "/"),
    ])
    is Err(DuplicatePseudoHeader(":method")),
    true,
  )
  assert_eq(
    HttpScope::from_h2_headers([
      (":method", "GET"),
      (":scheme", "https"),
      (":path", "/x"),
      (":path", "/y"),
    ])
    is Err(DuplicatePseudoHeader(":path")),
    true,
  )
  assert_eq(
    HttpScope::from_h2_headers([
      (":method", "GET"),
      (":scheme", "https"),
      (":path", "/"),
      (":protocol", "websocket"),
    ])
    is Err(UnknownPseudoHeader(":protocol")),
    true,
  )
  assert_eq(
    HttpScope::from_h2_headers([
      ("host", "example.test"),
      (":method", "GET"),
      (":scheme", "https"),
      (":path", "/"),
    ])
    is Err(PseudoHeaderAfterRegular(":method")),
    true,
  )
}

///|
/// `:authority` is the host an HTTP/2 request names, so a `host` the peer also
/// sent is dropped rather than duplicated: the application sees one `host`,
/// first, holding what the connection vouched for.
test "from_h2_headers takes the host from :authority, ahead of a sent host" {
  let scope = match
    HttpScope::from_h2_headers([
      (":method", "GET"),
      (":scheme", "https"),
      (":authority", "real.example"),
      (":path", "/a?x=1"),
      ("host", "claimed.example"),
      ("accept", "*/*"),
    ]) {
    Ok(s) => s
    Err(_) => fail("a well-formed set should have produced a scope")
  }
  assert_eq(scope.headers, [("host", "real.example"), ("accept", "*/*")])
  assert_eq(scope.http_version, "2")
  // The query comes off `:path`, and only the path half is decoded.
  assert_eq(scope.path, "/a")
  assert_eq(scope.query_string, b"x=1")
  assert_eq(scope.raw_path, Some(b"/a"))
}

///|
/// `split_target` splits at the first `?` and nothing else, which is what keeps
/// a `?` inside a query value from being read as the start of a second one.
test "split_target splits at the first question mark" {
  assert_eq(split_target("/a/b?x=1"), ("/a/b", "x=1"))
  assert_eq(split_target("/a/b"), ("/a/b", ""))
  assert_eq(split_target("/a/b?"), ("/a/b", ""))
  assert_eq(split_target("/a?x=1?y=2"), ("/a", "x=1?y=2"))
  // An escaped `?` is not a separator; it stays part of the path.
  assert_eq(split_target("/%3F"), ("/%3F", ""))
}

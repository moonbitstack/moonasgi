///|
/// ASGI's `path` is decoded and `raw_path` is not, so a target carrying an escaped
/// slash or a non-ASCII name reaches the application both ways.
test "from_h2_headers decodes path and keeps raw_path as sent" {
  let scope = match
    HttpScope::from_h2_headers([
      (":method", "GET"),
      (":scheme", "https"),
      (":authority", "example.test"),
      (":path", "/files/a%2Fb/caf%C3%A9?q=%20x"),
    ]) {
    Ok(s) => s
    Err(_) => fail("the request target should have produced a scope")
  }
  assert_eq(scope.path, "/files/a/b/café")
  assert_eq(scope.raw_path, b"/files/a%2Fb/caf%C3%A9")
  // The query string stays raw: ASGI hands it over undecoded.
  assert_eq(scope.query_string, b"q=%20x")
}

///|
/// A stray percent is not an escape and is passed through, since refusing to build
/// the scope would leave the server unable to answer at all.
test "percent_decode leaves a truncated escape alone" {
  assert_eq(percent_decode("100%"), b"100%")
  assert_eq(percent_decode("%zz"), b"%zz")
  assert_eq(percent_decode("a%2"), b"a%2")
}

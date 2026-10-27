///|
/// A handler that holds the connection open needs to tell a finished request from a
/// client that went away: the plain runner cannot, so it runs the handler either way.
test "run_http_scoped_drain reports why the body drain stopped" {
  let scope = @spec.Scope::Http(
    @spec.HttpScope::new(http_method="POST", path="/upload", http_version="1.1"),
  )
  let seen : Array[Drain] = []
  let app = (_hs, body, why) => {
    seen.push(why)
    [
      @spec.Event::HttpResponseStart(status=200, headers=[], trailers=false),
      @spec.Event::HttpResponseBody(body~, more_body=false),
    ]
  }
  let _ = run_http_scoped_drain(app, scope, [
    @spec.Event::HttpRequest(body=b"qwq", more_body=false),
  ])
  let _ = run_http_scoped_drain(app, scope, [
    @spec.Event::HttpRequest(body=b"partial", more_body=true),
    @spec.Event::HttpDisconnect,
  ])
  let _ = run_http_scoped_drain(app, scope, [
    @spec.Event::HttpRequest(body=b"cut", more_body=true),
  ])
  assert_eq(seen[0], Drain::Complete)
  assert_eq(seen[1], Drain::Disconnected)
  assert_eq(seen[2], Drain::Truncated)
}

///|
suberror Boom derive(Eq)

///|
/// The error `f` raises; fails the test if it returns.
async fn[X] error_of(f : async () -> X) -> Error {
  ignore(f()) catch {
    e => return e
  }
  fail("expected an error")
}

///|
fn http_scope(path? : String) -> @spec.Scope {
  Http(@spec.HttpScope::new(http_method="GET", path=path.unwrap_or("/")))
}

///|
/// Reads one event, answers with its body, and returns.
let echo : @spec.AsgiApp = async fn(_, receive, send) {
  guard receive() is HttpRequest(body~, ..) else { raise Boom }
  send(HttpResponseStart(status=200, headers=[], trailers=false))
  send(HttpResponseBody(body~, more_body=false))
}

///|
/// Takes whatever it is given and never answers.
let stuck : @spec.AsgiApp = async fn(_, receive, _) {
  while true {
    ignore(receive())
  }
}

///|
/// Fails after yielding once.
async fn boom() -> Unit {
  @async.pause()
  raise Boom
}

///|
async test "receive yields the events in order, then Finished" {
  @testing.communicate(echo, http_scope(), c => {
    c.send(HttpRequest(body=b"hi", more_body=false))
    assert_eq(
      c.receive(),
      HttpResponseStart(status=200, headers=[], trailers=false),
    )
    assert_eq(c.receive(), HttpResponseBody(body=b"hi", more_body=false))
    assert_true(error_of(() => c.receive()) is @testing.Finished)
  })
}

///|
async test "receive times out on a silent application" {
  @testing.communicate(stuck, http_scope(), c => {
    assert_true(
      error_of(() => c.receive(timeout=20)) is @testing.Timeout(limit=20),
    )
  })
}

///|
async test "the communicator timeout is the default for receive and wait" {
  @testing.communicate(stuck, http_scope(), timeout=30, c => {
    assert_true(error_of(() => c.receive()) is @testing.Timeout(limit=30))
    assert_true(error_of(() => c.wait()) is @testing.Timeout(limit=30))
  })
}

///|
async test "receive_nothing is true while the application is silent" {
  @testing.communicate(stuck, http_scope(), c => {
    assert_true(c.receive_nothing(timeout=20))
  })
}

///|
async test "receive_nothing leaves an arrived event for receive" {
  @testing.communicate(echo, http_scope(), c => {
    c.send(HttpRequest(body=b"x", more_body=false))
    assert_false(c.receive_nothing())
    assert_false(c.receive_nothing())
    assert_true(c.receive() is HttpResponseStart(status=200, ..))
    assert_true(c.receive() is HttpResponseBody(body=b"x", ..))
    assert_true(c.receive_nothing())
  })
}

///|
async test "an application error comes after the events sent before it" {
  let app : @spec.AsgiApp = async fn(_, _, send) {
    send(HttpResponseStart(status=500, headers=[], trailers=false))
    raise Boom
  }
  @testing.communicate(app, http_scope(), c => {
    assert_true(c.receive() is HttpResponseStart(status=500, ..))
    assert_true(error_of(() => c.receive()) is Boom)
    assert_true(error_of(() => c.receive_nothing()) is Boom)
    assert_true(error_of(() => c.send(HttpDisconnect)) is Boom)
    assert_true(error_of(() => c.wait()) is Boom)
  })
}

///|
async test "wait returns once the application returns" {
  @testing.communicate(echo, http_scope(), c => {
    c.send(HttpRequest(body=b"", more_body=false))
    c.wait()
    assert_true(c.receive() is HttpResponseStart(status=200, ..))
  })
}

///|
async test "an application still running when the body returns is cancelled" {
  let finished = @async.with_timeout_opt(2000, () => {
    @testing.communicate(stuck, http_scope(), _ => 7)
  })
  assert_eq(finished, Some(7))
}

///|
async test "send after a normal return is accepted and ignored" {
  @testing.communicate(echo, http_scope(), c => {
    c.send(HttpRequest(body=b"", more_body=false))
    c.wait()
    c.send(HttpDisconnect)
  })
}

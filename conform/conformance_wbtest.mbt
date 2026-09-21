///|
/// The ASGI 3.0 conformance harness runs clean: every Event variant and every
/// Scope field round-trips through run_http / ws_run / TestClient with no
/// failures. This is the DoD conformance gate — a red check names itself.
test "ASGI 3.0 conformance harness is all-green" {
  let report = run_conformance()
  // Surface any failing check by name before asserting.
  assert_eq(report.failures, [])
  assert_eq(report.ok(), true)
  assert_eq(report.passed, report.total)
  // The battery is substantial: 25 event self-checks + 300 pairwise-distinct
  // checks + the http/ws/scope/extension/streaming/version tables + the
  // positive/negative event-ordering tables + the lifespan-driver and
  // scope-aware-core tables.
  assert_eq(report.total > 350, true)
}

///|
/// The README quotes the harness size. Pin it here so the number cannot drift
/// unnoticed the way it did before — a check added without updating the prose
/// fails this rather than leaving the documentation quietly wrong.
test "the conformance harness runs the number of checks the README claims" {
  let report = run_conformance()
  assert_eq(report.total, 436)
}

///|
/// A field that is either given or not is given plainly.
///
/// `client` and `server` sit in a parameter list beside `raw_path`, which has
/// always been written this way; they now read the same.
test "an absent scope field is absent, not wrapped" {
  let bare = @spec.HttpScope::new(http_method="GET", path="/")
  assert_eq(bare.client, None)
  assert_eq(bare.server, None)
  let placed = @spec.HttpScope::new(
    http_method="GET",
    path="/",
    client=("203.0.113.7", 52333),
    server=("moonbit", Some(8080)),
  )
  assert_eq(placed.client, Some(("203.0.113.7", 52333)))
  assert_eq(placed.server, Some(("moonbit", Some(8080))))
  // A server with no port is a unix socket, and still says so plainly.
  let sock = @spec.HttpScope::new(
    http_method="GET",
    path="/",
    server=("/run/app.sock", None),
  )
  assert_eq(sock.server, Some(("/run/app.sock", None)))
  // The websocket scope takes the same two the same way.
  let ws = @spec.WebSocketScope::new(path="/ws", client=("c", 1))
  assert_eq(ws.client, Some(("c", 1)))
  assert_eq(ws.server, None)
}

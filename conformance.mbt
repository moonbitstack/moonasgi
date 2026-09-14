///|
/// The outcome of the ASGI 3.0 conformance harness: how many round-trip checks
/// ran, how many `passed`, and the names of any that `failures`. A clean run has
/// an empty `failures`. Reusable beyond the test suite — a server or framework
/// built on the seam can call `run_conformance` to self-verify the wiring.
pub(all) struct ConformanceReport {
  total : Int
  passed : Int
  failures : Array[String]
} derive(Eq)

///|
/// Whether every conformance check passed (no failures recorded).
pub fn ConformanceReport::ok(self : ConformanceReport) -> Bool {
  self.failures.length() == 0
}

///|
/// One of each `Event` variant, distinct payloads — the table the harness folds
/// over to prove `Event`'s derived equality discriminates every message in the
/// http / websocket / lifespan sets in both directions (no two variants collapse).
fn all_event_variants() -> Array[Event] {
  [
    HttpRequest(body=b"body", more_body=true),
    HttpDisconnect,
    HttpResponseStart(status=200, headers=[("a", "b")], trailers=false),
    HttpResponseBody(body=b"x", more_body=false),
    HttpResponseTrailers(headers=[("t", "v")], more_trailers=false),
    HttpResponsePush(path="/p", headers=[]),
    HttpResponsePathSend(path="/f"),
    HttpResponseZeroCopySend(
      fd=7,
      offset=Some(0),
      count=Some(16),
      more_body=false,
    ),
    HttpResponseDebug(info={ "trace": "abc" }.to_json()),
    HttpResponseEarlyHint(links=["</a>; rel=preload"]),
    WebSocketConnect,
    WebSocketReceive(text=Some("hi"), bytes=None),
    WebSocketDisconnect(code=1000, reason=Some("bye")),
    WebSocketAccept(subprotocol=Some("chat"), headers=[]),
    WebSocketSendText("hi"),
    WebSocketSendBytes(b"hi"),
    WebSocketClose(code=1001, reason="bye"),
    WebSocketHttpResponseStart(status=403, headers=[], trailers=false),
    WebSocketHttpResponseBody(body=b"no", more_body=false),
    LifespanStartup,
    LifespanShutdown,
    LifespanStartupComplete,
    LifespanStartupFailed(message="boom"),
    LifespanShutdownComplete,
    LifespanShutdownFailed(message="boom"),
  ]
}

///|
/// Run the ASGI 3.0 conformance harness: a table-driven battery that drives every
/// `Event` variant and every `Scope` field through `run_http`, `ws_run`, and the
/// `TestClient`, asserting round-trip fidelity — a value put in comes back
/// unchanged, and no two distinct events or scope shapes are confused — and a
/// negative table that asserts `validate_events` rejects every malformed ordering
/// (a body before the response starts, a websocket frame before the handshake, a
/// lifespan shutdown reply before startup, and the rest) with the exact
/// violation. Returns a `ConformanceReport` naming any check that failed, so the
/// suite (and any downstream server) can assert `ok()`.
pub fn run_conformance() -> ConformanceReport {
  let results : Array[(String, Bool)] = []
  let check = fn(name : String, cond : Bool) -> Unit {
    results.push((name, cond))
  }

  // A. every Event variant is self-equal and pairwise-distinct: derived equality
  //    discriminates all 25 messages, so none collapses into another.
  let evs = all_event_variants()
  check("event/count", evs.length() == 25)
  for i in 0..<evs.length() {
    check("event/self-eq[" + i.to_string() + "]", evs[i] == evs[i])
    for j in (i + 1)..<evs.length() {
      check(
        "event/distinct[" + i.to_string() + "," + j.to_string() + "]",
        evs[i] != evs[j],
      )
    }
  }

  // B. http response round-trip through the TestClient: status, headers and body
  //    survive lowering to events and reassembly.
  let http_cases : Array[(Int, Array[(String, String)], Bytes)] = [
    (200, [("content-type", "text/plain")], b"ok"),
    (404, [], b""),
    (201, [("x-a", "1"), ("x-b", "2")], b"created"),
    (500, [("x-err", "boom")], b"\x00\x01\x02"),
  ]
  for c in http_cases {
    let (status, headers, body) = c
    let client = TestClient::new(fn(_req) {
      Response::new(status, headers, body)
    })
    let r = client.get("/")
    check(
      "http/roundtrip[" + status.to_string() + "]",
      r.status == status && r.headers == headers && r.body == body,
    )
  }

  // C. request-line fields reach the handler intact: method, path, query, a
  //    streamed body, and header merge.
  let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
  for m in methods {
    let seen : Array[String] = []
    let client = TestClient::new(fn(req) {
      seen.push(req.http_method)
      Response::text("ok")
    })
    let _ = client.request(http_method=m, path="/x")
    check("http/method[" + m + "]", seen.length() == 1 && seen[0] == m)
  }
  let qseen : Array[(String, Bytes)] = []
  let qclient = TestClient::new(fn(req) {
    qseen.push((req.path, req.query_string))
    Response::text("ok")
  })
  let _ = qclient.get("/search?q=moonbit&n=3")
  check(
    "http/query-split",
    qseen.length() == 1 &&
    qseen[0].0 == "/search" &&
    qseen[0].1 == b"q=moonbit&n=3",
  )
  let bseen : Array[Bytes] = []
  let bclient = TestClient::new(fn(req) {
    bseen.push(req.body)
    Response::text("ok")
  })
  let _ = bclient.request(http_method="POST", path="/u", chunks=[
    b"chunk-1;", b"chunk-2",
  ])
  check(
    "http/streamed-body",
    bseen.length() == 1 && bseen[0] == b"chunk-1;chunk-2",
  )

  // D. every Scope field round-trips: build each scope kind with all fields set
  //    distinctively and read them back, and check the per-subprotocol
  //    spec_version defaults.
  let hs = HttpScope::new(
    http_method="POST",
    path="/deep",
    http_version="2",
    scheme="https",
    raw_path=b"/deep",
    query_string=b"k=v",
    root_path="/api",
    headers=[("host", "h")],
    client=Some(("1.2.3.4", 5)),
    server=Some(("9.8.7.6", Some(4))),
    extensions=Extensions::none().enable_push(),
    state=Map([("k", Json::string("v"))]),
  )
  check(
    "scope/http-fields",
    hs.http_method == "POST" &&
    hs.path == "/deep" &&
    hs.http_version == "2" &&
    hs.scheme == "https" &&
    hs.raw_path == b"/deep" &&
    hs.query_string == b"k=v" &&
    hs.root_path == "/api" &&
    hs.headers == [("host", "h")] &&
    hs.client == Some(("1.2.3.4", 5)) &&
    hs.server == Some(("9.8.7.6", Some(4))) &&
    hs.extensions.http_response_push &&
    hs.asgi.spec_version == "2.5",
  )
  let wss = WebSocketScope::new(
    path="/ws",
    scheme="wss",
    query_string=b"t=1",
    root_path="/rt",
    headers=[("origin", "o")],
    client=Some(("c", 1)),
    server=Some(("s", Some(2))),
    subprotocols=["chat", "json"],
    extensions=Extensions::none().enable_websocket_http_response(),
  )
  check(
    "scope/ws-fields",
    wss.path == "/ws" &&
    wss.scheme == "wss" &&
    wss.query_string == b"t=1" &&
    wss.root_path == "/rt" &&
    wss.headers == [("origin", "o")] &&
    wss.client == Some(("c", 1)) &&
    wss.server == Some(("s", Some(2))) &&
    wss.subprotocols == ["chat", "json"] &&
    wss.extensions.websocket_http_response &&
    wss.asgi.spec_version == "2.5",
  )
  let ls = LifespanScope::new(state=Map([("boot", true.to_json())]))
  check(
    "scope/lifespan-fields",
    ls.asgi.spec_version == "2.0" && ls.state.get("boot") is Some(_),
  )
  // A Unix-domain-socket server address is [path, None] — the port is optional
  // (ASGI www spec), which a TCP `[host, port]` server never needs.
  let unix = HttpScope::new(
    http_method="GET",
    path="/",
    server=Some(("/run/app.sock", None)),
  )
  check(
    "scope/unix-server",
    unix.server == Some(("/run/app.sock", None)) &&
    HttpScope::new(http_method="GET", path="/", server=Some(("h", Some(8080)))).server ==
    Some(("h", Some(8080))),
  )

  // E. websocket round-trip through ws_run / TestClient: echo, subprotocol,
  //    reject, deny-with-http, and app-initiated close.
  let echo = TestClient::new(fn(_r) { Response::text("") })
  let s_echo = echo.websocket(
    path="/ws",
    handler=WebSocketHandler::echo(subprotocol=Some("chat")),
    send=[Text("a"), Binary(b"b"), Text("c")],
  )
  check(
    "ws/echo",
    s_echo.accepted &&
    s_echo.subprotocol == Some("chat") &&
    s_echo.messages == [Text("a"), Binary(b"b"), Text("c")] &&
    s_echo.texts() == ["a", "c"],
  )
  let s_reject = echo.websocket(
    path="/ws",
    handler=WebSocketHandler::new(on_connect=fn(_s) {
      Reject(code=4403, reason="nope")
    }),
    send=[Text("ignored")],
  )
  check(
    "ws/reject",
    !s_reject.accepted &&
    s_reject.closed &&
    s_reject.close_code == Some(4403) &&
    s_reject.messages.length() == 0,
  )
  let s_deny = echo.websocket(
    path="/ws",
    handler=WebSocketHandler::new(on_connect=fn(_s) {
      DenyHttp(status=401, headers=[("x", "y")], body=b"denied")
    }),
  )
  let deny_ok = match s_deny.denial {
    Some(resp) => resp.status == 401 && resp.body == b"denied"
    None => false
  }
  check("ws/deny-http", !s_deny.accepted && deny_ok)
  let s_close = echo.websocket(
    path="/ws",
    handler=WebSocketHandler::new(on_receive=fn(_m) {
      [SendText("bye"), Close(code=1000, reason="done")]
    }),
    send=[Text("first"), Text("second-should-be-ignored")],
    disconnect=None,
  )
  check("ws/app-close", s_close.messages == [Text("bye")] && s_close.closed)
  // ws_run_app escape hatch sees the full scope (subprotocols) and inbound stream.
  let s_app = echo.websocket_app(
    path="/ws",
    app=fn(scope : WebSocketScope, inbound : Array[Event]) {
      [
        WebSocketAccept(subprotocol=scope.subprotocols.get(0), headers=[
          ("x-frames", inbound.length().to_string()),
        ]),
      ]
    },
    subprotocols=["v1"],
    send=[Text("a"), Text("b")],
    disconnect=None,
  )
  check(
    "ws/run_app",
    s_app.accepted &&
    s_app.subprotocol == Some("v1") &&
    s_app.header("x-frames") == Some("3"),
  )

  // F. extension capability flags round-trip onto the scope; early-hint events
  //    are captured by the client.
  let ext = Extensions::none()
    .enable_push()
    .enable_trailers()
    .enable_pathsend()
    .enable_zerocopysend()
    .enable_early_hint()
    .enable_debug()
    .enable_websocket_http_response()
  check(
    "ext/flags",
    ext.http_response_push &&
    ext.http_response_trailers &&
    ext.http_response_pathsend &&
    ext.http_response_zerocopysend &&
    ext.http_response_early_hint &&
    ext.http_response_debug &&
    ext.websocket_http_response,
  )
  // Each enable_* advertises exactly its own extension and leaves the rest off —
  // the seven official ASGI extension keys, each independently toggled.
  check(
    "ext/zerocopysend-isolated",
    {
      let e = Extensions::none().enable_zerocopysend()
      e.http_response_zerocopysend &&
      !e.http_response_push &&
      !e.http_response_debug
    },
  )
  check(
    "ext/debug-isolated",
    {
      let e = Extensions::none().enable_debug()
      e.http_response_debug &&
      !e.http_response_zerocopysend &&
      !e.http_response_pathsend
    },
  )
  let eh_client = TestClient::from_app(fn(_req) {
    [
      HttpResponseEarlyHint(links=["</a.css>; rel=preload"]),
      HttpResponseEarlyHint(links=[
        "</b.js>; rel=preload", "</c.js>; rel=preload",
      ]),
      HttpResponseStart(status=200, headers=[], trailers=false),
      HttpResponseBody(body=b"", more_body=false),
    ]
  })
  let eh = eh_client.get("/")
  check(
    "ext/early-hint",
    eh.early_hints.length() == 2 &&
    eh.early_hints[0] == ["</a.css>; rel=preload"] &&
    eh.early_hints[1] == ["</b.js>; rel=preload", "</c.js>; rel=preload"],
  )

  // G. streaming response round-trip: early hints, chunked body, and trailers.
  let stream = StreamingResponse::new(
    status=200,
    chunks=[b"one ", b"two"],
    trailers=[("digest", "abc")],
    early_hints=[["</s.css>; rel=preload"]],
  )
  let sclient = TestClient::from_stream(fn(_r) { stream })
  let sr = sclient.get("/")
  check(
    "stream/roundtrip",
    sr.body == b"one two" &&
    sr.trailer("digest") == Some("abc") &&
    sr.early_hints == [["</s.css>; rel=preload"]],
  )

  // H. spec_version negotiation compares numerically across the dotted version.
  let ver_cases : Array[(String, Int, Int, Bool)] = [
    ("2.5", 2, 0, true),
    ("2.5", 2, 5, true),
    ("2.5", 2, 6, false),
    ("2.5", 1, 9, true),
    ("2.5", 3, 0, false),
    ("2.10", 2, 9, true),
    ("2.0", 2, 0, true),
    ("2.0", 2, 1, false),
  ]
  for vc in ver_cases {
    let (sv, maj, minr, want) = vc
    let v : AsgiVersion = { version: "3.0", spec_version: sv, }
    check(
      "spec_version/" + sv + ">=" + maj.to_string() + "." + minr.to_string(),
      v.at_least(major=maj, minor=minr) == want,
    )
  }
  // I. event-ordering validation. A well-formed outbound stream passes
  //    `validate_events`; a malformed one is rejected with the exact violation.
  //    This is the negative half of the harness — the ordering rules ASGI pins.
  let hscope = Http(HttpScope::new(http_method="GET", path="/"))
  let wscope = WebSocket(WebSocketScope::new(path="/ws"))
  let lscope = Lifespan(LifespanScope::new())
  let ok_start = HttpResponseStart(status=200, headers=[], trailers=false)
  let ok_start_tr = HttpResponseStart(status=200, headers=[], trailers=true)
  let ok_body = HttpResponseBody(body=b"x", more_body=false)
  let ok_trailers = HttpResponseTrailers(
    headers=[("t", "v")],
    more_trailers=false,
  )
  let valid_http : Array[(String, Array[Event])] = [
    ("start+body", [ok_start, ok_body]),
    (
      "hint+start+body",
      [HttpResponseEarlyHint(links=["</a>"]), ok_start, ok_body],
    ),
    ("start+body+trailers", [ok_start_tr, ok_body, ok_trailers]),
    (
      "start+zerocopy",
      [
        ok_start,
        HttpResponseZeroCopySend(fd=3, offset=None, count=None, more_body=false),
      ],
    ),
    ("start+pathsend", [ok_start, HttpResponsePathSend(path="/f")]),
    (
      "start+push+body",
      [ok_start, HttpResponsePush(path="/p", headers=[]), ok_body],
    ),
    // The debug message goes once, ahead of the response it annotates.
    (
      "debug+start+body",
      [HttpResponseDebug(info={ "k": "v" }.to_json()), ok_start, ok_body],
    ),
  ]
  for vc in valid_http {
    check("order/http-valid/" + vc.0, validate_events(hscope, vc.1) == None)
  }
  let bad_http : Array[(String, Array[Event], EventOrderError)] = [
    ("body-before-start", [ok_body], BodyBeforeStart),
    (
      "push-before-start",
      [HttpResponsePush(path="/p", headers=[]), ok_start, ok_body],
      PushBeforeStart,
    ),
    (
      "debug-after-start",
      [ok_start, HttpResponseDebug(info={ "k": "v" }.to_json()), ok_body],
      DebugAfterStart,
    ),
    (
      "debug-twice",
      [
        HttpResponseDebug(info={ "k": "v" }.to_json()),
        HttpResponseDebug(info={ "k": "w" }.to_json()),
        ok_start,
        ok_body,
      ],
      DuplicateDebug,
    ),
    (
      "pathsend-after-body",
      [
        ok_start,
        HttpResponseBody(body=b"partial", more_body=true),
        HttpResponsePathSend(path="/f"),
      ],
      PathSendMixedWithBody,
    ),
    (
      "zerocopy-before-start",
      [HttpResponseZeroCopySend(fd=1, offset=None, count=None, more_body=false)],
      BodyBeforeStart,
    ),
    ("dup-start", [ok_start, ok_start], DuplicateResponseStart),
    (
      "hint-after-start",
      [ok_start, HttpResponseEarlyHint(links=[])],
      EarlyHintAfterStart,
    ),
    ("body-after-complete", [ok_start, ok_body, ok_body], BodyAfterComplete),
    (
      "unexpected-trailers",
      [ok_start, ok_body, ok_trailers],
      UnexpectedTrailers,
    ),
    ("trailers-before-body", [ok_start_tr, ok_trailers], TrailersBeforeBody),
    ("missing-start", [], MissingResponseStart),
    (
      "incomplete-body",
      [ok_start, HttpResponseBody(body=b"x", more_body=true)],
      IncompleteBody,
    ),
    ("missing-trailers", [ok_start_tr, ok_body], MissingTrailers),
    (
      "event-after-complete",
      [ok_start, ok_body, HttpResponsePush(path="/p", headers=[])],
      EventAfterComplete,
    ),
    ("non-response-event", [WebSocketConnect], NonResponseEvent),
  ]
  for bc in bad_http {
    check("order/http-bad/" + bc.0, validate_events(hscope, bc.1) == Some(bc.2))
  }
  let ws_accept = WebSocketAccept(subprotocol=None, headers=[])
  let ws_deny_start = WebSocketHttpResponseStart(
    status=403,
    headers=[],
    trailers=false,
  )
  let valid_ws : Array[(String, Array[Event])] = [
    ("accept", [ws_accept]),
    (
      "accept+send+close",
      [ws_accept, WebSocketSendText("hi"), WebSocketClose(code=1000, reason="")],
    ),
    ("close", [WebSocketClose(code=1003, reason="no")]),
    (
      "deny",
      [ws_deny_start, WebSocketHttpResponseBody(body=b"no", more_body=false)],
    ),
  ]
  for vc in valid_ws {
    check("order/ws-valid/" + vc.0, validate_events(wscope, vc.1) == None)
  }
  let bad_ws : Array[(String, Array[Event], EventOrderError)] = [
    ("frame-before-accept", [WebSocketSendText("x")], FrameBeforeAccept),
    ("dup-accept", [ws_accept, ws_accept], DuplicateAccept),
    (
      "event-after-close",
      [WebSocketClose(code=1000, reason=""), WebSocketSendText("x")],
      EventAfterClose,
    ),
    (
      "denial-body-before-start",
      [WebSocketHttpResponseBody(body=b"", more_body=false)],
      DenialBodyBeforeStart,
    ),
    ("deny-after-accept", [ws_accept, ws_deny_start], DenialAfterAccept),
    ("accept-after-deny", [ws_deny_start, ws_accept], AcceptAfterDenial),
    ("incomplete-denial", [ws_deny_start], IncompleteDenial),
    ("missing-reply", [], MissingHandshakeReply),
  ]
  for bc in bad_ws {
    check("order/ws-bad/" + bc.0, validate_events(wscope, bc.1) == Some(bc.2))
  }
  let valid_ls : Array[(String, Array[Event])] = [
    ("startup+shutdown", [LifespanStartupComplete, LifespanShutdownComplete]),
    ("startup-failed", [LifespanStartupFailed(message="boom")]),
    (
      "shutdown-failed",
      [LifespanStartupComplete, LifespanShutdownFailed(message="x")],
    ),
  ]
  for vc in valid_ls {
    check("order/ls-valid/" + vc.0, validate_events(lscope, vc.1) == None)
  }
  let bad_ls : Array[(String, Array[Event], EventOrderError)] = [
    (
      "shutdown-before-startup",
      [LifespanShutdownComplete],
      ShutdownBeforeStartup,
    ),
    (
      "dup-startup",
      [LifespanStartupComplete, LifespanStartupComplete],
      DuplicateLifespanReply,
    ),
    (
      "reply-after-cycle",
      [
        LifespanStartupComplete,
        LifespanShutdownComplete,
        LifespanShutdownComplete,
      ],
      DuplicateLifespanReply,
    ),
    ("non-response-event", [HttpDisconnect], NonResponseEvent),
  ]
  for bc in bad_ls {
    check("order/ls-bad/" + bc.0, validate_events(lscope, bc.1) == Some(bc.2))
  }
  // J. lifespan driver: startup/shutdown replies, in-place state seeding, the
  //    full cycle's ordering, and the failed-startup short-circuit ASGI pins.
  let boot_scope = LifespanScope::new()
  let boot = LifespanHandler::new(on_startup=fn(s) {
    s.state["ready"] = true.to_json()
    Complete
  })
  let ls_driven = Lifespan(boot_scope)
  let up = run_lifespan(boot, ls_driven, [LifespanStartup])
  check("lifespan/startup-complete", up == [LifespanStartupComplete])
  check("lifespan/state-seeded", boot_scope.state.get("ready") is Some(_))
  let cyc_scope = Lifespan(LifespanScope::new())
  let cyc = run_lifespan(boot, cyc_scope, [LifespanStartup, LifespanShutdown])
  check(
    "lifespan/full-cycle",
    cyc == [LifespanStartupComplete, LifespanShutdownComplete],
  )
  check("lifespan/cycle-valid", validate_events(cyc_scope, cyc) == None)
  let sfail = LifespanHandler::new(on_shutdown=fn(_s) {
    Failed(message="drain")
  })
  check(
    "lifespan/shutdown-failed",
    run_lifespan(sfail, Lifespan(LifespanScope::new()), [LifespanShutdown]) ==
    [LifespanShutdownFailed(message="drain")],
  )
  let ufail = LifespanHandler::new(on_startup=fn(_s) { Failed(message="boom") })
  check(
    "lifespan/startup-failed-short-circuits",
    run_lifespan(ufail, Lifespan(LifespanScope::new()), [
      LifespanStartup,
      LifespanShutdown,
    ]) ==
    [LifespanStartupFailed(message="boom")],
  )
  check(
    "lifespan/non-lifespan-scope",
    run_lifespan(boot, hscope, [LifespanStartup]).length() == 0,
  )

  // K. scope-aware http core: run_http_scoped hands the app the full HttpScope
  //    (state, root_path) the ergonomic Request drops, and drains the body the
  //    same way run_http_app does.
  let seen_state : Array[Bool] = []
  let seen_root : Array[String] = []
  let scoped = fn(sh : HttpScope, sbody : Bytes) -> Array[Event] {
    seen_state.push(sh.state.get("k") is Some(_))
    seen_root.push(sh.root_path)
    [
      HttpResponseStart(status=200, headers=[], trailers=false),
      HttpResponseBody(body=sbody, more_body=false),
    ]
  }
  let scoped_scope = Http(
    HttpScope::new(
      http_method="POST",
      path="/x",
      root_path="/mnt",
      state=Map([("k", Json::string("v"))]),
    ),
  )
  let scoped_out = run_http_scoped(scoped, scoped_scope, [
    HttpRequest(body=b"ab", more_body=true),
    HttpRequest(body=b"c", more_body=false),
  ])
  check("scoped/state-visible", seen_state == [true])
  check("scoped/root-visible", seen_root == ["/mnt"])
  check("scoped/body-drained", reassemble(scoped_out).body == b"abc")
  check(
    "scoped/non-http-scope",
    run_http_scoped(scoped, lscope, [LifespanStartup]).length() == 0,
  )

  // L. HTTP/2 pseudo-header lowering: a HEADERS block (pseudo-headers + ordinary
  //    fields in wire order) maps onto an HttpScope the way a conforming h2/h2c
  //    server consumes a frame — request line from the pseudo-headers, host
  //    synthesised from :authority, `:`-prefixed names stripped from the header
  //    list — and every malformed set is rejected with the exact violation.
  let h2 = HttpScope::from_h2_headers([
    (":method", "POST"),
    (":scheme", "https"),
    (":authority", "example.test"),
    (":path", "/items?page=2&q=x"),
    ("content-type", "application/json"),
    ("accept", "*/*"),
  ])
  check(
    "h2/lower",
    match h2 {
      Ok(s) =>
        s.http_method == "POST" &&
        s.scheme == "https" &&
        s.http_version == "2" &&
        s.path == "/items" &&
        s.raw_path == b"/items" &&
        s.query_string == b"page=2&q=x" &&
        s.asgi.spec_version == "2.5" &&
        // :authority becomes the leading host header; pseudo-headers are gone.
        s.headers ==
        [
          ("host", "example.test"),
          ("content-type", "application/json"),
          ("accept", "*/*"),
        ]
      Err(_) => false
    },
  )
  // :authority replaces a host header the peer also sent (RFC 7540 §8.1.2.3).
  let h2_host = HttpScope::from_h2_headers([
    (":method", "GET"),
    (":scheme", "http"),
    (":authority", "authority.test"),
    (":path", "/"),
    ("host", "stale.test"),
    ("x-trace", "1"),
  ])
  check(
    "h2/authority-wins",
    match h2_host {
      Ok(s) => s.headers == [("host", "authority.test"), ("x-trace", "1")]
      Err(_) => false
    },
  )
  // No :authority: ordinary headers (including any host) pass through untouched,
  // and http_version="3" is honoured for the shared HTTP/3 pseudo-header path.
  let h3 = HttpScope::from_h2_headers(
    [(":method", "GET"), (":scheme", "https"), (":path", "/p"), ("host", "h")],
    http_version="3",
  )
  check(
    "h2/no-authority",
    match h3 {
      Ok(s) => s.http_version == "3" && s.headers == [("host", "h")]
      Err(_) => false
    },
  )
  let bad_h2 : Array[(String, Array[(String, String)], Http2HeaderError)] = [
    ("missing-method", [(":scheme", "https"), (":path", "/")], MissingMethod),
    ("missing-scheme", [(":method", "GET"), (":path", "/")], MissingScheme),
    ("missing-path", [(":method", "GET"), (":scheme", "https")], MissingPath),
    (
      "empty-path",
      [(":method", "GET"), (":scheme", "https"), (":path", "")],
      EmptyPath,
    ),
    (
      "dup-method",
      [
        (":method", "GET"),
        (":method", "POST"),
        (":scheme", "h"),
        (":path", "/"),
      ],
      DuplicatePseudoHeader(":method"),
    ),
    (
      "unknown-pseudo",
      [(":method", "GET"), (":scheme", "h"), (":path", "/"), (":x", "y")],
      UnknownPseudoHeader(":x"),
    ),
    (
      "pseudo-after-regular",
      [(":method", "GET"), ("a", "b"), (":scheme", "h"), (":path", "/")],
      PseudoHeaderAfterRegular(":scheme"),
    ),
  ]
  for bc in bad_h2 {
    check(
      "h2/bad/" + bc.0,
      match HttpScope::from_h2_headers(bc.1) {
        Err(e) => e == bc.2
        Ok(_) => false
      },
    )
  }
  // The SEAM is transport-version agnostic: an http_version="2" request drives
  // the exact same synchronous core and yields the same response as "1.1".
  let ver_seen : Array[String] = []
  let ver_client = TestClient::new(fn(req) {
    ver_seen.push(req.path)
    Response::text("v2")
  })
  let v2 = ver_client.request(http_method="GET", path="/h2", http_version="2")
  check(
    "h2/seam-agnostic",
    v2.status == 200 && v2.text() == "v2" && ver_seen == ["/h2"],
  )
  // M. header wire codec: the seam types headers as latin-1 Strings, but the ASGI
  //    spec types them as byte strings. The boundary codec must carry every byte
  //    0x00..0xFF losslessly, so the black-box header I/O conforms to the spec for
  //    any header a server puts on or takes off the wire.
  let all_bytes = Buffer()
  for b = 0; b < 256; b = b + 1 {
    all_bytes.write_byte(b.to_byte())
  }
  let wire_in : Array[(Bytes, Bytes)] = [
    (b"x-raw", all_bytes.to_bytes()),
    (b"content-type", b"application/json"),
  ]
  let decoded = headers_from_wire(wire_in)
  check("header/latin1-roundtrip", headers_to_wire(decoded) == wire_in)
  check("header/latin1-name", decoded[1].0 == "content-type")
  // Encoding a seam String header and decoding it back is the identity too.
  check(
    "header/latin1-seam-roundtrip",
    headers_from_wire(headers_to_wire([("x-a", "1"), ("x-b", "café")])) ==
    [("x-a", "1"), ("x-b", "café")],
  )
  // N. legacy 2.0 double-callable convention: run_legacy — the sync core of the
  //    two-call shape double_to_single_callable lifts — yields exactly what a
  //    single-callable app yields, so a 3.0 server stays backward-compatible with a
  //    legacy 2.0 app.
  let legacy_scope = Http(HttpScope::new(http_method="POST", path="/l"))
  let legacy_inbound : Array[Event] = [HttpRequest(body=b"z", more_body=false)]
  let legacy_handler : Handler = fn(_r) { Response::text("ok") }
  let legacy_out = run_legacy(
    fn(sc) { fn(inb) { run_http(legacy_handler, sc, inb) } },
    legacy_scope,
    legacy_inbound,
  )
  check(
    "legacy/matches-single",
    legacy_out == run_http(legacy_handler, legacy_scope, legacy_inbound),
  )
  // NOTE on what is *not* here: `to_asgi` and `guarantee_single_callable` produce
  //    an async callable, and this package has no runtime to drive one — that is the
  //    whole point of the seam. Their coverage lives in `mooncat`, which has the
  //    runtime; here only the synchronous cores they lift can be checked.

  // P. middleware composition: the first registered is the outermost, so it sees
  //    the request first and the response last.
  let trace : Array[String] = []
  let outer : Middleware = next => {
    req => {
      trace.push("outer-in")
      let resp = next(req)
      trace.push("outer-out")
      resp
    }
  }
  let inner : Middleware = next => {
    req => {
      trace.push("inner-in")
      next(req)
    }
  }
  let composed = compose([outer, inner], fn(_r) { Response::text("body") })
  let composed_out = composed({
    http_method: "GET",
    path: "/c",
    query_string: b"",
    headers: [],
    body: b"",
  })
  check("middleware/order", trace == ["outer-in", "inner-in", "outer-out"])
  check("middleware/response", composed_out.status == 200)

  // R. subprotocol selection: the server picks the client's first offer it knows,
  //    in the client's order of preference, and `None` when there is no overlap.
  let ws_offer = WebSocketScope::new(path="/ws", subprotocols=[
    "graphql-transport-ws", "graphql-ws",
  ])
  check(
    "ws/subprotocol-picks-client-preference",
    ws_offer.select_subprotocol(["graphql-ws", "graphql-transport-ws"]) ==
    Some("graphql-transport-ws"),
  )
  check(
    "ws/subprotocol-none-on-no-overlap",
    ws_offer.select_subprotocol(["mqtt"]) is None,
  )

  // S. the tls extension: a named spec extension with zero coverage until now.
  let tls : TlsExtension = {
    server_cert: Some("-----BEGIN CERTIFICATE-----"),
    client_cert_chain: ["a", "b"],
    client_cert_name: Some("CN=heke1228"),
    client_cert_error: None,
    tls_version: Some(0x0304),
    cipher_suite: Some(0x1301),
  }
  let with_tls = Extensions::none().with_tls(tls)
  check("tls/round-trips", with_tls.tls == Some(tls))
  check("tls/absent-by-default", Extensions::none().tls is None)

  // T. streaming responses: `run_http_stream` lowers a StreamingResponse the same
  //    way `run_http` lowers a Response.
  let stream_scope = Http(HttpScope::new(http_method="GET", path="/stream"))
  let streamed = run_http_stream(
    fn(_req) {
      StreamingResponse::new(status=200, headers=[("x-stream", "1")], chunks=[
        b"one", b"two",
      ])
    },
    stream_scope,
    [HttpRequest(body=b"", more_body=false)],
  )
  check("stream/emits-start-and-chunks", streamed.length() >= 3)
  check(
    "stream/terminates-once",
    streamed[streamed.length() - 1] is HttpResponseBody(more_body=false, ..),
  )

  let failures : Array[String] = []
  for r in results {
    if !r.1 {
      failures.push(r.0)
    }
  }
  {
    total: results.length(),
    passed: results.length() - failures.length(),
    failures,
  }
}

///|
/// The legacy 2.0 double-callable convention must produce exactly what the same
/// handler produces single-callably: `@spec.run_legacy` (the sync core) equals `@http.run_http`.
/// `@spec.double_to_single_callable` is the async lift of this same two-step shape.
test "run_legacy: the two-call convention matches a single-callable app" {
  let handler : @http.Handler = fn(req) {
    @http.Response::new(200, [("x-m", req.http_method)], req.body)
  }
  // A legacy app: the first callable takes the scope and returns an instance that
  // folds the inbound event stream — the 2.0 double-callable shape over the sync core.
  let legacy : (@spec.Scope) -> (Array[@spec.Event]) -> Array[@spec.Event] = fn(
    scope,
  ) {
    fn(inbound) { @http.run_http(handler, scope, inbound) }
  }
  let scope = @spec.Scope::Http(
    @spec.HttpScope::new(http_method="POST", path="/x"),
  )
  let inbound : Array[@spec.Event] = [HttpRequest(body=b"hi", more_body=false)]
  let out = @spec.run_legacy(legacy, scope, inbound)
  assert_eq(out == @http.run_http(handler, scope, inbound), true)
  assert_eq(out.length(), 2)
  assert_eq(
    out[0] ==
    HttpResponseStart(status=200, headers=[("x-m", "POST")], trailers=false),
    true,
  )
  assert_eq(out[1] == HttpResponseBody(body=b"hi", more_body=false), true)
}

///|
/// The first (synchronous) callable is invoked with the connection scope — the step
/// that distinguishes the double-callable convention from the single one.
test "run_legacy hands the scope to the first callable" {
  let seen : Array[String] = []
  let legacy : (@spec.Scope) -> (Array[@spec.Event]) -> Array[@spec.Event] = fn(
    scope,
  ) {
    match scope {
      Http(hs) => seen.push(hs.path)
      _ => ()
    }
    fn(inbound) {
      @http.run_http(fn(_req) { @http.Response::text("ok") }, scope, inbound)
    }
  }
  let _ = @spec.run_legacy(
    legacy,
    @spec.Scope::Http(@spec.HttpScope::new(http_method="GET", path="/deep")),
    [HttpRequest(body=b"", more_body=false)],
  )
  assert_eq(seen, ["/deep"])
}

///|
/// The convention is protocol-agnostic: a legacy websocket app over `@ws.ws_run` yields
/// the same frames as driving the handler directly.
test "run_legacy carries a websocket app too" {
  let ws_handler = @ws.WebSocketHandler::echo()
  let legacy : (@spec.Scope) -> (Array[@spec.Event]) -> Array[@spec.Event] = fn(
    scope,
  ) {
    fn(inbound) { @ws.ws_run(ws_handler, scope, inbound) }
  }
  let scope = @spec.Scope::WebSocket(@spec.WebSocketScope::new(path="/ws"))
  let inbound : Array[@spec.Event] = [
    WebSocketConnect,
    WebSocketReceive(text=Some("hi"), bytes=None),
  ]
  let out = @spec.run_legacy(legacy, scope, inbound)
  assert_eq(out == @ws.ws_run(ws_handler, scope, inbound), true)
  assert_eq(out[0] == WebSocketAccept(subprotocol=None, headers=[]), true)
  assert_eq(out[1] == WebSocketSendText("hi"), true)
}

///|
/// The public async surface type-checks: both a single-callable app and a legacy
/// double-callable app normalize through `@spec.guarantee_single_callable` /
/// `@spec.double_to_single_callable` to an `@spec.AsgiApp` a server can drive. (The async result
/// runs under mooncat; here the constructors and the normaliser are exercised.)
test "the legacy compatibility wrappers normalize both conventions" {
  let single_app : @spec.AsgiApp = @http.to_asgi(fn(_req) {
    @http.Response::text("ok")
  })
  let legacy_app : @spec.LegacyAsgiApp = fn(_scope) {
    let inst : @spec.AsgiAppInstance = (_receive, send) => ignore(send)
    inst
  }
  // @spec.guarantee_single_callable accepts either variant and yields an @spec.AsgiApp; the
  // built values below would fail to type-check if the wiring were wrong.
  let normalized : Array[@spec.AsgiApp] = [
    @spec.guarantee_single_callable(Single(single_app)),
    @spec.guarantee_single_callable(Legacy(legacy_app)),
    @spec.double_to_single_callable(legacy_app),
  ]
  assert_eq(normalized.length(), 3)
}

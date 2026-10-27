// ASGI 2.0 legacy double-callable applications (main spec, "Legacy Applications").
// The current spec is single-callable — application(scope, receive, send) — but a 3.0
// server is encouraged to keep running legacy 2.0 apps for backward compatibility.
// A legacy app's first callable is synchronous and takes the scope, returning the
// asynchronous instance that then drives the connection. MoonBit has no signature or
// attribute reflection to auto-detect the convention the way asgiref's
// guarantee_single_callable does, so the two conventions are distinct types and the
// choice is an explicit constructor (AsgiApplication) — the same shape Rust/Go take.

///|
/// The asynchronous instance a legacy app's first callable returns: already bound to
/// the scope, it drives the connection with `receive` / `send`.
pub type AsgiAppInstance = async (Receive, Send) -> Unit

///|
/// A legacy ASGI 2.0 double-callable application: a synchronous `application(scope)`
/// that returns the `AsgiAppInstance`.
pub type LegacyAsgiApp = (Scope) -> AsgiAppInstance

///|
/// An application in either calling convention — the current 3.0 single-callable form
/// or the legacy 2.0 double-callable form. A server holds one of these and normalizes
/// it with `guarantee_single_callable`; the enum is the typed, reflection-free stand-in
/// for asgiref detecting the convention at runtime.
pub(all) enum AsgiApplication {
  Single(AsgiApp)
  Legacy(LegacyAsgiApp)
}

///|
/// Wrap a legacy 2.0 double-callable app as a 3.0 single-callable `AsgiApp`
/// (asgiref's `double_to_single_callable`): call the first callable with the scope to
/// get the instance, then drive it with `receive` / `send`.
pub fn double_to_single_callable(app : LegacyAsgiApp) -> AsgiApp {
  (scope, receive, send) => {
    let instance = app(scope)
    instance(receive, send)
  }
}

///|
/// Normalize any application to a single-callable `AsgiApp` (asgiref's
/// `guarantee_single_callable`): a 3.0 app passes straight through, a legacy 2.0 app
/// is wrapped. A server calls this once and then only ever drives single-callables.
pub fn guarantee_single_callable(app : AsgiApplication) -> AsgiApp {
  match app {
    Single(a) => a
    Legacy(l) => double_to_single_callable(l)
  }
}

///|
/// The synchronous core of the legacy two-call convention, testable without an async
/// runtime the way `run_http` is for `to_asgi`: the first callable takes the scope and
/// returns an instance that folds the inbound event stream into the outbound one.
/// `double_to_single_callable` is the async lift of exactly this two-step shape, so a
/// green `run_legacy` covers the convention's semantics that the async wrapper relies
/// on.
pub fn run_legacy(
  app : (Scope) -> (Array[Event]) -> Array[Event],
  scope : Scope,
  inbound : Array[Event],
) -> Array[Event] {
  let instance = app(scope)
  instance(inbound)
}

///|
/// An application's answer to a lifespan phase: `Complete` when startup or
/// shutdown succeeded, or `Failed` with a message the server logs and (for
/// startup) aborts the boot on. Mirrors the two replies ASGI allows to each
/// lifespan message — `lifespan.startup.complete` / `.failed` and
/// `lifespan.shutdown.complete` / `.failed`.
pub(all) enum LifespanReply {
  Complete
  Failed(message~ : String)
} derive(Eq)

///|
/// A synchronous lifespan application in the startup / shutdown shape, the
/// lifespan analog of the http `Handler` and the WebSocket `WebSocketHandler`.
/// `on_startup` runs once at boot: it seeds the scope's `state` in place (the map
/// the server then copies onto every request scope — a DB pool handle, a loaded
/// config) and returns `Complete` or `Failed`. `on_shutdown` runs once at
/// teardown to release those resources. Driven in-process by `run_lifespan`, so
/// boot/teardown logic is testable on every backend without an async runtime —
/// the faithful synchronous core the async server (`mooncat`) lifts onto the
/// lifespan protocol.
pub(all) struct LifespanHandler {
  on_startup : (@spec.LifespanScope) -> LifespanReply
  on_shutdown : (@spec.LifespanScope) -> LifespanReply
}

///|
/// Build a `LifespanHandler`. Both phases default to succeeding without doing
/// anything, so a caller overrides only the phase it needs — an app that just
/// wants a startup hook leaves `on_shutdown` alone.
pub fn LifespanHandler::new(
  on_startup? : (@spec.LifespanScope) -> LifespanReply = fn(_s) { Complete },
  on_shutdown? : (@spec.LifespanScope) -> LifespanReply = fn(_s) { Complete },
) -> LifespanHandler {
  { on_startup, on_shutdown, }
}

///|
/// Lower one `LifespanReply` to the outbound `@spec.Event` a server sends for a phase:
/// `startup` picks the startup reply pair, `shutdown` the shutdown pair.
fn lifespan_reply_event(reply : LifespanReply, startup : Bool) -> @spec.Event {
  match (reply, startup) {
    (Complete, true) => LifespanStartupComplete
    (Complete, false) => LifespanShutdownComplete
    (Failed(message~), true) => LifespanStartupFailed(message~)
    (Failed(message~), false) => LifespanShutdownFailed(message~)
  }
}

///|
/// Drive a `LifespanHandler` over a materialised inbound event stream, folding it
/// into the outbound replies a server would send. `LifespanStartup` runs
/// `on_startup` and emits `LifespanStartupComplete` or `LifespanStartupFailed`; a
/// failed startup ends the run, since ASGI has the server abort the boot and
/// never send `lifespan.shutdown`. `LifespanShutdown` runs `on_shutdown` and
/// emits the matching shutdown reply. The handler mutates `scope.state` in place
/// during startup, exactly as an ASGI app populates `scope["state"]`. This is the
/// synchronous lifespan core mirroring `run_http` / `ws_run`; a non-lifespan
/// scope yields `[]`.
pub fn run_lifespan(
  handler : LifespanHandler,
  scope : @spec.Scope,
  inbound : Array[@spec.Event],
) -> Array[@spec.Event] {
  match scope {
    Lifespan(ls) => {
      let out : Array[@spec.Event] = []
      let mut startup_failed = false
      for ev in inbound {
        if startup_failed {
          break
        }
        match ev {
          LifespanStartup => {
            let reply = (handler.on_startup)(ls)
            out.push(lifespan_reply_event(reply, true))
            if reply is Failed(..) {
              startup_failed = true
            }
          }
          LifespanShutdown =>
            out.push(lifespan_reply_event((handler.on_shutdown)(ls), false))
          _ => ()
        }
      }
      out
    }
    _ => []
  }
}

///|
pub extend LifespanReply with Eq::{not_equal, equal}

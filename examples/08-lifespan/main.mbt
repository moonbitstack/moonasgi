// Copyright 2026 Leo Cheng
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// The lifespan protocol. A `LifespanHandler`'s startup seeds `scope.state` in
/// place - the map a server copies onto every request scope - and returns
/// `Complete` or `Failed`; shutdown releases it. `run_lifespan` drives the
/// startup/shutdown cycle in-process. A failed startup short-circuits: ASGI
/// aborts the boot and never sends shutdown.
///
///     moon run examples/08-lifespan
#coverage.skip
fn main {
  let handler = @moonasgi.LifespanHandler::new(
    on_startup=fn(s) {
      s.state["db_pool"] = "pool://heke1228".to_json()
      s.state["greeting"] = "Bonjour".to_json()
      @lifespan.Complete
    },
    on_shutdown=fn(_s) { @lifespan.Complete },
  )
  let scope = @moonasgi.LifespanScope::new()
  let driven = @moonasgi.Scope::Lifespan(scope)
  let cycle = @moonasgi.run_lifespan(handler, driven, [
    @spec.LifespanStartup,
    @spec.LifespanShutdown,
  ])
  for ev in cycle {
    match ev {
      @spec.LifespanStartupComplete => println("<- startup.complete")
      @spec.LifespanShutdownComplete => println("<- shutdown.complete")
      @spec.LifespanStartupFailed(message~) =>
        println("<- startup.failed: " + message)
      @spec.LifespanShutdownFailed(message~) =>
        println("<- shutdown.failed: " + message)
      _ => ()
    }
  }
  let seeded = match scope.state.get("greeting") {
    Some(String(v)) => v
    _ => "?"
  }
  println(
    "state after startup: greeting=\{seeded} (\{scope.state.length()} keys)",
  )
  let cycle_ok = @moonasgi.validate_lifespan_replies(cycle) is None
  println("cycle well-formed: \{cycle_ok}")

  // A failed startup aborts the boot: ASGI never proceeds to shutdown.
  let failing = @moonasgi.LifespanHandler::new(on_startup=fn(_s) {
    @lifespan.Failed(message="db unreachable")
  })
  let aborted = @moonasgi.run_lifespan(
    failing,
    @moonasgi.Scope::Lifespan(@moonasgi.LifespanScope::new()),
    [@spec.LifespanStartup, @spec.LifespanShutdown],
  )
  println("failed startup emitted \{aborted.length()} reply (shutdown skipped)")
  for ev in aborted {
    match ev {
      @spec.LifespanStartupFailed(message~) => println("  reason: " + message)
      _ => ()
    }
  }
}

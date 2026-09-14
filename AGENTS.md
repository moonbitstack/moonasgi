`moonasgi` is the ASGI 3.0 seam for MoonBit: one typed contract — `Scope` / `Receive` / `Send` — that servers and frameworks meet in the middle on. `mooncat` implements the server side; `moonapi`, `moonrpc`, `moongql` and `moonzero` sit on the application side and, because of it, never depend on an async runtime directly.

# Working here

- `moon fmt` before anything else. CI runs `moon fmt && git diff --exit-code`, so an unformatted file fails the build on its own.
- `moon check --target all --deny-warn` and `moon build --target all` are the gate. Warnings are errors, and all four backends (wasm, wasm-gc, js, native) must pass.
- `moon test --target all`.
- `moon info` regenerates `pkg.generated.mbti`. If that file does not change, your edit is not visible to anyone depending on this package, which usually means the refactor was safe. If it does change, read the diff before committing — that is the public interface moving, and here it is also the contract five other repos are written against. The examples regenerate their own, which is why those are gitignored.
- CI installs the latest moon on every run, so a toolchain that is behind will disagree with it. Upgrade locally rather than pinning.

# Layout

`asgi.mbt` is the seam itself — `Scope`, `Event`, `Receive`, `Send`, `AsgiApp`. The protocol families sit beside it: `http.mbt`, `http2.mbt`, `websocket.mbt`, `lifespan.mbt`. `headers.mbt` is the header representation both sides share, `legacy.mbt` the ASGI 2.0 double-callable convention, `validate.mbt` the outbound event-order rules, and `conformance.mbt` a harness that drives the whole seam and reports what passed. `client.mbt` is the in-process driver used to exercise an app without a socket. Tests sit beside their subject as `*_wbtest.mbt`; `examples/NN-topic/` are runnable one-file demos.

# Things worth knowing

- This package has no runtime dependency and no I/O, on purpose. That is the whole point of the seam: it compiles on every backend, and the async churn stays in one server adapter. A change that would pull in `moonbitlang/async` belongs in `mooncat` instead.
- The seam is a published contract with five consumers. Renaming a variant or adding a required field is a breaking change for all of them, so prefer additive shapes and check the diff in `pkg.generated.mbti` before committing.
- `validate_events` names the *first* ordering violation in a stream and nothing after it. Adding a rule means extending `EventOrderError` and the walk, plus a negative case in the conformance table — the harness is what proves a rule actually fires.
- The harness cannot drive `to_asgi` or `guarantee_single_callable`: they produce an async callable and this package has no runtime, which is the whole point of the seam. Their coverage belongs in `mooncat`. Everything synchronous — the cores, middleware composition, subprotocol selection, the tls extension, streaming — is covered here.
- `run_conformance` is public deliberately: a server or framework built on the seam can call it to self-verify its wiring, so it has to stay usable outside this repo's tests.
- ASGI 2.0 apps are a separate type rather than an auto-detected convention. `guarantee_single_callable` exists and does what its asgiref namesake does once you have said which convention you have; what has no equivalent is asgiref's `is_double_callable`, since MoonBit has no signature reflection to detect it. The choice is an explicit constructor and should stay one.
- The seam is open where the spec is open: `Extensions::enable`/`get` carry extensions this file does not name, and `Event::Other` carries a message type it does not name. `validate_events` passes those through rather than calling them out-of-scope.

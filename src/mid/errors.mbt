// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What an application's failure becomes: a 500 when the response has not started, then the
/// error raised on to the server, which logs it. `debug` puts the error in the body. `handler`
/// writes the answer instead: `(status, headers, body)` for the error.
pub(all) struct ServerErrors {
  debug : Bool
  handler : ((Error) -> (Int32, Array[(String, String)], String))?
}

///|
/// The defaults: no detail in the body, the plain 500.
pub let server_errors : ServerErrors = { debug: false, handler: None, }

///|
pub fn ServerErrors::new(
  debug~ : Bool = server_errors.debug,
  handler? : (Error) -> (Int32, Array[(String, String)], String),
) -> ServerErrors {
  { debug, handler, }
}

///|
pub impl Layer for ServerErrors with fn wrap(self, app) {
  (scope, receive, send) => {
    guard scope is Http(_) else {
      app(scope, receive, send)
      return
    }
    let started = Ref(false)
    let failure : Ref[Error?] = Ref(None)
    app(scope, receive, event => {
      if event is HttpResponseStart(..) {
        started.val = true
      }
      send(event)
    }) catch {
      e => failure.val = Some(e)
    }
    guard failure.val is Some(e) else { return }
    if !started.val {
      let (status, headers, body) = match self.handler {
        Some(f) => f(e)
        None if self.debug => (500, [], "Internal Server Error\n\n\{e}")
        None => (500, [], "Internal Server Error")
      }
      respond(send, status, headers, body)
    }
    raise e
  }
}

///|
pub extend ServerErrors with Layer::{wrap}

///|
/// A ceiling on a request body. A `Content-Length` above it is answered `413` at
/// once, without calling the application. A body that grows past it while the
/// application reads it is answered `413` too, when no response has started;
/// the application then reads a disconnect, and what it sends afterwards is
/// dropped, since the client already has its answer.
pub(all) struct BodyLimit {
  limit : Int32
} derive(Eq, Debug)

///|
pub extend BodyLimit with Eq::{equal, not_equal}

///|
pub extend BodyLimit with Debug::{to_repr}

///|
/// One mebibyte, nginx's `client_max_body_size`.
pub let body_limit : BodyLimit = { limit: 1 << 20, }

///|
pub fn BodyLimit::new(limit~ : Int32 = body_limit.limit) -> BodyLimit {
  { limit, }
}

///|
pub impl Layer for BodyLimit with fn wrap(self, app) {
  (scope, receive, send) => {
    guard scope is Http(hs) else {
      app(scope, receive, send)
      return
    }
    let declared = header(hs.headers, "content-length").map(v => {
      @string.parse_int64(v.trim(chars=" ")) catch {
        _ => -1L
      }
    })
    if declared is Some(n) && n > self.limit.to_int64() {
      respond(send, 413, [], "Content Too Large")
      return
    }
    let mut seen = 0
    let mut started = false
    let mut refused = false
    let guarded_receive : @spec.Receive = () => {
      if refused {
        return HttpDisconnect
      }
      let event = receive()
      if event is HttpRequest(body~, ..) {
        seen += body.length()
        if seen > self.limit {
          refused = true
          if !started {
            started = true
            respond(send, 413, [], "Content Too Large")
          }
          return HttpDisconnect
        }
      }
      event
    }
    let guarded_send : @spec.Send = event => {
      if refused {
        return
      }
      if event is HttpResponseStart(..) {
        started = true
      }
      send(event)
    }
    app(scope, guarded_receive, guarded_send)
  }
}

///|
pub extend BodyLimit with Layer::{wrap}

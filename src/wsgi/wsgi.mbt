// Synchronous applications on an ASGI server (← WSGI, PEP 3333, and the
// adapters that run one under ASGI). The application is a plain function: it
// cannot wait, and the server waits for nothing while it runs.

///|
/// How a synchronous application starts its response (← WSGI's
/// `start_response`): the status line, such as `"200 OK"`, and the headers. It
/// gives back a function that writes part of the body at once, for code written
/// against that older style; returning the body is the usual way.
pub type StartResponse = (String, Array[(String, String)]) -> (Bytes) -> Unit

///|
/// A synchronous application (← a WSGI application): the environment and
/// `start_response` in, the body out, chunk by chunk. A chunk is sent as soon
/// as the iterator yields it, so a long body streams.
pub type WsgiApp = (Environ, StartResponse) -> Iter[Bytes] raise

///|
/// `app` as an ASGI application. The request body is
/// read in full before `app` runs, since it reads it as one value. The status
/// and headers go out with the first chunk of the body, written or yielded; a
/// header name is lowered, as ASGI asks of a response.
///
/// An application that raises, one that never calls `start_response`, and one
/// that yields a body before it does all get a `500`. A WebSocket is declined,
/// since a
/// synchronous application has no way to hold one, and the lifespan is answered
/// as complete, since it has nothing to start.
pub fn to_asgi(app : WsgiApp) -> @spec.AsgiApp {
  (scope, receive, send) => {
    match scope {
      Http(hs) => serve(app, hs, receive, send)
      WebSocket(_) => send(WebSocketClose(code=1000, reason=""))
      Lifespan(_) =>
        while true {
          match receive() {
            LifespanStartup => send(LifespanStartupComplete)
            LifespanShutdown => {
              send(LifespanShutdownComplete)
              break
            }
            _ => break
          }
        }
    }
  }
}

///|
async fn serve(
  app : WsgiApp,
  hs : @spec.HttpScope,
  receive : @spec.Receive,
  send : @spec.Send,
) -> Unit {
  let body = Buffer()
  while true {
    match receive() {
      HttpRequest(body=part, more_body~) => {
        body.write_bytes(part)
        if !more_body {
          break
        }
      }
      _ => return
    }
  }
  let environ = Environ::of(hs, body.to_bytes())
  let mut head : (Int32, Array[(String, String)])? = None
  let written : Array[Bytes] = []
  let start : StartResponse = (status, headers) => {
    head = Some((code_of(status), headers.map(h => (h.0.to_lower(), h.1))))
    chunk => written.push(chunk)
  }
  let chunks = app(environ, start) catch { _ => return failure(send) }
  let mut started = false
  // What was written or yielded goes out once the response has started; the
  // last part of the last flush ends the body.
  let flush = async fn(last : Bool) {
    guard head is Some((status, headers)) else { return }
    if !started {
      started = true
      send(HttpResponseStart(status~, headers~, trailers=false))
    }
    let parts = written.copy()
    written.clear()
    for i, part in parts {
      send(
        HttpResponseBody(body=part, more_body=!last || i < parts.length() - 1),
      )
    }
    if last && parts.is_empty() {
      send(HttpResponseBody(body=b"", more_body=false))
    }
  }
  while chunks.next() is Some(chunk) {
    if !chunk.is_empty() {
      written.push(chunk)
    }
    if head is None {
      // A body before a status has nowhere to go.
      if !written.is_empty() {
        return failure(send)
      }
      continue
    }
    flush(false)
  }
  if head is None {
    return failure(send)
  }
  flush(true)
}

///|
/// The status code at the start of a status line; `500` for one that has none.
fn code_of(status : String) -> Int32 {
  let digits = match status.find(" ") {
    Some(k) => status.view(end_offset=k)
    None => status[:]
  }
  @string.parse_int(digits) catch {
    _ => 500
  }
}

///|
async fn failure(send : @spec.Send) -> Unit {
  send(
    HttpResponseStart(
      status=500,
      headers=[("content-type", "text/plain; charset=utf-8")],
      trailers=false,
    ),
  )
  send(HttpResponseBody(body=b"Internal Server Error", more_body=false))
}

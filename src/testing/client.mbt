///|
/// An in-process client for a real `AsgiApp`, as Starlette's `TestClient`. Each request runs
/// the application on a fresh scope, feeds it the body, sends `http.disconnect` once the
/// response is complete, and waits for the application to return, so an error it raises fails
/// the test. `@client.TestClient` is the synchronous counterpart for event-folding handlers.
///
/// `state` is the lifespan state: `lifespan` hands it to the application's startup, and every
/// request and WebSocket scope gets a shallow copy, as the lifespan sub-specification asks.
pub(all) struct Client {
  app : @spec.AsgiApp
  root_path : String
  base_headers : Array[(String, String)]
  client : (String, Int32)?
  server : (String, Int32?)?
  extensions : @spec.Extensions
  state : Map[String, Json]
  timeout : Int32
}

///|
/// Build a `Client` for `app`. The peers default to Starlette's `("testclient", 50000)` and
/// `("testserver", 80)`; `timeout` is how long each wait for the application lasts.
pub fn Client::new(
  app : @spec.AsgiApp,
  root_path~ : String = "",
  base_headers~ : Array[(String, String)] = [],
  client~ : (String, Int32)? = Some(("testclient", 50000)),
  server~ : (String, Int32?)? = Some(("testserver", Some(80))),
  extensions~ : @spec.Extensions = @spec.Extensions::none(),
  state~ : Map[String, Json] = {},
  timeout~ : Int32 = timeout,
) -> Client {
  { app, root_path, base_headers, client, server, extensions, state, timeout, }
}

///|
/// Drive one request through the application and capture the response. `path` may carry a
/// query string; the client's `base_headers` go before `headers`; `chunks` streams the body as
/// several `http.request` events. A body goes with its `content-length`, as a client sends it,
/// unless the headers already frame it.
///
/// Raises `Finished` if the application returns before completing the response, `Timeout` if
/// it stalls, and the application's own error if it fails, before or after responding. An
/// application that streams without end never completes; drive it with `communicate`.
pub async fn Client::request(
  self : Client,
  http_method~ : String,
  path~ : String,
  headers~ : Array[(String, String)] = [],
  body~ : Bytes = b"",
  http_version~ : String = "1.1",
  chunks? : Array[Bytes],
) -> @client.TestResponse {
  let (p, q) = @spec.split_target(path)
  let all = [..self.base_headers, ..headers]
  let framed = all
    .iter()
    .any(h => h.0.to_lower() is ("content-length" | "transfer-encoding"))
  let size = match chunks {
    Some(parts) => parts.fold(init=0, (n, part) => n + part.length())
    None => body.length()
  }
  if size > 0 && !framed {
    all.push(("content-length", size.to_string()))
  }
  let scope = @spec.HttpScope::new(
    http_method~,
    path=p,
    http_version~,
    query_string=@utf8.encode(q),
    root_path=self.root_path,
    headers=all,
    client?=self.client,
    server?=self.server,
    extensions=self.extensions,
    state=self.state.copy(),
  )
  communicate(self.app, Http(scope), timeout=self.timeout, c => {
    for event in @client.request_events(body, chunks?) {
      c.send(event)
    }
    let events = []
    let mut trailing = false
    while true {
      let event = c.receive()
      events.push(event)
      let complete = match event {
        HttpResponseStart(trailers~, ..) => {
          trailing = trailers
          false
        }
        HttpResponseBody(more_body=false, ..)
        | HttpResponseZeroCopySend(more_body=false, ..) => !trailing
        HttpResponseTrailers(more_trailers=false, ..)
        | HttpResponsePathSend(_) => true
        _ => false
      }
      if complete {
        break
      }
    }
    c.send(HttpDisconnect)
    @client.reassemble([..events, ..c.drain()])
  })
}

///|
/// `GET path`.
pub async fn Client::get(
  self : Client,
  path : String,
  headers~ : Array[(String, String)] = [],
) -> @client.TestResponse {
  self.request(http_method="GET", path~, headers~)
}

///|
/// `HEAD path`.
pub async fn Client::head(
  self : Client,
  path : String,
  headers~ : Array[(String, String)] = [],
) -> @client.TestResponse {
  self.request(http_method="HEAD", path~, headers~)
}

///|
/// `DELETE path`.
pub async fn Client::delete(
  self : Client,
  path : String,
  headers~ : Array[(String, String)] = [],
) -> @client.TestResponse {
  self.request(http_method="DELETE", path~, headers~)
}

///|
/// `POST path` with `body`.
pub async fn Client::post(
  self : Client,
  path : String,
  body~ : Bytes = b"",
  headers~ : Array[(String, String)] = [],
) -> @client.TestResponse {
  self.request(http_method="POST", path~, headers~, body~)
}

///|
/// `PUT path` with `body`.
pub async fn Client::put(
  self : Client,
  path : String,
  body~ : Bytes = b"",
  headers~ : Array[(String, String)] = [],
) -> @client.TestResponse {
  self.request(http_method="PUT", path~, headers~, body~)
}

///|
/// `PATCH path` with `body`.
pub async fn Client::patch(
  self : Client,
  path : String,
  body~ : Bytes = b"",
  headers~ : Array[(String, String)] = [],
) -> @client.TestResponse {
  self.request(http_method="PATCH", path~, headers~, body~)
}

///|
/// Open a WebSocket to `path`, run `body` with the accepted `Session`, then close the
/// connection with `1000` unless `body` already did, and wait for the application to return.
///
/// Raises `Closed` if the application closes before accepting, `Denied` with the response if
/// it declines with `websocket.http.response`, and `Unexpected` for any other first reply.
pub async fn[X] Client::websocket(
  self : Client,
  path~ : String,
  body : async (Session) -> X,
  headers~ : Array[(String, String)] = [],
  subprotocols~ : Array[String] = [],
) -> X {
  let (p, q) = @spec.split_target(path)
  let scope = @spec.WebSocketScope::new(
    path=p,
    query_string=@utf8.encode(q),
    root_path=self.root_path,
    headers=[..self.base_headers, ..headers],
    client?=self.client,
    server?=self.server,
    subprotocols~,
    asgi=@spec.AsgiVersion::websocket(),
    extensions=self.extensions,
    state=self.state.copy(),
  )
  communicate(self.app, WebSocket(scope), timeout=self.timeout, c => {
    c.send(WebSocketConnect)
    match c.receive() {
      WebSocketAccept(subprotocol~, headers~) => {
        let session = { comm: c, subprotocol, headers, closed: false, }
        let x = body(session)
        if !session.closed {
          session.close()
        }
        ignore(c.drain())
        x
      }
      WebSocketClose(code~, reason~) => raise Closed(status=code, reason~)
      WebSocketHttpResponseStart(status~, headers~, trailers~) => {
        let events : Array[@spec.Event] = [
          HttpResponseStart(status~, headers~, trailers~),
        ]
        while true {
          match c.receive() {
            WebSocketHttpResponseBody(body~, more_body~) => {
              events.push(HttpResponseBody(body~, more_body~))
              if !more_body {
                break
              }
            }
            e => raise Unexpected(e)
          }
        }
        raise Denied(@client.reassemble(events))
      }
      e => raise Unexpected(e)
    }
  })
}

///|
/// Run the application's lifespan startup, then `body`, then its shutdown, as entering and
/// leaving Starlette's `with TestClient(app)`. Startup sees this client's `state`, so what it
/// stores there is in every scope `body` opens. Shutdown runs even if `body` fails.
///
/// Raises `Startup` or `Shutdown` with the application's message when it reports a failure,
/// and `Unexpected` for any other reply.
pub async fn[X] Client::lifespan(self : Client, body : async () -> X) -> X {
  let scope = @spec.LifespanScope::new(state=self.state)
  communicate(self.app, Lifespan(scope), timeout=self.timeout, c => {
    c.send(LifespanStartup)
    match c.receive() {
      LifespanStartupComplete => ()
      LifespanStartupFailed(message~) => raise Startup(message)
      e => raise Unexpected(e)
    }
    errdefer (shutdown(c) catch { _ => () })
    let x = body()
    shutdown(c)
    x
  })
}

///|
async fn shutdown(c : Communicator) -> Unit {
  c.send(LifespanShutdown)
  match c.receive() {
    LifespanShutdownComplete => ()
    LifespanShutdownFailed(message~) => raise Shutdown(message)
    e => raise Unexpected(e)
  }
}

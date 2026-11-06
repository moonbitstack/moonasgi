///|
/// An in-process client for a real `AsgiApp`. Each request runs
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
  scheme : String
  jar : @cookie.Jar
  follow_redirects : Bool
  max_redirects : Int32
  clock : () -> Int64
}

///|
/// Build a `Client` for `app`. The peers default to `("testclient", 50000)` and
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
  scheme~ : String = "http",
  jar? : @cookie.Jar,
  follow_redirects~ : Bool = false,
  max_redirects~ : Int32 = 20,
  clock? : () -> Int64,
) -> Client {
  {
    app,
    root_path,
    base_headers,
    client,
    server,
    extensions,
    state,
    timeout,
    scheme,
    jar: jar.unwrap_or(@cookie.Jar::new()),
    follow_redirects,
    max_redirects,
    clock: clock.unwrap_or(fn() { (@env.now() / 1000UL).reinterpret_as_int64() }),
  }
}

///|
/// Drive one request through the application and capture the response. `path` may carry a
/// query string; the client's `base_headers` go before `headers`; `chunks` streams the body as
/// several `http.request` events. A body goes with its `content-length`, as a client sends it,
/// unless the headers already frame it.
///
/// With `follow_redirects` a `3xx` carrying a `location` is followed — up to `max_redirects`
/// hops, after which the last response is returned as it is. A `303` continues as a `GET` with
/// no body, as does a `301`/`302` answering a `POST`, which is what a browser does; `307` and
/// `308` keep both. The jar keeps whatever a hop set, so a login that redirects and sets a
/// cookie is one request.
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
  let mut verb = http_method
  let mut target = path
  let mut body = body
  let mut chunks = chunks
  let mut scheme : String? = None
  let mut host : String? = None
  let mut hops = 0
  let mut response = self.forward(
    verb,
    target,
    headers~,
    body~,
    http_version~,
    chunks?,
    scheme?,
    host?,
  )
  guard self.follow_redirects else { return response }
  while hops < self.max_redirects {
    guard response.header("location") is Some(location) else { break }
    let status = response.status
    guard status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308 else {
      break
    }
    guard self.resolve(target, location, scheme?, host?) is Some(next) else {
      break
    }
    hops = hops + 1
    scheme = Some(next.0)
    host = Some(next.1)
    target = next.2
    // The method a redirect keeps: 303 always drops to GET, and so does a 301 or
    // 302 answering a POST — that is what browsers settled on.
    if status == 303 || ((status == 301 || status == 302) && verb == "POST") {
      verb = "GET"
      body = b""
      chunks = None
    }
    response = self.forward(
      verb,
      target,
      headers~,
      body~,
      http_version~,
      chunks?,
      scheme?,
      host?,
    )
  }
  response
}

///|
/// One hop: run the application on a scope built from `method` and `target`, carrying the
/// cookies the jar holds for that host and path, then store whatever the response set.
async fn Client::forward(
  self : Client,
  http_method : String,
  path : String,
  headers~ : Array[(String, String)],
  body~ : Bytes,
  http_version~ : String,
  chunks? : Array[Bytes],
  scheme? : String,
  host? : String,
) -> @client.TestResponse {
  let host_override = host
  let (p, q) = @spec.split_target(path)
  let scheme = scheme.unwrap_or(self.scheme)
  let headers = [..self.base_headers, ..headers]
  // A redirect that named a host sends it; otherwise the request goes where the
  // caller's `host` header says, or to the client's own server.
  let host = match host {
    Some(host) => host
    None =>
      match header_of(headers, "host") {
        Some(header) => header
        None => self.default_host()
      }
  }
  let now = (self.clock)()
  let all = self.with_cookies(
    headers,
    host~,
    path=p,
    now~,
    secure=scheme == "https",
  )
  let all = match host_override {
    Some(host) => put_header(all, "host", host)
    None => all
  }
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
    scheme~,
    query_string=@utf8.encode(q),
    root_path=self.root_path,
    headers=all,
    client?=self.client,
    server?=self.server,
    extensions=self.extensions,
    state=self.state.copy(),
  )
  let response = communicate(self.app, Http(scope), timeout=self.timeout, c => {
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
  self.remember(response, host~, path=p, now~)
  response
}

///|
/// The host a request goes to when the caller named none: the client's own server, or
/// `testserver` when it was built without one. A cookie is kept per host, so this is the name a
/// jar files it under.
fn Client::default_host(self : Client) -> String {
  match self.server {
    Some(peer) => peer.0
    None => "testserver"
  }
}

///|
/// The headers with the jar's cookies for `host` and `path` added, or with an existing `cookie`
/// header extended: a request carries one such header, and a caller may have set it.
fn Client::with_cookies(
  self : Client,
  headers : Array[(String, String)],
  host~ : String,
  path~ : String,
  now~ : Int64,
  secure~ : Bool,
) -> Array[(String, String)] {
  let cookies = match self.jar.header(host~, path~, now~, secure~) {
    Some(cookies) => cookies
    None => return headers.copy()
  }
  match header_of(headers, "cookie") {
    Some(existing) => put_header(headers, "cookie", existing + "; " + cookies)
    None => [..headers, ("cookie", cookies)]
  }
}

///|
/// Store what a response said about cookies: every `set-cookie` line goes into the jar, filed
/// under the host that answered and the path of the request, as a browser files it.
fn Client::remember(
  self : Client,
  response : @client.TestResponse,
  host~ : String,
  path~ : String,
  now~ : Int64,
) -> Unit {
  let directory = directory_of(path)
  for pair in response.headers {
    if pair.0 != "set-cookie" {
      continue
    }
    let parsed = try Some(@cookie.SetCookie::parse(pair.1)) catch {
      _ => None
    } noraise {
      cookie => cookie
    }
    match parsed {
      Some(cookie) =>
        self.jar.store(cookie, host~, now~, default_path=directory)
      None => ()
    }
  }
}

///|
/// The cookie the client holds under `name`, as a request to `path` would send it. A test asks
/// this to see what a login left behind without writing a header itself.
pub fn Client::cookie(
  self : Client,
  name : String,
  path~ : String = "/",
) -> String? {
  self.jar.get(
    name,
    host=self.default_host(),
    path~,
    now=(self.clock)(),
    secure=self.scheme == "https",
  )
}

///|
/// Every cookie a request to `path` would carry, in the order it would send them.
pub fn Client::cookies(
  self : Client,
  path~ : String = "/",
) -> Array[(String, String)] {
  self.jar.pairs(
    host=self.default_host(),
    path~,
    now=(self.clock)(),
    secure=self.scheme == "https",
  )
}

///|
/// Where a redirect sends the next hop: the scheme, the host, and the target to request. A
/// relative `location` resolves against the request that produced it, an absolute one names its
/// own host. `None` when the location is not a URL this client can follow.
fn Client::resolve(
  self : Client,
  target : String,
  location : String,
  scheme? : String,
  host? : String,
) -> (String, String, String)? {
  let scheme = scheme.unwrap_or(self.scheme)
  let host = host.unwrap_or(self.default_host())
  let base = @moonurl.Url::new(scheme~, host~, path=target)
  let next = try @moonurl.Url::decode(location, base~) catch {
    _ => return None
  } noraise {
    url => url
  }
  let next_scheme = next.scheme.unwrap_or(scheme)
  let next_host = next.host.unwrap_or(host)
  let path = if next.path == "" { "/" } else { next.path }
  let target = match next.query {
    Some(query) => path + "?" + query
    None => path
  }
  Some((next_scheme, next_host, target))
}

///|
/// The directory a request's path sits in: what a cookie with no `Path` belongs to
/// (RFC 6265 §5.1.4). `/app/items` belongs to `/app`, and `/` to `/`.
fn directory_of(path : String) -> String {
  match path.rev_find("/") {
    Some(0) => "/"
    Some(at) => path[0:at].to_owned()
    None => "/"
  }
}

///|
/// The value of `name` in a header list, matched without regard to case.
fn header_of(headers : Array[(String, String)], name : String) -> String? {
  for pair in headers {
    if pair.0.to_lower() == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// `headers` with `name` set to `value`, replacing any earlier value.
fn put_header(
  headers : Array[(String, String)],
  name : String,
  value : String,
) -> Array[(String, String)] {
  [..headers.filter(pair => pair.0.to_lower() != name), (name, value)]
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
  // A handshake carries the cookies a request would: a chat connection opened
  // after a login is identified by the same stage of the exchange.
  let secure = self.scheme == "https"
  let headers = self.with_cookies(
    [..self.base_headers, ..headers],
    host=self.default_host(),
    path=p,
    now=(self.clock)(),
    secure~,
  )
  let scope = @spec.WebSocketScope::new(
    path=p,
    scheme=if secure { "wss" } else { "ws" },
    query_string=@utf8.encode(q),
    root_path=self.root_path,
    headers~,
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
/// leaving the client's lifespan scope. Startup sees this client's `state`, so what it
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
    // A cancelled body still owes the application its shutdown, so the shutdown itself is not cancelled.
    errdefer (@async.protect_from_cancel(() => shutdown(c)) catch { _ => () })
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

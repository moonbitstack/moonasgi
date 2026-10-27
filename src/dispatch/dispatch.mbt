// Several applications behind one: by path prefix, as a mount, or by host name.
// A server runs one application per listening socket; this is how a moonapi app,
// an MCP server and a GraphQL endpoint share it.

///|
/// One application per path prefix (← Starlette's `Mount`, a dispatcher that
/// picks an application by the start of the path). A prefix matches whole
/// segments, so `/api` takes `/api` and `/api/users` but not `/apis`; when two
/// prefixes match, the longer wins, whatever the order they were given in. `""`
/// or `"/"` matches every path.
///
/// The application chosen sees the path below its prefix, `/` at the least,
/// and the prefix added to `root_path`, the way the ASGI spec has a mounted
/// application see its own location. A path no prefix takes goes to `fallback`,
/// or is answered with `404` (HTTP) or a declined handshake (WebSocket).
///
/// The lifespan reaches every application, the fallback last; see `lifespan`.
pub fn mount(
  routes : Array[(String, @spec.AsgiApp)],
  fallback? : @spec.AsgiApp,
) -> @spec.AsgiApp {
  let prefixes = routes.map(r => (trim(r.0), r.1))
  let all = prefixes.map(r => r.1)
  if fallback is Some(f) {
    all.push(f)
  }
  (scope, receive, send) => {
    match scope {
      Lifespan(ls) => lifespan(all, ls, receive, send)
      Http(hs) =>
        match pick(prefixes, hs.path) {
          Some((prefix, app)) => {
            let scope : @spec.HttpScope = {
              ..hs,
              path: below(hs.path, prefix),
              raw_path: strip_raw(hs.raw_path, prefix),
              root_path: hs.root_path + prefix,
            }
            app(Http(scope), receive, send)
          }
          None => unmatched(fallback, scope, receive, send)
        }
      WebSocket(ws) =>
        match pick(prefixes, ws.path) {
          Some((prefix, app)) => {
            let scope : @spec.WebSocketScope = {
              ..ws,
              path: below(ws.path, prefix),
              raw_path: strip_raw(ws.raw_path, prefix),
              root_path: ws.root_path + prefix,
            }
            app(WebSocket(scope), receive, send)
          }
          None => unmatched(fallback, scope, receive, send)
        }
    }
  }
}

///|
/// One application per host name (← Starlette's `Host`). A name matches the
/// request's `Host` header without its port and without regard to case;
/// `*.example.com` matches every name below `example.com`, not `example.com`
/// itself. The first route that matches is taken. A host no route takes goes
/// to `fallback`, or is answered as `mount` answers an unmatched path.
///
/// The lifespan reaches every application, the fallback last; see `lifespan`.
pub fn hosts(
  routes : Array[(String, @spec.AsgiApp)],
  fallback? : @spec.AsgiApp,
) -> @spec.AsgiApp {
  let names = routes.map(r => (r.0.to_lower(), r.1))
  let all = names.map(r => r.1)
  if fallback is Some(f) {
    all.push(f)
  }
  (scope, receive, send) => {
    let headers = match scope {
      Http(hs) => hs.headers
      WebSocket(ws) => ws.headers
      Lifespan(ls) => return lifespan(all, ls, receive, send)
    }
    let host = host_of(headers)
    match names.iter().find_first(r => host_matches(r.0, host)) {
      Some((_, app)) => app(scope, receive, send)
      None => unmatched(fallback, scope, receive, send)
    }
  }
}

///|
fn trim(prefix : String) -> String {
  prefix.trim_end(chars="/").to_owned()
}

///|
/// The longest prefix that takes `path` by whole segments.
fn pick(
  prefixes : Array[(String, @spec.AsgiApp)],
  path : String,
) -> (String, @spec.AsgiApp)? {
  let mut best : (String, @spec.AsgiApp)? = None
  for route in prefixes {
    let (prefix, _) = route
    let takes = prefix == "" || path == prefix || path.has_prefix(prefix + "/")
    if takes && (best is None || best.unwrap().0.length() < prefix.length()) {
      best = Some(route)
    }
  }
  best
}

///|
fn below(path : String, prefix : String) -> String {
  let rest = path.view(start_offset=prefix.length()).to_owned()
  if rest == "" {
    "/"
  } else {
    rest
  }
}

///|
/// `raw` without the prefix, when it starts with the prefix's bytes; a raw path
/// that spells the prefix differently (percent-encoded) is left whole.
fn strip_raw(raw : Bytes, prefix : String) -> Bytes {
  let p = @utf8.encode(prefix)
  if raw.length() >= p.length() && raw[:p.length()] == p[:] {
    let rest = raw[p.length():].to_owned()
    if rest.length() == 0 {
      b"/"
    } else {
      rest
    }
  } else {
    raw
  }
}

///|
/// The `Host` header in lower case, without its port.
fn host_of(headers : Array[(String, String)]) -> String {
  guard headers.iter().find_first(h => h.0.to_lower() == "host")
    is Some((_, value)) else {
    return ""
  }
  let host = value.trim(chars=" ").to_lower()
  if host.has_prefix("[") {
    match host.find("]") {
      Some(end) => host.view(end_offset=end + 1).to_owned()
      None => host.to_owned()
    }
  } else {
    match host.rev_find(":") {
      Some(k) => host.view(end_offset=k).to_owned()
      None => host.to_owned()
    }
  }
}

///|
fn host_matches(pattern : String, host : String) -> Bool {
  if pattern.has_prefix("*.") {
    let suffix = pattern.view(start_offset=1)
    host.length() > suffix.length() && host.has_suffix(suffix)
  } else {
    pattern == host
  }
}

///|
async fn unmatched(
  fallback : @spec.AsgiApp?,
  scope : @spec.Scope,
  receive : @spec.Receive,
  send : @spec.Send,
) -> Unit {
  match (fallback, scope) {
    (Some(app), _) => app(scope, receive, send)
    (None, Http(_)) => {
      send(
        HttpResponseStart(
          status=404,
          headers=[("content-type", "text/plain; charset=utf-8")],
          trailers=false,
        ),
      )
      send(HttpResponseBody(body=b"Not Found", more_body=false))
    }
    (None, WebSocket(_)) => send(WebSocketClose(code=1000, reason=""))
    (None, Lifespan(_)) => ()
  }
}

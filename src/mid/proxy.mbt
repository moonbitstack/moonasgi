///|
/// The client and scheme a reverse proxy saw, put back in the scope, by
/// `X-Forwarded-For` / `X-Forwarded-Proto` or by RFC 7239's `Forwarded`. Only a
/// request from an address in
/// `trusted` is rewritten, since anyone else could claim any address; `"*"`
/// trusts every peer.
///
/// `X-Forwarded-For` gives the client: the rightmost address that is not
/// trusted, every proxy before it having appended its own; when all are
/// trusted, the leftmost. `X-Forwarded-Proto` gives the scheme, `http` or
/// `https` (`ws` or `wss` for a WebSocket). Without either header, the
/// `Forwarded` header is read the same way through its `for` and `proto`.
pub(all) struct ProxyHeaders {
  trusted : Array[String]
} derive(Eq, Debug)

///|
pub extend ProxyHeaders with Eq::{equal, not_equal}

///|
pub extend ProxyHeaders with Debug::{to_repr}

///|
/// The default: only a proxy on the same machine is believed.
pub let proxy_headers : ProxyHeaders = { trusted: ["127.0.0.1"], }

///|
pub fn ProxyHeaders::new(
  trusted~ : Array[String] = proxy_headers.trusted,
) -> ProxyHeaders {
  { trusted, }
}

///|
fn ProxyHeaders::trusts(self : ProxyHeaders, host : String) -> Bool {
  self.trusted.contains("*") || self.trusted.contains(host)
}

///|
/// The client and the scheme the headers name, each `None` when they name none.
fn ProxyHeaders::forwarded(
  self : ProxyHeaders,
  headers : Array[(String, String)],
) -> (String?, String?) {
  let fors = list(headers, "x-forwarded-for")
  let protos = list(headers, "x-forwarded-proto")
  if !fors.is_empty() || !protos.is_empty() {
    return (self.pick(fors).map(p => p.0), protos.get(0))
  }
  // RFC 7239: each element is one hop, `for=…;proto=…`, the client's first.
  let hops = list(headers, "forwarded").map(element => {
    let fields : Map[String, String] = Map([])
    for pair in element.split(";") {
      if pair.find("=") is Some(k) {
        let key = pair.view(end_offset=k).trim(chars=" ").to_lower()
        let value = pair.view(start_offset=k + 1).trim(chars=" \"").to_owned()
        fields[key.to_owned()] = value
      }
    }
    (address(fields.get("for").unwrap_or("")), fields.get("proto"))
  })
  match self.pick(hops.map(h => h.0)) {
    Some((_, i)) => (Some(hops[i].0), hops[i].1)
    None => (None, None)
  }
}

///|
/// The client among `chain` and its position: the rightmost untrusted entry,
/// or the leftmost when every entry is trusted.
fn ProxyHeaders::pick(
  self : ProxyHeaders,
  chain : Array[String],
) -> (String, Int32)? {
  for i = chain.length() - 1; i >= 0; i = i - 1 {
    if !self.trusts(chain[i]) {
      return Some((chain[i], i))
    }
  }
  if chain.is_empty() {
    None
  } else {
    Some((chain[0], 0))
  }
}

///|
/// Every comma-separated entry of every header named `name`, trimmed.
fn list(headers : Array[(String, String)], name : String) -> Array[String] {
  let out = []
  for h in headers {
    if h.0.to_lower() == name {
      for part in h.1.split(",") {
        let part = part.trim(chars=" ").to_owned()
        if !part.is_empty() {
          out.push(part)
        }
      }
    }
  }
  out
}

///|
/// A `Forwarded` node without its port and IPv6 brackets.
fn address(node : String) -> String {
  if node.has_prefix("[") {
    match node.find("]") {
      Some(end) => node.view(start_offset=1, end_offset=end).to_owned()
      None => node
    }
  } else {
    match node.find(":") {
      Some(k) if node.rev_find(":") == Some(k) =>
        node.view(end_offset=k).to_owned()
      _ => node
    }
  }
}

///|
fn scheme_for(proto : String?, websocket : Bool) -> String? {
  match (proto.map(p => p.to_lower()), websocket) {
    (Some("https" | "wss"), true) => Some("wss")
    (Some("http" | "ws"), true) => Some("ws")
    (Some("https" | "wss"), false) => Some("https")
    (Some("http" | "ws"), false) => Some("http")
    _ => None
  }
}

///|
pub impl Layer for ProxyHeaders with fn wrap(self, app) {
  (scope, receive, send) => {
    let scope = match scope {
      Http(hs) if hs.client is Some((peer, _)) && self.trusts(peer) => {
        let (client, proto) = self.forwarded(hs.headers)
        @spec.Scope::Http({
          ..hs,
          client: if client is Some(c) {
            Some((c, 0))
          } else {
            hs.client
          },
          scheme: scheme_for(proto, false).unwrap_or(hs.scheme),
        })
      }
      WebSocket(ws) if ws.client is Some((peer, _)) && self.trusts(peer) => {
        let (client, proto) = self.forwarded(ws.headers)
        @spec.Scope::WebSocket({
          ..ws,
          client: if client is Some(c) {
            Some((c, 0))
          } else {
            ws.client
          },
          scheme: scheme_for(proto, true).unwrap_or(ws.scheme),
        })
      }
      other => other
    }
    app(scope, receive, send)
  }
}

///|
pub extend ProxyHeaders with Layer::{wrap}

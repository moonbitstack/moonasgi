// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Only the hosts listed may be asked for, as Starlette's `TrustedHostMiddleware`: a `host`
/// header naming another answers 400. `*.example.com` allows any subdomain, `*` alone allows any
/// host. With `www_redirect`, a request for `example.com` where only `www.example.com` is listed
/// is sent there.
pub(all) struct TrustedHosts {
  hosts : Array[String]
  www_redirect : Bool
} derive(Eq, Debug)

///|
pub extend TrustedHosts with Eq::{equal, not_equal}

///|
pub extend TrustedHosts with Debug::{to_repr}

///|
/// Starlette's defaults: any host, and the redirect to `www.` on.
pub let trusted_hosts : TrustedHosts = { hosts: ["*"], www_redirect: true, }

///|
pub fn TrustedHosts::new(
  hosts~ : Array[String] = trusted_hosts.hosts,
  www_redirect~ : Bool = trusted_hosts.www_redirect,
) -> TrustedHosts {
  { hosts, www_redirect, }
}

///|
/// The host a `host` header names, without its port; an IPv6 literal keeps its brackets.
fn host_of(value : String) -> String {
  if value.has_prefix("[") {
    match value.find("]") {
      Some(i) => value[:i + 1].to_owned()
      None => value
    }
  } else {
    match value.find(":") {
      Some(i) => value[:i].to_owned()
      None => value
    }
  }
}

///|
pub impl Layer for TrustedHosts with fn wrap(self, app) {
  (scope, receive, send) => {
    guard view(scope) is Some(v) && !self.hosts.contains("*") else {
      app(scope, receive, send)
      return
    }
    let raw = header(v.headers, "host").unwrap_or("")
    let host = host_of(raw)
    let mut www = false
    for pattern in self.hosts {
      if host == pattern ||
        (pattern.has_prefix("*") && host.has_suffix(pattern[1:].to_owned())) {
        app(scope, receive, send)
        return
      }
      if "www." + host == pattern {
        www = true
      }
    }
    if www && self.www_redirect {
      redirect(send, "\{v.scheme}://www.\{raw}\{v.target}", v.websocket)
    } else {
      respond(send, 400, [], "Invalid host header", websocket=v.websocket)
    }
  }
}

///|
/// Send every plain request to its secure equivalent, as Starlette's `HTTPSRedirectMiddleware`:
/// `http` to `https` and `ws` to `wss`, with a 307 so the method and body are kept. Port 80 or 443
/// in the host is dropped; any other port stays.
pub(all) struct HttpsRedirect {} derive(Eq, Debug)

///|
pub extend HttpsRedirect with Eq::{equal, not_equal}

///|
pub extend HttpsRedirect with Debug::{to_repr}

///|
pub let https_redirect : HttpsRedirect = HttpsRedirect::{ }

///|
pub fn HttpsRedirect::new() -> HttpsRedirect {
  HttpsRedirect::{ }
}

///|
pub impl Layer for HttpsRedirect with fn wrap(_self, app) {
  (scope, receive, send) => {
    guard view(scope) is Some(v) && v.scheme is ("http" | "ws") else {
      app(scope, receive, send)
      return
    }
    let secure = if v.scheme == "http" { "https" } else { "wss" }
    let netloc = match header(v.headers, "host") {
      Some(h) =>
        match h.rev_find(":") {
          Some(i) if !h.has_suffix("]") && h[i + 1:] is ("80" | "443") =>
            h[:i].to_owned()
          _ => h
        }
      None =>
        match v.server {
          Some((name, Some(port))) if port != 80 && port != 443 =>
            "\{name}:\{port}"
          Some((name, _)) => name
          None => ""
        }
    }
    redirect(send, "\{secure}://\{netloc}\{v.target}", v.websocket)
  }
}

///|
pub extend TrustedHosts with Layer::{wrap}

///|
pub extend HttpsRedirect with Layer::{wrap}

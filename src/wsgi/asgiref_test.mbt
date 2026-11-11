// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The same requests through this library's WSGI adapter and through asgiref's,
// compared on the environment, the status line, the headers and the body.
//
// `scripts/gen_wsgi_vectors.py` runs asgiref 3.13.0 over the requests below and
// writes `asgiref_vectors_test.mbt` with what it produced. The fixtures here
// are those applications again, written the same way, so what differs between
// the two replies is the adapter and nothing else.

///|
fn vector_http(vector : AsgirefVector) -> @spec.HttpScope {
  let scope = @spec.HttpScope::new(
    http_method=vector.http_method,
    path=vector.path,
    root_path=vector.root_path,
    query_string=@utf8.encode(vector.query),
    headers=vector.headers,
    scheme=vector.scheme,
    http_version=vector.version,
  )
  let scope = match vector.client {
    Some(client) => { ..scope, client: Some(client), }
    None => scope
  }
  match vector.server {
    Some(server) => { ..scope, server: Some(server), }
    None => scope
  }
}

///|
/// One of the four applications the generator ran, written as it was there.
fn asgiref_fixture(app : Int32) -> @wsgi.WsgiApp {
  match app {
    0 =>
      (environ, start) => {
        ignore(
          start("201 Created", [
            ("Content-Type", "text/plain"),
            ("X-Method", environ.request_method),
          ]),
        )
        [b"hello", b"", b", ", b"world"].iter()
      }
    2 =>
      (environ, start) => {
        ignore(start("200 OK", [("Content-Type", "application/octet-stream")]))
        [environ.input].iter()
      }
    _ => {
      let every = b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"
      (_, start) => {
        ignore(start("200 OK", [("Content-Type", "application/octet-stream")]))
        [every, every].iter()
      }
    }
  }
}

///|
/// Status, headers and body as the adapter sent them, with the request body fed
/// in as one event.
async fn vector_reply(
  app : @spec.AsgiApp,
  scope : @spec.Scope,
  body : Bytes,
) -> (Int32, Array[(String, String)], Bytes) {
  let mut status = 0
  let mut headers : Array[(String, String)] = []
  let mut asked = false
  let out = Buffer()
  app(
    scope,
    fn() {
      if asked {
        HttpDisconnect
      } else {
        asked = true
        HttpRequest(body~, more_body=false)
      }
    },
    fn(event) {
      match event {
        HttpResponseStart(status=s, headers=h, ..) => {
          status = s
          headers = h
        }
        HttpResponseBody(body=chunk, ..) => out.write_bytes(chunk)
        _ => ()
      }
    },
  )
  (status, headers, out.to_bytes())
}

///|
async test "asgiref: the environment is the one asgiref builds, key for key" {
  for vector in asgiref_vectors() {
    let cgi = @wsgi.Environ::of(vector_http(vector), vector.body).to_map()
    for pair in vector.environ {
      let got = match cgi.get(pair.0) {
        Some(value) => value
        None => "absent"
      }
      if got != pair.1 {
        fail("\{vector.name}: \{pair.0} is \{got}, asgiref says \{pair.1}")
      }
    }
    // Everything this library says beyond that: the client's port, which asgiref
    // has no key for and a CGI server may set (RFC 3875 §4.1.9).
    for key, _ in cgi {
      if key != "REMOTE_PORT" && !vector.environ.any(pair => pair.0 == key) {
        fail("\{vector.name}: \{key} is not in asgiref's environment")
      }
    }
  }
}

///|
async test "asgiref: the status line, the headers and the body are the same" {
  for vector in asgiref_vectors() {
    let (status, headers, body) = vector_reply(
      @wsgi.to_asgi(asgiref_fixture(vector.app)),
      Http(vector_http(vector)),
      vector.body,
    )
    if status != vector.status {
      fail("\{vector.name}: status \{status}, asgiref says \{vector.status}")
    }
    for pair in vector.response_headers {
      if !headers.contains(pair) {
        fail("\{vector.name}: no header \{pair.0}: \{pair.1}")
      }
    }
    if headers.length() != vector.response_headers.length() {
      fail("\{vector.name}: \{headers.length()} headers, asgiref sent more")
    }
    if body != vector.response_body {
      fail(
        "\{vector.name}: \{body.length()} body bytes against \{vector.response_body.length()}",
      )
    }
  }
}

///|
test "asgiref: a port the transport did not report is the scheme's, not 0" {
  // asgiref writes `SERVER_PORT: "0"` when the scope's server has no port; a
  // WSGI application builds URLs out of these two variables, and a request on
  // port 0 is a request no client can make. PEP 3333 says the variable holds the
  // port the request came in on, so this library reports the scheme's own.
  let scope = @spec.HttpScope::new(
    http_method="GET",
    path="/",
    scheme="https",
    server=("api.test", None),
  )
  let environ = @wsgi.Environ::of(scope, b"")
  assert_eq(environ.server_port, "443")
  assert_eq(environ.to_map().get("SERVER_PORT"), Some("443"))
}

///|
test "asgiref: a raw query byte above ASCII is kept, not refused" {
  // asgiref decodes the query string as ASCII and raises on anything else, so
  // one such byte loses the whole request. Every byte string at this seam is
  // latin-1 — one code point per byte — so the byte survives, and a WSGI
  // application that hands it back as bytes gets the client's byte again.
  let scope = @spec.HttpScope::new(
    http_method="GET",
    path="/",
    query_string=b"tag=caf\xe9",
  )
  let environ = @wsgi.Environ::of(scope, b"")
  assert_eq(environ.query_string, "tag=caf\u{e9}")
  assert_eq(@spec.latin1_encode(environ.query_string), b"tag=caf\xe9")
}

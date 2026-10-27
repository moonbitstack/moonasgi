// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Gzip for responses a client accepts it for: a body of at
/// least `minimum` octets, sent in one message, not already content-encoded. `level` is the
/// zlib effort, 0 to 9.
///
/// A body sent in several messages is passed through as it comes: compressing it would hold it
/// back until the end, and a stream is sent in pieces so that it is not held back. An event
/// stream is never compressed, for the same reason.
pub(all) struct Gzip {
  minimum : Int32
  level : Int32
} derive(Eq, Debug)

///|
pub extend Gzip with Eq::{equal, not_equal}

///|
pub extend Gzip with Debug::{to_repr}

///|
/// The defaults: 500 octets and up, the most effort.
pub let gzip : Gzip = { minimum: 500, level: 9, }

///|
pub fn Gzip::new(
  minimum~ : Int32 = gzip.minimum,
  level~ : Int32 = gzip.level,
) -> Gzip {
  { minimum, level, }
}

///|
fn accepts_gzip(headers : Array[(String, String)]) -> Bool {
  header(headers, "accept-encoding") is Some(v) && v.to_lower().contains("gzip")
}

///|
fn Gzip::worth(
  self : Gzip,
  headers : Array[(String, String)],
  body : Bytes,
  more : Bool,
) -> Bool {
  !more &&
  body.length() >= self.minimum &&
  header(headers, "content-encoding") is None &&
  !(header(headers, "content-type") is Some(t) &&
  t.has_prefix("text/event-stream"))
}

///|
pub impl Layer for Gzip with fn wrap(self, app) {
  (scope, receive, send) => {
    guard scope is Http(h) && accepts_gzip(h.headers) else {
      app(scope, receive, send)
      return
    }
    // The start waits for the first body message, which decides whether to compress.
    let held : Ref[@spec.Event?] = Ref(None)
    let decided = Ref(false)
    app(scope, receive, event => {
      if decided.val {
        send(event)
        return
      }
      match (event, held.val) {
        (HttpResponseStart(trailers=false, ..), _) => held.val = Some(event)
        (
          HttpResponseBody(body~, more_body~),
          Some(HttpResponseStart(status~, headers~, trailers~)),
        ) => {
          decided.val = true
          held.val = None
          if self.worth(headers, body, more_body) {
            let packed = @gzip.gzip(body[:], level=self.level)
            let headers = put(headers, "content-encoding", "gzip")
              |> put("content-length", packed.length().to_string())
              |> vary("Accept-Encoding")
            send(HttpResponseStart(status~, headers~, trailers~))
            send(HttpResponseBody(body=packed, more_body=false))
          } else {
            send(HttpResponseStart(status~, headers~, trailers~))
            send(event)
          }
        }
        (other, Some(start)) => {
          decided.val = true
          held.val = None
          send(start)
          send(other)
        }
        (other, None) => send(other)
      }
    })
    if held.val is Some(start) {
      send(start)
    }
  }
}

///|
pub extend Gzip with Layer::{wrap}

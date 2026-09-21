// Copyright 2026 Leo Cheng
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// HTTP/2 (and HTTP/3) pseudo-header lowering. `HttpScope::from_h2_headers`
/// consumes a HEADERS block - `:method` / `:scheme` / `:authority` / `:path`
/// pseudo-headers interleaved with ordinary fields - into a typed `HttpScope`:
/// the request line comes from the pseudo-headers, `host` is synthesised from
/// `:authority`, and no `:`-prefixed name reaches the app. A malformed set is
/// rejected with the exact `Http2HeaderError`.
///
///     moon run examples/10-http2
#coverage.skip
fn main {
  let describe = fn(e : @moonasgi.Http2HeaderError) -> String {
    match e {
      @spec.MissingMethod => "missing :method"
      @spec.MissingScheme => "missing :scheme"
      @spec.MissingPath => "missing :path"
      @spec.EmptyPath => "empty :path"
      @spec.DuplicatePseudoHeader(n) => "duplicate " + n
      @spec.UnknownPseudoHeader(n) => "unknown " + n
      @spec.PseudoHeaderAfterRegular(n) => "pseudo after regular: " + n
    }
  }
  // A well-formed h2 HEADERS block lowers onto a scope.
  let frame = [
    (":method", "POST"),
    (":scheme", "https"),
    (":authority", "example.test"),
    (":path", "/items?page=2&q=heke1228"),
    ("content-type", "application/json"),
    ("accept", "*/*"),
  ]
  match @moonasgi.HttpScope::from_h2_headers(frame) {
    Ok(s) => {
      println(
        "method=\{s.http_method} scheme=\{s.scheme} version=\{s.http_version}",
      )
      println("path=\{s.path} query=\{@moonasgi.latin1_decode(s.query_string)}")
      let hdrs = s.headers.map(fn(kv) { kv.0 + ": " + kv.1 })
      println("headers: " + hdrs.join(" | "))
    }
    Err(e) => println("unexpected: " + describe(e))
  }
  // The same contract serves HTTP/3 - pass http_version="3".
  match
    @moonasgi.HttpScope::from_h2_headers(
      [(":method", "GET"), (":scheme", "https"), (":path", "/"), ("host", "h")],
      http_version="3",
    ) {
    Ok(s) => println("h3 version=\{s.http_version}")
    Err(e) => println("unexpected: " + describe(e))
  }
  // Each malformed pseudo-header set is rejected with its exact violation.
  let bad : Array[(String, Array[(String, String)])] = [
    ("missing :method", [(":scheme", "https"), (":path", "/")]),
    (
      "unknown :foo",
      [(":method", "GET"), (":scheme", "h"), (":path", "/"), (":foo", "x")],
    ),
    (
      "pseudo after regular",
      [(":method", "GET"), ("a", "b"), (":scheme", "h"), (":path", "/")],
    ),
  ]
  for case in bad {
    match @moonasgi.HttpScope::from_h2_headers(case.1) {
      Ok(_) => println(case.0 + " -> unexpectedly Ok")
      Err(e) => println(case.0 + " -> " + describe(e))
    }
  }
}

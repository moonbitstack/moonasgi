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
/// The header wire codec. ASGI types headers as byte strings; the seam carries
/// them as latin-1 `String`s because latin-1 is the lossless bijection between
/// bytes 0x00..0xFF and code points U+0000..U+00FF. `latin1_decode` /
/// `latin1_encode` and `headers_from_wire` / `headers_to_wire` cross that
/// boundary in one place, byte for byte.
///
///     moon run src/examples/11-headers
#coverage.skip
fn main {
  // A header value with a high byte (0xFF) still round-trips exactly.
  let raw : Bytes = b"application/json; x=\xff"
  let decoded = @moonasgi.latin1_decode(raw)
  println("decoded \{decoded.length()} chars from \{raw.length()} bytes")
  println("re-encode round-trips: \{@moonasgi.latin1_encode(decoded) == raw}")

  // A wire header list decodes to seam pairs and back, byte for byte.
  let wire : Array[(Bytes, Bytes)] = [
    (b"content-type", b"application/json"),
    (b"x-request-id", b"req-233"),
    (b"x-user", b"heke1228"),
  ]
  let seam = @moonasgi.headers_from_wire(wire)
  for kv in seam {
    println("  " + kv.0 + ": " + kv.1)
  }
  let identity = @moonasgi.headers_to_wire(seam) == wire
  println("headers_to_wire . headers_from_wire == id: \{identity}")

  // Every one of the 256 byte values survives the decode/encode round-trip.
  let buf = Buffer()
  for i in 0..<256 {
    buf.write_byte(i.to_byte())
  }
  let all = buf.to_bytes()
  let back = @moonasgi.latin1_encode(@moonasgi.latin1_decode(all))
  println("all 256 byte values round-trip: \{back == all}")
}

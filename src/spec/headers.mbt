// The header wire codec (ASGI www spec). ASGI types headers as byte-string pairs;
// the seam carries them as `(String, String)` because latin-1 (ISO-8859-1) is the
// bijection between bytes 0x00..0xFF and code points U+0000..U+00FF, so every header
// byte round-trips through a MoonBit String losslessly — the same decode Starlette
// applies internally. A server adapter (mooncat's HTTP/1.1 codec, moonrpc's HPACK)
// crosses this boundary once with `headers_from_wire` / `headers_to_wire`, so the
// codec discipline lives in one place instead of being re-derived per consumer.

///|
/// Decode a raw byte string to a latin-1 String: each byte becomes the character
/// with that code point. Total — every byte 0x00..0xFF is a valid code point.
pub fn latin1_decode(bytes : Bytes) -> String {
  let sb = StringBuilder()
  for i = 0; i < bytes.length(); i = i + 1 {
    sb.write_char(bytes[i].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// Encode a String back to a header byte string. The inverse of `latin1_decode` for
/// anything that came from the wire, since HTTP header values are latin-1 by the
/// protocol's own rules.
///
/// A character above U+00FF never came off a wire — it was put there by a framework
/// setting, say, a `content-disposition` filename — and truncating it to its low byte
/// would silently corrupt it. Those are written as their UTF-8 bytes instead, which is
/// what real servers emit and what RFC 6266 §4.3 expects a recipient to decode.
pub fn latin1_encode(s : String) -> Bytes {
  let buf = Buffer()
  for c in s {
    let code = c.to_int()
    if code <= 0xff {
      buf.write_byte(code.to_byte())
    } else {
      buf.write_bytes(@utf8.encode(c.to_string()))
    }
  }
  buf.to_bytes()
}

///|
/// Decode a wire header list (raw ASGI byte-string pairs, as they arrive off an
/// HTTP/1.1 or HPACK frame) into the `(String, String)` pairs the seam uses.
pub fn headers_from_wire(
  wire : Array[(Bytes, Bytes)],
) -> Array[(String, String)] {
  wire.map(fn(kv) { (latin1_decode(kv.0), latin1_decode(kv.1)) })
}

///|
/// Encode the seam's header list back to raw ASGI byte-string pairs for the wire.
/// The exact inverse of `headers_from_wire`, byte for byte.
pub fn headers_to_wire(
  headers : Array[(String, String)],
) -> Array[(Bytes, Bytes)] {
  headers.map(fn(kv) { (latin1_encode(kv.0), latin1_encode(kv.1)) })
}

///|
/// Split a request target into its path and raw query string on the first `?`;
/// `"/a/b?x=1&y=2"` → `("/a/b", "x=1&y=2")`, `"/a/b"` → `("/a/b", "")`.
pub fn split_target(target : String) -> (String, String) {
  for i in 0..<target.length() {
    if target[i].to_int() == 63 {
      return (target[0:i].to_owned(), target[i + 1:].to_owned())
    }
  }
  (target, "")
}

///|
/// The moment these tests sign at: a round one, so a failure is readable.
let signed_at : Int64 = 1_700_000_000L

///|
/// A layer with the test's secret and a clock that does not move.
fn signer(secret~ : Bytes = b"secret", now~ : Int64 = signed_at) -> Sessions {
  Sessions::new(secret~, clock=fn() { now })
}

///|
/// The signature a session cookie carries is itsdangerous's, byte for byte: for
/// the same payload at the same moment this layer signs exactly what the Python
/// signer signs, so either side reads the other's cookie. The vectors are
/// generated from itsdangerous itself (`scripts/gen_session_vectors.py`).
test "sessions: the signature is the one itsdangerous writes" {
  for vector in signatures {
    let (secret, payload, timestamp, signed) = vector
    let layer = Sessions::new(secret=@utf8.encode(secret), clock=fn() {
      timestamp
    })
    assert_eq(layer.sign(payload, now=timestamp), signed)
    assert_eq(layer.unsign(signed, now=timestamp), Some(payload))
  }
}

///|
/// A cookie Starlette's `SessionMiddleware` wrote reads here as the session it
/// carries: the payload is Starlette's — standard base64 of Python's
/// `json.dumps` — and the signature is over that text, so both are accepted as
/// they are.
test "sessions: a cookie written by a Python service reads here" {
  for vector in cookies {
    let (secret, cookie, expected) = vector
    let layer = Sessions::new(secret=@utf8.encode(secret), clock=fn() { 0L })
    let payload = match layer.unsign(cookie, now=1700000000L) {
      Some(payload) => payload
      None => abort("a Starlette cookie verifies")
    }
    let text = try @utf8.decode(base64url_decode(payload)) catch {
      _ => abort("the payload is base64")
    } noraise {
      text => text
    }
    assert_eq(text, expected)
  }
}

///|
/// A signature made with another secret, and one made over other bytes, verify as
/// nothing: that is the whole of what the signature buys.
test "sessions: a signature from another key is refused" {
  let signed = signer(now=signed_at).sign("payload", now=signed_at)
  assert_eq(Sessions::new(secret=b"other").unsign(signed, now=signed_at), None)
  // A signature over the same text at another moment is a different signature.
  assert_eq(
    signer(now=signed_at).unsign(signed, now=signed_at + 1L),
    Some("payload"),
  )
  // Editing the payload leaves the signature over the old text, so it is refused.
  let edited = "P" + signed[1:].to_owned()
  assert_eq(signer(now=signed_at).unsign(edited, now=signed_at), None)
  // A value with no signature at all is refused rather than read.
  assert_eq(signer(now=signed_at).unsign("payload", now=signed_at), None)
}

///|
/// The timestamp is checked against `max_age`, not against the wall clock: a
/// cookie signed for a moment older than the layer allows is refused, and one
/// signed with no age limit given is not checked at all.
test "sessions: the age limit is enforced on the signature's own timestamp" {
  let signed = signer(now=signed_at).sign("payload", now=signed_at)
  let later = signed_at + 60L
  assert_eq(
    Sessions::new(secret=b"secret", max_age=Some(30), clock=fn() { later }).unsign(
      signed,
      now=later,
    ),
    None,
  )
  assert_eq(
    Sessions::new(secret=b"secret", max_age=None, clock=fn() { later }).unsign(
      signed,
      now=later + 100_000L,
    ),
    Some("payload"),
  )
}

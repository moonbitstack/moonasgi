// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The expected lines below are copied from draft-ietf-httpapi-ratelimit-headers-11
// with the field name dropped: what is asserted is the field value, byte for
// byte, so a reader comparing the page with the encoder sees no difference.
//
// Two places in the draft are not what the fields' own grammar allows, and both
// are singletons below rather than table rows: a list written with a space after
// its comma, and a partition key that is not canonical base64.

///|
fn policy(
  name : String,
  quota : Int64,
  window? : Int64,
  unit? : String,
  key? : Bytes,
  extra~ : Array[String] = [],
) -> @mid.RateLimitPolicy {
  { name, quota, window, unit, key, extra, }
}

///|
fn limit(
  name : String,
  remaining : Int64,
  window? : Int64,
  key? : Bytes,
  extra~ : Array[String] = [],
) -> @mid.ServiceLimit {
  { name, remaining, window, key, extra, }
}

///|
test "quota: RateLimit-Policy is the specification's examples, byte for byte" {
  let cases : Array[(@mid.RateLimitPolicy, String)] = [
    (policy("default", 100L, window=10L), "\"default\";q=100;w=10"),
    (policy("permin", 50L, window=60L), "\"permin\";q=50;w=60"),
    (policy("perhr", 1000L, window=3600L), "\"perhr\";q=1000;w=3600"),
    (
      policy("peruser", 100L, window=60L, key=@base64.decode("cHsdsRa89w==")),
      "\"peruser\";q=100;w=60;pk=:cHsdsRa89w==:",
    ),
    (
      policy(
        "peruser",
        65535L,
        window=10L,
        unit="content-bytes",
        key=@base64.decode("sdfjLJUOUA=="),
      ),
      "\"peruser\";q=65535;qu=\"content-bytes\";w=10;pk=:sdfjLJUOUA==:",
    ),
  ]
  for pair in cases {
    assert_eq(pair.0.encode(), pair.1)
  }
  // Two of the draft's partition keys carry bits that base64 says are zero:
  // `cHsdsRa894==` and `sdfjLJUOUH==` are not canonical (RFC 4648 §3.5), and a
  // decoder may reject them. The bytes they stand for are the bytes this encoder
  // is handed, and it writes them back canonically — the safe side of the
  // disagreement, since a reader that decodes strictly must still understand the
  // field.
  assert_eq(
    policy("peruser", 100L, window=60L, key=@base64.decode("cHsdsRa894==")).encode(),
    "\"peruser\";q=100;w=60;pk=:cHsdsRa89w==:",
  )
  assert_eq(
    policy(
      "peruser",
      65535L,
      window=10L,
      unit="content-bytes",
      key=@base64.decode("sdfjLJUOUH=="),
    ).encode(),
    "\"peruser\";q=65535;qu=\"content-bytes\";w=10;pk=:sdfjLJUOUA==:",
  )
}

///|
test "quota: RateLimit is the specification's examples, byte for byte" {
  let cases : Array[(@mid.ServiceLimit, String)] = [
    (limit("default", 50L, window=30L), "\"default\";r=50;t=30"),
    (
      limit("default", 999L, key=@base64.decode("dHJpYWwxMjEzMjM=")),
      "\"default\";r=999;pk=:dHJpYWwxMjEzMjM=:",
    ),
    (
      limit(
        "default",
        300_000_000L,
        window=60L,
        key=@base64.decode("QXBwLTk5OQ=="),
      ),
      "\"default\";r=300000000;t=60;pk=:QXBwLTk5OQ==:",
    ),
    (limit("default", 1L, window=7L), "\"default\";r=1;t=7"),
    (limit("problemPolicy", 0L, window=10L), "\"problemPolicy\";r=0;t=10"),
  ]
  for pair in cases {
    assert_eq(pair.0.encode(), pair.1)
  }
}

///|
test "quota: the appendix's field lines, byte for byte" {
  let limits : Array[(@mid.ServiceLimit, String)] = [
    (limit("default", 0L, window=50L), "\"default\";r=0;t=50"),
    (limit("default", 0L, window=48L), "\"default\";r=0;t=48"),
    (limit("dayLimit", 100L, window=36000L), "\"dayLimit\";r=100;t=36000"),
    (limit("basic", 60L, window=58L), "\"basic\";r=60;t=58"),
    (limit("basic", 20L, window=56L), "\"basic\";r=20;t=56"),
    (limit("default", 0L, window=5L), "\"default\";r=0;t=5"),
    (limit("fixedwindow", 99L, window=50L), "\"fixedwindow\";r=99;t=50"),
    (limit("dynamic", 9L, window=50L), "\"dynamic\";r=9;t=50"),
    (limit("dynamic", 0L, window=20L), "\"dynamic\";r=0;t=20"),
    (limit("dynamic", 15L, window=40L), "\"dynamic\";r=15;t=40"),
    (limit("daily", 1L, window=86400L), "\"daily\";r=1;t=86400"),
    (limit("somepolicy", 10000L, window=10L), "\"somepolicy\";r=10000;t=10"),
    (limit("day", 100L, window=36000L), "\"day\";r=100;t=36000"),
    (limit("default", 50L, window=60L), "\"default\";r=50;t=60"),
    (limit("sliding", 50L, window=44L), "\"sliding\";r=50;t=44"),
  ]
  for pair in limits {
    assert_eq(pair.0.encode(), pair.1)
  }
  let policies : Array[(@mid.RateLimitPolicy, String)] = [
    (policy("basic", 100L, window=60L), "\"basic\";q=100;w=60"),
    (policy("fixedwindow", 100L, window=60L), "\"fixedwindow\";q=100;w=60"),
    (policy("dynamic", 100L, window=60L), "\"dynamic\";q=100;w=60"),
    (policy("dynamic", 15L, window=20L), "\"dynamic\";q=15;w=20"),
    (
      policy("somepolicy", 10000L, window=1000L),
      "\"somepolicy\";q=10000;w=1000",
    ),
  ]
  for pair in policies {
    assert_eq(pair.0.encode(), pair.1)
  }
}

///|
test "quota: a field is a list of items joined with a comma" {
  let hour = policy("hour", 1000L, window=3600L)
  let day = policy("day", 5000L, window=86400L)
  assert_eq(
    [hour.encode(), day.encode()].join(","),
    "\"hour\";q=1000;w=3600,\"day\";q=5000;w=86400",
  )
  // The appendix writes this list with a space after the comma; Structured
  // Fields joins a list with a bare comma (RFC 8941 §4.1.1), as the footer of
  // the same draft does, so the canonical form is the one asserted above.
}

///|
test "quota: a parameter the specification leaves open is appended as written" {
  let sliding = policy("sliding", 100L, window=60L, extra=["burst=1000"])
  assert_eq(sliding.encode(), "\"sliding\";q=100;w=60;burst=1000")
  let fixed = policy("fixed", 5000L, window=3600L, extra=["burst=0"])
  assert_eq(fixed.encode(), "\"fixed\";q=5000;w=3600;burst=0")
}

///|
test "quota: a name is quoted and its quote and backslash escaped" {
  assert_eq(policy("say \"hi\"\\", 1L).encode(), "\"say \\\"hi\\\"\\\\\";q=1")
}

///|
test "quota: no window and no unit leave their parameters out" {
  assert_eq(limit("default", 0L).encode(), "\"default\";r=0")
  assert_eq(policy("default", 0L).encode(), "\"default\";q=0")
}

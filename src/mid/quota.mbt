// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The two fields a server uses to tell a client how much of its quota is left, as
// HTTP Structured Fields (RFC 8941) write them: `RateLimit-Policy` states the
// quota a policy grants, `RateLimit` what is left of it right now.
//
// The records here are the items of those fields, not the fields themselves: a
// field is a list of items joined with `,`, and a layer that reports one policy
// writes one item. Encoding is byte for byte what the specification's examples
// show — quoted policy names, parameters in the order it declares them.

///|
/// A quota policy, as one item of a `RateLimit-Policy` field
/// (draft-ietf-httpapi-ratelimit-headers §3.1): the name that identifies the
/// policy, the `quota` it grants, and the `window` it grants it over, the `unit`
/// the quota counts in, the partition `key` it is allocated to, and any
/// parameters the specification does not define.
///
/// `window` is in seconds, and `None` states a quota with no time limit.
/// `unit` is `None` for the default, requests; the other units are
/// `"content-bytes"` and `"concurrent-requests"`.
#derive(Eq, Debug)
pub(all) struct RateLimitPolicy {
  name : String
  quota : Int64
  window : Int64?
  unit : String?
  key : Bytes?
  extra : Array[String]
}

///|
pub extend RateLimitPolicy with Eq::{equal, not_equal}

///|
pub extend RateLimitPolicy with Debug::{to_repr}

///|
/// What is left of a quota, as one item of a `RateLimit` field
/// (draft-ietf-httpapi-ratelimit-headers §4.1): the `name` of the policy it
/// belongs to, the `remaining` quota, the `window` within which no more than that
/// may be used, the partition `key`, and any parameters the specification does
/// not define.
///
/// `window` is in seconds, and `None` states a quota that is not time limited.
/// A client reads `remaining` as what it may still send, and `window` as how long
/// that holds: it says nothing about what comes after, which the server may
/// change between requests.
#derive(Eq, Debug)
pub(all) struct ServiceLimit {
  name : String
  remaining : Int64
  window : Int64?
  key : Bytes?
  extra : Array[String]
}

///|
pub extend ServiceLimit with Eq::{equal, not_equal}

///|
pub extend ServiceLimit with Debug::{to_repr}

///|
/// The item as the field writes it: `"default";q=100;w=10`, with `qu` before `w`
/// and `pk` last, the order the specification declares its parameters in.
pub fn RateLimitPolicy::encode(self : RateLimitPolicy) -> String {
  let out = StringBuilder()
  write_string(out, self.name)
  write_integer(out, "q", self.quota)
  match self.unit {
    Some(unit) => {
      out.write_string(";qu=")
      write_string(out, unit)
    }
    None => ()
  }
  match self.window {
    Some(window) => write_integer(out, "w", window)
    None => ()
  }
  match self.key {
    Some(key) => write_key(out, key)
    None => ()
  }
  write_extra(out, self.extra)
  out.to_string()
}

///|
/// The item as the field writes it: `"default";r=50;t=30`, with `pk` last.
pub fn ServiceLimit::encode(self : ServiceLimit) -> String {
  let out = StringBuilder()
  write_string(out, self.name)
  write_integer(out, "r", self.remaining)
  match self.window {
    Some(window) => write_integer(out, "t", window)
    None => ()
  }
  match self.key {
    Some(key) => write_key(out, key)
    None => ()
  }
  write_extra(out, self.extra)
  out.to_string()
}

///|
/// A name as a Structured Fields String: always quoted (RFC 8941 §4.1.6), with
/// only `"` and `\` escaped inside.
fn write_string(out : StringBuilder, text : String) -> Unit {
  out.write_string("\"")
  for c in text {
    if c == '"' || c == '\\' {
      out.write_string("\\")
    }
    out.write_char(c)
  }
  out.write_string("\"")
}

///|
fn write_integer(out : StringBuilder, name : String, value : Int64) -> Unit {
  out.write_string(";")
  out.write_string(name)
  out.write_string("=")
  out.write_string(value.to_string())
}

///|
/// A partition key is a Byte Sequence, written between colons as base64
/// (RFC 8941 §4.1.8).
fn write_key(out : StringBuilder, key : Bytes) -> Unit {
  out.write_string(";pk=:")
  out.write_string(@base64.encode(key))
  out.write_string(":")
}

///|
/// Parameters the specification leaves to the implementation, each already
/// written as Structured Fields text: the field is text, and a parameter's shape
/// is the caller's to choose.
fn write_extra(out : StringBuilder, extra : Array[String]) -> Unit {
  for parameter in extra {
    out.write_string(";")
    out.write_string(parameter)
  }
}

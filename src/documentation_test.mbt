// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The values the README and the skill tell a reader to expect, asserted here.
// The blocks in those files are compiled by `scripts/check_snippets.py`; the
// numbers under them are only prose until something runs them, and this is that
// something. A change to a default, a status, or a header that makes the
// documentation wrong turns one of these red.

///|
/// `TestClient` drives a handler in-process, and a text response is
/// `200 text/plain; charset=utf-8`.
test "a first handler answers 200 with the body it returned" {
  let greet : @moonasgi.Handler = fn(_request) {
    @moonasgi.Response::text("hello")
  }
  let client = @moonasgi.TestClient::new(greet)
  let response = client.get("/")
  assert_eq(response.status, 200)
  assert_eq(response.text(), "hello")
  assert_eq(response.header("content-type"), Some("text/plain; charset=utf-8"))
}

///|
/// `run_http` lowers one request to two events, and the conformance validator
/// finds nothing wrong with the pair.
test "one request lowers to a start and a body, in order" {
  let greet : @moonasgi.Handler = fn(_request) {
    @moonasgi.Response::text("hello")
  }
  let scope = @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(http_method="GET", path="/"),
  )
  let inbound = [@moonasgi.Event::HttpRequest(body=b"", more_body=false)]
  let events = @moonasgi.run_http(greet, scope, inbound)
  assert_eq(events.length(), 2)
  assert_eq(@moonasgi.validate_events(scope, events) is None, true)
}

///|
/// The three response constructors carry the content types the README names.
test "the response constructors set the content types the documentation shows" {
  let plain = @moonasgi.Response::text("hello")
  let created = @moonasgi.Response::json(status=201, Json({ "id": 233 }))
  let hand_built = @moonasgi.Response::new(204, [("x-trace", "1")], b"")
  assert_eq(plain.header("content-type"), Some("text/plain; charset=utf-8"))
  assert_eq(created.status, 201)
  assert_eq(created.header("content-type"), Some("application/json"))
  assert_eq(hand_built.status, 204)
  assert_eq(hand_built.header("x-trace"), Some("1"))
  assert_eq(hand_built.body.length(), 0)
}

///|
/// A streamed response reassembles into one body, with its trailers and its
/// early hints kept apart from it.
test "a streamed body, its trailers and its hints arrive as documented" {
  let feed : @moonasgi.StreamHandler = fn(_request) {
    @moonasgi.StreamingResponse::new(
      status=200,
      headers=[("content-type", "text/event-stream")],
      chunks=[b"data: 233\n\n", b"data: done\n\n"],
      trailers=[("x-digest", "9f2c")],
      early_hints=[["</style.css>; rel=preload"]],
    )
  }
  let client = @moonasgi.TestClient::from_stream(feed)
  let stream = client.get("/events")
  assert_eq(stream.status, 200)
  assert_eq(stream.body, b"data: 233\n\ndata: done\n\n")
  assert_eq(stream.trailer("x-digest"), Some("9f2c"))
  assert_eq(stream.early_hints.length(), 1)
}

///|
/// A WebSocket handler echoes, negotiates the subprotocol it was offered, and
/// the driver's output is a well-formed handshake, frames and close.
test "a websocket session accepts, echoes and validates" {
  let chat = @moonasgi.WebSocketHandler::new(
    on_connect=fn(_scope) {
      @ws.WsAccept::Accept(subprotocol=Some("chat.v1"), headers=[])
    },
    on_receive=fn(message) {
      match message {
        @ws.WsMessage::Text(text) => [@ws.WsSend::SendText("echo:" + text)]
        @ws.WsMessage::Binary(bytes) => [@ws.WsSend::SendBinary(bytes)]
      }
    },
  )
  let client = @moonasgi.TestClient::new(fn(_r) { @moonasgi.Response::text("") })
  let session = client.websocket(path="/chat", handler=chat, send=[
    @ws.WsMessage::Text("hi"),
  ])
  assert_eq(session.accepted, true)
  assert_eq(session.subprotocol, Some("chat.v1"))
  assert_eq(session.texts(), ["echo:hi"])

  let raw = @moonasgi.ws_run(
    chat,
    @moonasgi.Scope::WebSocket(@moonasgi.WebSocketScope::new(path="/chat")),
    [
      @moonasgi.Event::WebSocketConnect,
      @moonasgi.Event::WebSocketReceive(text=Some("hi"), bytes=None),
      @moonasgi.Event::WebSocketDisconnect(code=1000, reason=None),
    ],
  )
  assert_eq(@moonasgi.validate_ws_response(raw) is None, true)
}

///|
/// Startup seeds `state` in place and both phases answer complete, which is
/// what the README says a server copies onto every request scope.
test "lifespan startup seeds the state the documentation reads back" {
  let lifecycle = @moonasgi.LifespanHandler::new(
    on_startup=fn(scope) {
      scope.state["db_pool"] = Json::string("pool://main")
      Complete
    },
    on_shutdown=fn(_scope) { Complete },
  )
  let boot = @moonasgi.LifespanScope::new()
  let replies = @moonasgi.run_lifespan(
    lifecycle,
    @moonasgi.Scope::Lifespan(boot),
    [@moonasgi.Event::LifespanStartup, @moonasgi.Event::LifespanShutdown],
  )
  assert_eq(replies.length(), 2)
  assert_eq(boot.state.get("db_pool"), Some(Json::string("pool://main")))
}

///|
/// The extension flags start off, switch on one at a time, and an extension the
/// specification does not name is kept in the same map by name.
test "the extension flags are off until they are turned on" {
  let extensions = @moonasgi.Extensions::none()
    .enable_push()
    .enable_early_hint()
  assert_eq(extensions.http_response_push, true)
  assert_eq(extensions.http_response_early_hint, true)
  assert_eq(extensions.http_response_trailers, false)
  let custom = @moonasgi.Extensions::none().enable("http.fullflush")
  assert_eq(custom.get("http.fullflush") is Some(_), true)
  assert_eq(custom.get("http.nothing"), None)
}

///|
/// An HTTP/2 HEADERS block becomes a scope with the query split off `:path`, and
/// the harness the README quotes runs clean.
test "an h2 request line and the conformance harness behave as documented" {
  let parsed = @moonasgi.HttpScope::from_h2_headers([
    (":method", "POST"),
    (":scheme", "https"),
    (":authority", "example.test"),
    (":path", "/items?page=2"),
  ])
  match parsed {
    Ok(scope) => {
      assert_eq(scope.http_method, "POST")
      assert_eq(scope.path, "/items")
      assert_eq(scope.query_string, b"page=2")
    }
    Err(_) => abort("the pseudo-headers did not parse")
  }
  let report = @moonasgi.run_conformance()
  assert_eq(report.ok(), true)
  assert_eq(report.failures.length(), 0)
  assert_eq(report.passed, report.total)
}

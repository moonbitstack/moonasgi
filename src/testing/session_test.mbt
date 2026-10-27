///|
/// Accepts with the first offered subprotocol, echoes every message, records how the client
/// left, and closes with `4000` when told "bye".
fn echo_ws(left : Array[Int32]) -> @spec.AsgiApp {
  async fn(scope, receive, send) {
    guard scope is WebSocket(s) else { raise Boom }
    guard receive() is WebSocketConnect else { raise Boom }
    send(
      WebSocketAccept(subprotocol=s.subprotocols.get(0), headers=[
        ("x-hello", "1"),
      ]),
    )
    while true {
      match receive() {
        WebSocketReceive(text=Some("bye"), ..) => {
          send(WebSocketClose(code=4000, reason="bye"))
          break
        }
        WebSocketReceive(text=Some(t), ..) => send(WebSocketSendText(t))
        WebSocketReceive(bytes=Some(b), ..) => send(WebSocketSendBytes(b))
        WebSocketDisconnect(code~, ..) => {
          left.push(code)
          break
        }
        _ => raise Boom
      }
    }
  }
}

///|
async test "a WebSocket session echoes text, bytes and JSON" {
  let left = []
  let client = @testing.Client::new(echo_ws(left))
  client.websocket(path="/ws", subprotocols=["chat"], ws => {
    assert_eq(ws.subprotocol, Some("chat"))
    assert_eq(ws.headers, [("x-hello", "1")])
    ws.send_text("hi")
    assert_eq(ws.receive_text(), "hi")
    ws.send_bytes(b"\x01\x02")
    assert_eq(ws.receive_bytes(), b"\x01\x02")
    ws.send_json({ "n": 1 })
    assert_eq(ws.receive_json(), { "n": 1 })
    ws.close(status=1001)
  })
  assert_eq(left, [1001])
}

///|
async test "leaving the body closes with 1000" {
  let left = []
  @testing.Client::new(echo_ws(left)).websocket(path="/", ws => {
    assert_eq(ws.subprotocol, None)
  })
  assert_eq(left, [1000])
}

///|
async test "a server close surfaces as Closed" {
  @testing.Client::new(echo_ws([])).websocket(path="/", ws => {
    ws.send_text("bye")
    assert_true(
      error_of(() => ws.receive()) is @testing.Closed(status=4000, reason="bye"),
    )
  })
}

///|
async test "receive_text refuses a binary message" {
  @testing.Client::new(echo_ws([])).websocket(path="/", ws => {
    ws.send_bytes(b"z")
    assert_true(
      error_of(() => ws.receive_text())
      is @testing.Unexpected(WebSocketSendBytes(b"z")),
    )
  })
}

///|
async test "receive_bytes refuses a text message" {
  @testing.Client::new(echo_ws([])).websocket(path="/", ws => {
    ws.send_text("z")
    assert_true(
      error_of(() => ws.receive_bytes())
      is @testing.Unexpected(WebSocketSendText("z")),
    )
  })
}

///|
async test "a close before accept raises Closed" {
  let app : @spec.AsgiApp = async fn(_, receive, send) {
    ignore(receive())
    send(WebSocketClose(code=1008, reason="policy"))
  }
  assert_true(
    error_of(() => @testing.Client::new(app).websocket(path="/", _ => ()))
    is @testing.Closed(status=1008, reason="policy"),
  )
}

///|
async test "a denial response raises Denied with that response" {
  let app : @spec.AsgiApp = async fn(_, receive, send) {
    ignore(receive())
    send(
      WebSocketHttpResponseStart(
        status=403,
        headers=[("content-type", "text/plain")],
        trailers=false,
      ),
    )
    send(WebSocketHttpResponseBody(body=b"no", more_body=true))
    send(WebSocketHttpResponseBody(body=b"pe", more_body=false))
  }
  guard error_of(() => @testing.Client::new(app).websocket(path="/", _ => ()))
    is @testing.Denied(r) else {
    fail("expected Denied")
  }
  assert_eq(r.status, 403)
  assert_eq(r.header("content-type"), Some("text/plain"))
  assert_eq(r.text(), "nope")
}

///|
async test "a first reply outside the handshake raises Unexpected" {
  let app : @spec.AsgiApp = async fn(_, receive, send) {
    ignore(receive())
    send(WebSocketSendText("early"))
  }
  assert_true(
    error_of(() => @testing.Client::new(app).websocket(path="/", _ => ()))
    is @testing.Unexpected(WebSocketSendText("early")),
  )
}

///|
async test "the WebSocket scope carries path, query and subprotocols" {
  let seen = []
  let app : @spec.AsgiApp = async fn(scope, receive, send) {
    guard scope is WebSocket(s) else { raise Boom }
    seen.push((s.path, @utf8.decode_lossy(s.query_string), s.subprotocols))
    ignore(receive())
    send(WebSocketAccept(subprotocol=None, headers=[]))
    ignore(receive())
  }
  @testing.Client::new(app).websocket(
    path="/room?id=7",
    subprotocols=["a", "b"],
    _ => (),
  )
  assert_eq(seen, [("/room", "id=7", ["a", "b"])])
}

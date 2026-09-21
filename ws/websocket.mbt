///|
/// A message crossing a WebSocket in either direction: a UTF-8 `Text` frame or a
/// `Binary` frame. The ergonomic form of `WebSocketReceive` / `WebSocketSendText`
/// / `WebSocketSendBytes`, so a `WebSocketHandler` reasons over messages instead
/// of raw events.
pub(all) enum WsMessage {
  Text(String)
  Binary(Bytes)
} derive(Eq)

///|
/// The application's answer to a `WebSocketConnect`, mirroring the three replies
/// ASGI allows to an opening handshake: `Accept` it (optionally choosing a
/// `subprotocol` and adding response `headers`), `Reject` it with a bare close
/// code (ASGI closes the handshake with `websocket.close`), or `DenyHttp` it with
/// a full HTTP response (the `websocket.http.response` extension — a real status
/// + headers + body instead of a bare close).
pub(all) enum WsAccept {
  Accept(subprotocol~ : String?, headers~ : Array[(String, String)])
  Reject(code~ : Int, reason~ : String)
  DenyHttp(status~ : Int, headers~ : Array[(String, String)], body~ : Bytes)
} derive(Eq)

///|
/// An outbound action a `WebSocketHandler` takes while the connection is open:
/// send a `SendText` / `SendBinary` frame, or `Close` the connection with a code
/// and reason. A `Close` ends the handler's send stream — the driver stops
/// pulling further inbound messages, mirroring a server that has closed the
/// socket.
pub(all) enum WsSend {
  SendText(String)
  SendBinary(Bytes)
  Close(code~ : Int, reason~ : String)
} derive(Eq)

///|
/// A synchronous WebSocket application in the connect / receive / disconnect
/// shape, the WebSocket analog of the http `Handler`. `on_connect` decides the
/// handshake from the scope; `on_receive` maps each inbound `WsMessage` to the
/// frames to send back (it may `Close`); `on_disconnect` runs when the client
/// goes away, carrying the close `code` and the optional close `reason` (ASGI
/// 2.5). Driven in-process by `ws_run` and the
/// `TestClient`, so accept/subprotocol/echo/close logic is testable on every
/// backend without an async socket — the faithful synchronous core the async
/// server (`mooncat`) lifts onto `AsgiApp`.
pub(all) struct WebSocketHandler {
  on_connect : (@spec.WebSocketScope) -> WsAccept
  on_receive : (WsMessage) -> Array[WsSend]
  on_disconnect : (Int, String?) -> Array[WsSend]
}

///|
/// Build a `WebSocketHandler`. `on_connect` defaults to accepting the handshake
/// with no chosen subprotocol and no extra headers; `on_receive` and
/// `on_disconnect` default to doing nothing. Callers override only the phases
/// they care about.
pub fn WebSocketHandler::new(
  on_connect? : (@spec.WebSocketScope) -> WsAccept = fn(_s) {
    Accept(subprotocol=None, headers=[])
  },
  on_receive? : (WsMessage) -> Array[WsSend] = fn(_m) { [] },
  on_disconnect? : (Int, String?) -> Array[WsSend] = fn(_c, _r) { [] },
) -> WebSocketHandler {
  { on_connect, on_receive, on_disconnect, }
}

///|
/// An echo handler: accept the handshake (optionally negotiating `subprotocol`),
/// then send every received message straight back — text as text, binary as
/// binary. The canonical WebSocket smoke test.
pub fn WebSocketHandler::echo(subprotocol? : String) -> WebSocketHandler {
  WebSocketHandler::new(
    on_connect=fn(_s) { Accept(subprotocol~, headers=[]) },
    on_receive=fn(m) {
      match m {
        Text(t) => [SendText(t)]
        Binary(b) => [SendBinary(b)]
      }
    },
  )
}

///|
/// Lower one outbound `WsSend` to the wire `@spec.Event` a server would push.
fn ws_send_event(s : WsSend) -> @spec.Event {
  match s {
    SendText(t) => WebSocketSendText(t)
    SendBinary(b) => WebSocketSendBytes(b)
    Close(code~, reason~) => WebSocketClose(code~, reason~)
  }
}

///|
/// Read the ergonomic `WsMessage` out of a `WebSocketReceive`: a present `text`
/// wins over `bytes` (ASGI sends exactly one), a lone `bytes` is `Binary`, and a
/// message with neither is `None` (ignored by the driver).
fn ws_message_of(text : String?, bytes : Bytes?) -> WsMessage? {
  match text {
    Some(t) => Some(Text(t))
    None =>
      match bytes {
        Some(b) => Some(Binary(b))
        None => None
      }
  }
}

///|
/// Drive a `WebSocketHandler` over a materialised inbound event stream, folding
/// it into the outbound events a server would send. `WebSocketConnect` runs
/// `on_connect`: `Accept` emits a `WebSocketAccept` and opens the connection;
/// `Reject` emits a `WebSocketClose` and stops; `DenyHttp` emits the
/// `WebSocketHttpResponseStart` + `WebSocketHttpResponseBody` pair and stops.
/// While open, each `WebSocketReceive` runs `on_receive` and appends its sends —
/// a `Close` among them ends the stream. `WebSocketDisconnect` runs
/// `on_disconnect` and ends the stream. This is the synchronous WebSocket core
/// mirroring `run_http`; the `TestClient` and the async server share it.
fn drive_ws(
  handler : WebSocketHandler,
  scope : @spec.WebSocketScope,
  inbound : Array[@spec.Event],
) -> Array[@spec.Event] {
  let out : Array[@spec.Event] = []
  let mut accepted = false
  let mut closed = false
  for ev in inbound {
    if closed {
      break
    }
    match ev {
      WebSocketConnect =>
        match (handler.on_connect)(scope) {
          Accept(subprotocol~, headers~) => {
            out.push(WebSocketAccept(subprotocol~, headers~))
            accepted = true
          }
          Reject(code~, reason~) => {
            out.push(WebSocketClose(code~, reason~))
            closed = true
          }
          DenyHttp(status~, headers~, body~) => {
            out.push(
              WebSocketHttpResponseStart(status~, headers~, trailers=false),
            )
            out.push(WebSocketHttpResponseBody(body~, more_body=false))
            closed = true
          }
        }
      WebSocketReceive(text~, bytes~) =>
        if accepted {
          match ws_message_of(text, bytes) {
            Some(msg) =>
              for s in (handler.on_receive)(msg) {
                out.push(ws_send_event(s))
                if s is Close(..) {
                  closed = true
                  break
                }
              }
            None => ()
          }
        }
      WebSocketDisconnect(code~, reason~) => {
        for s in (handler.on_disconnect)(code, reason) {
          out.push(ws_send_event(s))
        }
        closed = true
      }
      _ => ()
    }
  }
  out
}

///|
/// Drive a `WebSocketHandler` over an inbound event sequence, returning the
/// outbound events a server would send. The WebSocket counterpart of `run_http`:
/// a `WebSocket` scope is driven through `drive_ws`; any other scope yields `[]`,
/// since this sugar covers websocket connections only.
pub fn ws_run(
  handler : WebSocketHandler,
  scope : @spec.Scope,
  inbound : Array[@spec.Event],
) -> Array[@spec.Event] {
  match scope {
    WebSocket(ws) => drive_ws(handler, ws, inbound)
    _ => []
  }
}

///|
/// The general sans-transport WebSocket core: hand the whole inbound event
/// stream and the `@spec.WebSocketScope` to `app` and return the outbound events it
/// emits. The escape hatch under `ws_run` for applications whose control flow is
/// not the connect/receive/disconnect fold — an app is free to inspect every
/// scope field (subprotocols, headers, extensions, state) and emit any sequence.
/// Non-websocket scopes yield `[]`. The WebSocket analog of `run_http_app`.
pub fn ws_run_app(
  app : (@spec.WebSocketScope, Array[@spec.Event]) -> Array[@spec.Event],
  scope : @spec.Scope,
  inbound : Array[@spec.Event],
) -> Array[@spec.Event] {
  match scope {
    WebSocket(ws) => app(ws, inbound)
    _ => []
  }
}

///|
pub extend WsAccept with Eq::{not_equal, equal}

///|
pub extend WsMessage with Eq::{not_equal, equal}

///|
pub extend WsSend with Eq::{not_equal, equal}

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
/// The WebSocket surface, driven in-process. A `WebSocketHandler` answers the
/// opening handshake three ways - `Accept` (negotiating a subprotocol with
/// `select_subprotocol`), `Reject` with a bare close, or `DenyHttp` with a full
/// HTTP response - then echoes frames as `WsSend`. `TestClient::websocket`
/// captures the exchange as a `WsTestSession`; `ws_run` and `ws_run_app` are the
/// raw cores under it.
///
///     moon run examples/07-websocket
#coverage.skip
fn main {
  let opt = fn(o : String?) -> String {
    match o {
      Some(v) => v
      None => "-"
    }
  }
  let opt_int = fn(o : Int?) -> String {
    match o {
      Some(v) => v.to_string()
      None => "-"
    }
  }
  let c = @moonasgi.TestClient::new(fn(_r) { @moonasgi.Response::text("") })

  // 1. Echo with subprotocol negotiation: pick the first offered value the
  //    server also supports.
  let echo = @moonasgi.WebSocketHandler::new(
    on_connect=fn(s) {
      @ws.Accept(subprotocol=s.select_subprotocol(["chat.v2", "chat.v1"]), headers=[
        ("x-ws", "ok"),
      ])
    },
    on_receive=fn(m) {
      match m {
        @ws.Text(t) => [@ws.SendText("echo:" + t)]
        @ws.Binary(b) => [@ws.SendBinary(b)]
      }
    },
  )
  let s = c.websocket(
    path="/ws",
    handler=echo,
    subprotocols=["chat.v1", "chat.v3"],
    send=[@ws.Text("emm"), @ws.Text("hhh")],
  )
  println(
    "echo: accepted=\{s.accepted} subprotocol=\{opt(s.subprotocol)} x-ws=\{opt(s.header("x-ws"))}",
  )
  println("echo texts: " + s.texts().join(", "))

  // 2. Reject the handshake with a bare close code.
  let reject = @moonasgi.WebSocketHandler::new(on_connect=fn(_s) {
    @ws.Reject(code=4403, reason="forbidden")
  })
  let sr = c.websocket(path="/ws", handler=reject, send=[@ws.Text("ignored")])
  println(
    "reject: accepted=\{sr.accepted} closed=\{sr.closed} code=\{opt_int(sr.close_code)}",
  )

  // 3. Deny the handshake with a full HTTP response (websocket.http.response).
  let deny = @moonasgi.WebSocketHandler::new(on_connect=fn(_s) {
    @ws.DenyHttp(status=401, headers=[("x-why", "auth")], body=b"denied")
  })
  let sd = c.websocket(path="/ws", handler=deny)
  match sd.denial {
    Some(resp) => println("deny: status=\{resp.status} body=" + resp.text())
    None => ()
  }

  // 4. The built-in echo handler over the raw ws_run core.
  let raw = @moonasgi.ws_run(
    @moonasgi.WebSocketHandler::echo(subprotocol=Some("chat.v1")),
    @moonasgi.Scope::WebSocket(
      @moonasgi.WebSocketScope::new(path="/ws", subprotocols=["chat.v1"]),
    ),
    [
      @spec.WebSocketConnect,
      @spec.WebSocketReceive(text=Some("qwq"), bytes=None),
      @spec.WebSocketDisconnect(code=1000, reason=None),
    ],
  )
  let ws_ok = @moonasgi.validate_ws_response(raw) is None
  println("ws_run -> \{raw.length()} outbound events, well-formed: \{ws_ok}")

  // 5. ws_run_app / websocket_app: the escape hatch sees the whole scope + stream.
  let counted = c.websocket_app(
    path="/ws",
    app=fn(scope, inbound) {
      [
        @spec.WebSocketAccept(subprotocol=scope.subprotocols.get(0), headers=[
          ("x-frames", inbound.length().to_string()),
        ]),
      ]
    },
    subprotocols=["v1"],
    send=[@ws.Text("a"), @ws.Text("b")],
    disconnect=None,
  )
  println(
    "websocket_app: subprotocol=\{opt(counted.subprotocol)} x-frames=\{opt(counted.header("x-frames"))}",
  )
}

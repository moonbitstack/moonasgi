// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// An async application tested in-process with `testing`, no socket:
///
///     moon run src/examples/15-testing --target native
///
/// Lifespan startup stores a greeting, an HTTP request reads it back from its scope, a
/// WebSocket echoes, `communicate` steps through one exchange event by event, and a failing
/// route shows its error reaching the test.
#coverage.skip
async fn main {
  tour() catch {
    e => println("failed: \{e}")
  }
}

///|
#coverage.skip
async fn tour() -> Unit {
  let app : @spec.AsgiApp = async fn(scope, receive, send) {
    match scope {
      Lifespan(s) =>
        while true {
          match receive() {
            LifespanStartup => {
              s.state["greeting"] = "hello"
              send(LifespanStartupComplete)
            }
            _ => {
              send(LifespanShutdownComplete)
              break
            }
          }
        }
      Http(h) if h.path == "/fail" => raise Failure::Failure("route /fail")
      Http(h) => {
        ignore(receive())
        let greeting = h.state.get("greeting").unwrap_or("none")
        send(HttpResponseStart(status=200, headers=[], trailers=false))
        send(
          HttpResponseBody(
            body=@utf8.encode(greeting.stringify()),
            more_body=false,
          ),
        )
      }
      WebSocket(_) => {
        ignore(receive())
        send(WebSocketAccept(subprotocol=None, headers=[]))
        while receive() is WebSocketReceive(text=Some(t), ..) {
          send(WebSocketSendText(t))
        }
      }
    }
  }
  let client = @testing.Client::new(app)
  client.lifespan(() => {
    let r = client.get("/")
    println("GET /: \{r.status} \{r.text()}")
    client.websocket(path="/echo", ws => {
      ws.send_text("ping")
      println("echo: \{ws.receive_text()}")
    })
  })
  @testing.communicate(
    app,
    Http(@spec.HttpScope::new(http_method="GET", path="/")),
    c => {
      c.send(HttpRequest(body=b"", more_body=false))
      while true {
        let event = c.receive() catch {
          @testing.Finished => break
          e => raise e
        }
        match event {
          HttpResponseStart(status~, ..) => println("event: start \{status}")
          HttpResponseBody(body~, ..) =>
            println("event: body \{body.length()} bytes")
          _ => ()
        }
      }
    },
  )
  (client.get("/fail") |> ignore) catch {
    e => println("GET /fail raised: \{e}")
  }
}

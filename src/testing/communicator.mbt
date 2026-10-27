///|
/// How long `receive` and `wait` wait by default, in milliseconds: one second.
pub let timeout : Int32 = 1000

///|
/// How long `receive_nothing` listens before it concludes nothing is coming, in milliseconds:
/// 100 ms.
pub let quiet : Int32 = 100

///|
/// What a test driver could not get from the application under test.
pub(all) suberror Refused {
  /// Nothing arrived within `limit` milliseconds.
  Timeout(limit~ : Int32)
  /// The application returned with nothing more to send.
  Finished
  /// The application sent an event the protocol does not allow at that point.
  Unexpected(@spec.Event)
  /// The application closed the WebSocket, before accepting it or after.
  Closed(status~ : Int32, reason~ : String)
  /// The application declined the WebSocket handshake with an HTTP response
  /// (`websocket.http.response`).
  Denied(@client.TestResponse)
  /// The application reported `lifespan.startup.failed` with this message.
  Startup(String)
  /// The application reported `lifespan.shutdown.failed` with this message.
  Shutdown(String)
} derive(Eq)

///|
pub extend Refused with Eq::{not_equal, equal}

///|
/// A running application under test: events go in with
/// `send`, come out with `receive`, and `wait` waits for the application to return. An error the
/// application raises comes out of the next `send`, `receive` or `wait`, after the events it sent
/// before failing. Made by `communicate`, which owns the application's task.
pub struct Communicator {
  priv inbound : @aqueue.Queue[@spec.Event]
  priv outbound : @deque.Deque[@spec.Event]
  priv arrived : @cond_var.Cond
  priv mut ended : Result[Unit, Error]?
  priv timeout : Int32
}

///|
/// Start `app` on `scope`, hand `body` a `Communicator` to talk to it, and return what `body`
/// returns. The application runs as a task of its own and is cancelled if it is still running
/// when `body` returns, since the test is done with it.
///
/// `timeout` is the default wait of `receive` and `wait`; each call can override it.
pub async fn[X] communicate(
  app : @spec.AsgiApp,
  scope : @spec.Scope,
  body : async (Communicator) -> X,
  timeout~ : Int32 = timeout,
) -> X {
  let c : Communicator = {
    inbound: @aqueue.Queue(kind=Unbounded),
    outbound: @deque.Deque([]),
    arrived: @cond_var.Cond(),
    ended: None,
    timeout,
  }
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, allow_failure=true, () => {
      try
        app(scope, () => c.inbound.get(), event => {
          c.outbound.push_back(event)
          c.arrived.broadcast()
        })
      catch {
        e => c.end(Err(e))
      } noraise {
        _ => c.end(Ok(()))
      }
    })
    body(c)
  })
}

///|
fn Communicator::end(
  self : Communicator,
  outcome : Result[Unit, Error],
) -> Unit {
  self.ended = Some(outcome)
  self.arrived.broadcast()
}

///|
/// Wait until there is output to take or the application has returned; `false` if `limit`
/// milliseconds pass first. Waiting on the condition rather than on a queue means a timeout
/// never takes an event with it.
async fn Communicator::ready(self : Communicator, limit : Int32) -> Bool {
  @async.with_timeout_opt(limit, () => {
    while self.outbound.is_empty() && self.ended is None {
      self.arrived.wait()
    }
  })
  is Some(_)
}

///|
/// Hand `event` to the application's `receive`. Raises the
/// application's error if it has already failed.
pub async fn Communicator::send(
  self : Communicator,
  event : @spec.Event,
) -> Unit {
  if self.ended is Some(Err(e)) {
    raise e
  }
  self.inbound.put(event)
}

///|
/// The next event the application sent. Raises `Timeout` if none
/// arrives within `timeout` milliseconds, `Finished` once the application has returned and
/// everything it sent has been taken, and the application's own error if it failed.
pub async fn Communicator::receive(
  self : Communicator,
  timeout? : Int32,
) -> @spec.Event {
  let limit = timeout.unwrap_or(self.timeout)
  guard self.ready(limit) else { raise Timeout(limit~) }
  match (self.outbound.pop_front(), self.ended) {
    (Some(event), _) => event
    (None, Some(Err(e))) => raise e
    (None, _) => raise Finished
  }
}

///|
/// Whether the application stays silent for `timeout` milliseconds. An event that does arrive
/// is left for the next `receive`. An application
/// that returned is silent; one that failed raises its error.
pub async fn Communicator::receive_nothing(
  self : Communicator,
  timeout? : Int32,
) -> Bool {
  if !self.ready(timeout.unwrap_or(quiet)) {
    return true
  }
  match (self.outbound.is_empty(), self.ended) {
    (false, _) => false
    (true, Some(Err(e))) => raise e
    (true, _) => true
  }
}

///|
/// Wait for the application to return. Raises `Timeout` if it is still running after `timeout`
/// milliseconds, and the application's error if it failed.
pub async fn Communicator::wait(self : Communicator, timeout? : Int32) -> Unit {
  let limit = timeout.unwrap_or(self.timeout)
  ignore(
    @async.with_timeout_opt(limit, () => {
      while self.ended is None {
        self.arrived.wait()
      }
    }),
  )
  match self.ended {
    Some(Ok(_)) => ()
    Some(Err(e)) => raise e
    None => raise Timeout(limit~)
  }
}

///|
/// Take events until the application returns, and return them.
async fn Communicator::drain(self : Communicator) -> Array[@spec.Event] {
  let events = []
  while true {
    let event = self.receive() catch {
      Finished => break
      e => raise e
    }
    events.push(event)
  }
  events
}

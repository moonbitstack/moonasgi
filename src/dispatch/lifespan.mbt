///|
/// Run the lifespan of every application in `apps` as one. Startup reaches them
/// in order and stops at the first that fails, which fails the whole startup with
/// its message; shutdown reaches them in reverse, so what started last stops
/// first, and the first failure is reported once every application has been told.
///
/// An application that returns or raises instead of answering does not take
/// part in the lifespan, as the spec has a server treat it; the others go on.
/// Every application sees the same lifespan state.
pub async fn lifespan(
  apps : Array[@spec.AsgiApp],
  scope : @spec.LifespanScope,
  receive : @spec.Receive,
  send : @spec.Send,
) -> Unit {
  @async.with_task_group(group => {
    let inboxes : Array[@aqueue.Queue[@spec.Event]] = []
    // `None` once the application has returned: it answers nothing more.
    let outboxes : Array[@aqueue.Queue[@spec.Event?]] = []
    for app in apps {
      let inbox : @aqueue.Queue[@spec.Event] = @aqueue.Queue(kind=Unbounded)
      let outbox : @aqueue.Queue[@spec.Event?] = @aqueue.Queue(kind=Unbounded)
      inboxes.push(inbox)
      outboxes.push(outbox)
      group.spawn_bg(no_wait=true, allow_failure=true, () => {
        app(Lifespan(scope), () => inbox.get(), event => outbox.put(Some(event))) catch {
          _ => ()
        }
        outbox.put(None)
      })
    }
    let taking = apps.map(_ => true)
    while true {
      match receive() {
        LifespanStartup => {
          for i in 0..<apps.length() {
            inboxes[i].put(LifespanStartup)
            match outboxes[i].get() {
              Some(LifespanStartupFailed(message~)) => {
                send(LifespanStartupFailed(message~))
                return
              }
              Some(_) => ()
              None => taking[i] = false
            }
          }
          send(LifespanStartupComplete)
        }
        LifespanShutdown => {
          let mut failed : String? = None
          for i = apps.length() - 1; i >= 0; i = i - 1 {
            guard taking[i] else { continue }
            inboxes[i].put(LifespanShutdown)
            if outboxes[i].get() is Some(LifespanShutdownFailed(message~)) &&
              failed is None {
              failed = Some(message)
            }
          }
          match failed {
            Some(message) => send(LifespanShutdownFailed(message~))
            None => send(LifespanShutdownComplete)
          }
          return
        }
        _ => return
      }
    }
  })
}

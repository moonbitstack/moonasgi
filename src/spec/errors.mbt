///|
/// A message sent on a connection that has already closed (HTTP and WebSocket
/// spec 2.4): the client went away, or the response or the WebSocket was
/// already finished. A server raises it from `send`. An application that keeps
/// sending after a disconnect catches it and stops; a server need not log it as
/// a failure. The text says which connection, for whoever reads the log.
pub(all) suberror Closed {
  Closed(String)
} derive(Eq, Debug)

///|
pub extend Closed with Eq::{equal, not_equal}

///|
pub extend Closed with Debug::{to_repr}

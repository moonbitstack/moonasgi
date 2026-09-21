// Subprotocol selection from a client's offered list (RFC 6455 §4.1).

///|
test "select_subprotocol: first client-offered the server supports, in client order; None when disjoint" {
  let scope = @spec.WebSocketScope::new(path="/ws", subprotocols=[
    "chat", "superchat", "json",
  ])
  // The client offers chat, superchat, json; the server supports superchat + json.
  // Client order wins: superchat is the first offered value the server supports.
  assert_eq(scope.select_subprotocol(["json", "superchat"]), Some("superchat"))
  // A single shared value is chosen.
  assert_eq(scope.select_subprotocol(["chat"]), Some("chat"))
  // No overlap: no subprotocol.
  assert_eq(scope.select_subprotocol(["binary"]), None)
  // No offers at all: no subprotocol.
  assert_eq(
    @spec.WebSocketScope::new(path="/ws").select_subprotocol(["chat"]),
    None,
  )
}

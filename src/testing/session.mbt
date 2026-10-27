///|
/// An accepted WebSocket under test: the
/// negotiated `subprotocol` and accept `headers`, plus methods that talk to the application.
pub struct Session {
  priv comm : Communicator
  subprotocol : String?
  headers : Array[(String, String)]
  priv mut closed : Bool
}

///|
/// Send `message` to the application as `websocket.receive`.
pub async fn Session::send(self : Session, message : @ws.WsMessage) -> Unit {
  self.comm.send(
    match message {
      Text(text) => WebSocketReceive(text=Some(text), bytes=None)
      Binary(bytes) => WebSocketReceive(text=None, bytes=Some(bytes))
    },
  )
}

///|
/// Send a text message.
pub async fn Session::send_text(self : Session, text : String) -> Unit {
  self.send(Text(text))
}

///|
/// Send a binary message.
pub async fn Session::send_bytes(self : Session, bytes : Bytes) -> Unit {
  self.send(Binary(bytes))
}

///|
/// Send `value` serialised as a text message.
pub async fn Session::send_json(self : Session, value : Json) -> Unit {
  self.send(Text(value.stringify()))
}

///|
/// The next message the application sent. Raises `Closed` when the application closes the
/// connection, and `Timeout`, `Finished` or the application's error as `Communicator::receive`.
pub async fn Session::receive(
  self : Session,
  timeout? : Int32,
) -> @ws.WsMessage {
  match self.comm.receive(timeout?) {
    WebSocketSendText(text) => Text(text)
    WebSocketSendBytes(bytes) => Binary(bytes)
    WebSocketClose(code~, reason~) => raise Closed(status=code, reason~)
    e => raise Unexpected(e)
  }
}

///|
/// The next message, which must be text.
pub async fn Session::receive_text(self : Session, timeout? : Int32) -> String {
  match self.receive(timeout?) {
    Text(text) => text
    Binary(bytes) => raise Unexpected(WebSocketSendBytes(bytes))
  }
}

///|
/// The next message, which must be binary.
pub async fn Session::receive_bytes(self : Session, timeout? : Int32) -> Bytes {
  match self.receive(timeout?) {
    Binary(bytes) => bytes
    Text(text) => raise Unexpected(WebSocketSendText(text))
  }
}

///|
/// The next message parsed as JSON; text or binary.
pub async fn Session::receive_json(self : Session, timeout? : Int32) -> Json {
  match self.receive(timeout?) {
    Text(text) => @json.parse(text)
    Binary(bytes) => @json.parse(@utf8.decode(bytes))
  }
}

///|
/// Tell the application the client went away with `status` (`websocket.disconnect`).
pub async fn Session::close(
  self : Session,
  status~ : Int32 = 1000,
  reason? : String,
) -> Unit {
  self.closed = true
  self.comm.send(WebSocketDisconnect(code=status, reason~))
}

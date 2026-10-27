// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// 门面：把六个子包的公开面原样重导出，`@moonasgi.X` 仍然是原来的 X。
// 只要其中一件的人直接 import 子包，产物里不会有其余五个。

///|
pub using @spec {
  type AsgiApp,
  type AsgiAppInstance,
  type AsgiApplication,
  type AsgiVersion,
  type Event,
  type Extensions,
  type Http2HeaderError,
  type HttpScope,
  type LegacyAsgiApp,
  type LifespanScope,
  type Receive,
  type Scope,
  type Send,
  type TlsExtension,
  type WebSocketScope,
  double_to_single_callable,
  guarantee_single_callable,
  headers_from_wire,
  headers_to_wire,
  latin1_decode,
  latin1_encode,
  percent_decode,
  run_legacy,
}

///|
pub using @http {
  type Drain,
  type Handler,
  type Middleware,
  type Request,
  type Response,
  type StreamHandler,
  type StreamingResponse,
  compose,
  run_http,
  run_http_app,
  run_http_scoped,
  run_http_scoped_drain,
  run_http_stream,
  to_asgi,
}

///|
pub using @ws {
  type WebSocketHandler,
  type WsAccept,
  type WsMessage,
  type WsSend,
  ws_run,
  ws_run_app,
}

///|
pub using @lifespan {type LifespanHandler, type LifespanReply, run_lifespan}

///|
pub using @client {
  type PushPromise,
  type TestClient,
  type TestResponse,
  type WsTestSession,
  type ZeroCopySend,
}

///|
pub using @conform {
  type ConformanceReport,
  type EventOrderError,
  run_conformance,
  validate_events,
  validate_http_response,
  validate_inbound,
  validate_lifespan_replies,
  validate_ws_response,
}

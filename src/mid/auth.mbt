// Who is behind the connection, resolved once per connection and left where
// every handler can read it.
//
// A server cannot know — it holds sockets. A framework knows how, but it comes
// later in the stack than the middleware it wants to reuse. The backend is the
// seam between the two: one function from a connection to an identity, and the
// layer that puts the answer on the scope.

///|
/// What a backend found for one connection: the `user` it identified, and the
/// `auth` record the decision was made from (a token's claims, a role list, a
/// tenant). Both are `None` when the connection carried nothing to go on.
///
/// JSON rather than a record because the seam cannot know what a service's user
/// looks like; a framework that wants a typed user reads it back out of the
/// scope with `user` and decodes it into its own type.
pub(all) struct Identity {
  user : Json?
  auth : Json?
} derive(Eq, Debug)

///|
/// An identity with nothing in it: the answer for a connection that carried no
/// credentials.
pub fn Identity::anonymous() -> Identity {
  { user: None, auth: None, }
}

///|
/// An identity for `user`, with no record of how it was reached.
pub fn Identity::of(user : Json) -> Identity {
  { user: Some(user), auth: None, }
}

///|
/// A backend answers one question: who is behind this connection? It sees the
/// whole scope, so it can read the session, a bearer token, a client certificate
/// or the peer address, in whatever order the service prefers.
pub(open) trait Backend {
  fn authenticate(Self, @spec.Scope) -> Identity
}

///|
/// A backend written as a plain function, for a service whose rule fits on a line
/// or two: `BackendFn(fn(scope) { ... })` is a `Backend` with no type to declare.
pub(all) struct BackendFn((@spec.Scope) -> Identity)

///|
pub impl Backend for BackendFn with fn authenticate(self, scope) {
  let BackendFn(f) = self
  f(scope)
}

///|
/// Resolve the identity of every connection and put it on the scope, under `user`
/// and `auth`, before the application runs. A connection the backend could not
/// identify carries `null` there rather than nothing at all, so a handler can tell
/// "this service identified nobody" from "this service has no auth layer".
///
/// The layer sees the scope the layers outside it built, so a session written by
/// `Sessions` is readable here when `Sessions` wraps `Auth`.
pub(all) struct Auth {
  backend : &Backend
}

///|
/// Build an `Auth` layer around `backend`.
pub fn Auth::new(backend : &Backend) -> Auth {
  { backend, }
}

///|
/// The identity the layer resolved for this connection, or `None` when nobody was
/// identified — or when no `Auth` layer ran.
pub fn user(scope : @spec.Scope) -> Json? {
  match state_of(scope).get("user") {
    Some(Null) => None
    other => other
  }
}

///|
/// The record the identity was decided from, when the backend kept one.
pub fn auth(scope : @spec.Scope) -> Json? {
  match state_of(scope).get("auth") {
    Some(Null) => None
    other => other
  }
}

///|
pub impl Layer for Auth with fn wrap(self, app) {
  (scope, receive, send) => {
    let state = state_of(scope)
    let identity = self.backend.authenticate(scope)
    state["user"] = identity.user.unwrap_or(Json::null())
    state["auth"] = identity.auth.unwrap_or(Json::null())
    app(scope, receive, send)
  }
}

///|
pub extend BackendFn with Backend::{authenticate}

///|
pub extend Identity with Eq::{equal, not_equal}

///|
pub extend Identity with Debug::{to_repr}

///|
pub extend Auth with Layer::{wrap}

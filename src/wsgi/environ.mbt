///|
/// What a synchronous application is told about a request (← WSGI's `environ`,
/// PEP 3333): the CGI variables as fields, the request headers, the body read in
/// full, and the URL scheme. `to_map` gives the same under the CGI names, for
/// code that reads them by key.
pub(all) struct Environ {
  request_method : String
  // Where the application is mounted: the ASGI `root_path`.
  script_name : String
  // The path below `script_name`.
  path_info : String
  query_string : String
  content_type : String
  content_length : String
  server_name : String
  server_port : String
  server_protocol : String
  remote_addr : String
  remote_port : String
  headers : Array[(String, String)]
  url_scheme : String
  input : Bytes
} derive(Eq, Debug)

///|
pub extend Environ with Eq::{equal, not_equal}

///|
pub extend Environ with Debug::{to_repr}

///|
/// The environment for `scope` and its `body`. The server's name and port come
/// from the scope, else from the `Host` header, else from the scheme's default;
/// the protocol is `HTTP/` and the scope's version.
pub fn Environ::of(scope : @spec.HttpScope, body : Bytes) -> Environ {
  let header = (name : String) => {
    scope.headers.iter().find_first(h => h.0.to_lower() == name).map(h => h.1)
  }
  let default_port = if scope.scheme == "https" { "443" } else { "80" }
  let (server_name, server_port) = match scope.server {
    Some((name, Some(port))) => (name, port.to_string())
    Some((name, None)) => (name, default_port)
    None =>
      match header("host") {
        Some(host) =>
          match host.rev_find(":") {
            Some(k) if !host.has_suffix("]") =>
              (
                host.view(end_offset=k).to_owned(),
                host.view(start_offset=k + 1).to_owned(),
              )
            _ => (host, default_port)
          }
        None => ("localhost", default_port)
      }
  }
  let (remote_addr, remote_port) = match scope.client {
    Some((host, port)) => (host, port.to_string())
    None => ("", "")
  }
  {
    request_method: scope.http_method,
    script_name: scope.root_path,
    path_info: scope.path,
    query_string: @spec.latin1_decode(scope.query_string),
    content_type: header("content-type").unwrap_or(""),
    content_length: header("content-length").unwrap_or(
      if body.is_empty() {
        ""
      } else {
        body.length().to_string()
      },
    ),
    server_name,
    server_port,
    server_protocol: "HTTP/" + scope.http_version,
    remote_addr,
    remote_port,
    headers: scope.headers,
    url_scheme: scope.scheme,
    input: body,
  }
}

///|
/// The first request header named `name`, matched without regard to case.
pub fn Environ::header(self : Environ, name : String) -> String? {
  let name = name.to_lower()
  self.headers.iter().find_first(h => h.0.to_lower() == name).map(h => h.1)
}

///|
/// The environment under its CGI names: `REQUEST_METHOD`, `SCRIPT_NAME`,
/// `PATH_INFO` and the rest, each request header as `HTTP_` and its name in
/// upper case with `-` as `_` (repeated headers joined with `,`, except that
/// `Content-Type` and `Content-Length` keep their own names), and
/// `wsgi.url_scheme`. The body is not in it.
pub fn Environ::to_map(self : Environ) -> Map[String, String] {
  let out : Map[String, String] = {
    "REQUEST_METHOD": self.request_method,
    "SCRIPT_NAME": self.script_name,
    "PATH_INFO": self.path_info,
    "QUERY_STRING": self.query_string,
    "SERVER_NAME": self.server_name,
    "SERVER_PORT": self.server_port,
    "SERVER_PROTOCOL": self.server_protocol,
    "wsgi.url_scheme": self.url_scheme,
  }
  if self.content_type != "" {
    out["CONTENT_TYPE"] = self.content_type
  }
  if self.content_length != "" {
    out["CONTENT_LENGTH"] = self.content_length
  }
  if self.remote_addr != "" {
    out["REMOTE_ADDR"] = self.remote_addr
    out["REMOTE_PORT"] = self.remote_port
  }
  for h in self.headers {
    let name = h.0.to_lower()
    if name == "content-type" || name == "content-length" {
      continue
    }
    let key = "HTTP_" + name.to_upper().replace_all(old="-", new="_")
    out[key] = match out.get(key) {
      Some(before) => before + "," + h.1
      None => h.1
    }
  }
  out
}

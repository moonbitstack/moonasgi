///|
/// A synchronous application on an ASGI server:
///
///     moon run src/examples/17-wsgi --target native
///
/// The application is a plain function from the request environment and a
/// `start_response` to the body. It cannot wait for anything, and it does not
/// need to: `to_asgi` reads the request body first, calls it, and sends each
/// chunk it yields as soon as it yields it. Mounted under `/legacy`, it sees its
/// mount point as `SCRIPT_NAME` and the rest of the path as `PATH_INFO`.
#coverage.skip
async fn main {
  tour() catch {
    e => println("failed: \{e}")
  }
}

///|
/// Answers `/hello` with a greeting built in three pieces, `/echo` with the
/// request body, `/env` with the CGI variables it was given, and anything else
/// with a 404.
#coverage.skip
fn legacy() -> @wsgi.WsgiApp {
  (environ, start) => {
    match environ.path_info {
      "/hello" => {
        ignore(start("200 OK", [("Content-Type", "text/plain")]))
        [b"hello", b", ", b"world"].iter()
      }
      "/echo" => {
        // The older style: write the body through what start_response returns.
        let write = start("200 OK", [
          ("Content-Type", "application/octet-stream"),
        ])
        write(environ.input)
        [].iter()
      }
      "/env" => {
        ignore(start("200 OK", [("Content-Type", "text/plain")]))
        let cgi = environ.to_map()
        let lines = [
          "SCRIPT_NAME=" + cgi["SCRIPT_NAME"],
          "PATH_INFO=" + cgi["PATH_INFO"],
          "QUERY_STRING=" + cgi["QUERY_STRING"],
          "HTTP_USER_AGENT=" + cgi.get("HTTP_USER_AGENT").unwrap_or(""),
        ]
        [@utf8.encode(lines.join("\n"))].iter()
      }
      _ => {
        ignore(start("404 Not Found", []))
        [b"no such page"].iter()
      }
    }
  }
}

///|
#coverage.skip
async fn tour() -> Unit {
  let app = @dispatch.mount([("/legacy", @wsgi.to_asgi(legacy()))])
  let client = @testing.Client::new(app)
  let hello = client.get("/legacy/hello")
  println("GET /legacy/hello -> \{hello.status} \{hello.text()}")
  let echo = client.post("/legacy/echo", body=b"sent and returned")
  println("POST /legacy/echo -> \{echo.status} \{echo.text()}")
  let env = client.get("/legacy/env?page=2", headers=[("user-agent", "moonbit")])
  println("GET /legacy/env?page=2 ->\n" + env.text())
  let missing = client.get("/legacy/nope")
  println("GET /legacy/nope -> \{missing.status} \{missing.text()}")
}

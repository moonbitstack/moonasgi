"""Compare this library's WSGI adapter with asgiref's, and write the vectors its tests replay.

    python scripts/gen_wsgi_vectors.py

asgiref 3.13.0 is a different implementation of the same seam: PEP 3333's
environment built from an ASGI scope, an application's status line, headers and
body turned back into ASGI messages. For each request below the script runs the
same application through both, and records what asgiref produced. The generated
file is replayed by `moon test`; nothing here runs in CI, the vectors do.

A case is a request (method, path, mount, query, headers, body, scheme, peers,
HTTP version) and one of four applications:

    0  echo    a status of its own, a header it read from the environment, four
               pieces of body, one of them empty
    1  write   two pieces written before the iterator is asked for anything
    2  read    the request body as the response body
    3  bytes   a body with every byte value in it

What is recorded per case: the environment asgiref built, and the status,
headers and body it sent. The four adapters' own metadata — `wsgi.version`,
`wsgi.input`, `wsgi.errors` and the three concurrency flags — is not recorded:
this library's `Environ` is a record that carries the input as bytes, so those
keys have no place in `to_map`, which is the CGI surface both sides share.
"""

import asyncio
import io
import json
import pathlib
import shutil
import subprocess
import sys

from asgiref.wsgi import WsgiToAsgi, WsgiToAsgiInstance

CLIENT = ("10.1.2.3", 5000)
SERVER = ("testserver", 80)

# name, method, path, root_path, query, headers, body, scheme, version, client,
# server, app
CASES = [
    (
        "get-root",
        "GET",
        "/",
        "",
        "",
        [(b"host", b"example.com")],
        b"",
        "http",
        "1.1",
        CLIENT,
        SERVER,
        0,
    ),
    (
        "get-query",
        "GET",
        "/items",
        "",
        "page=2&tag=a%20b",
        [(b"host", b"example.com"), (b"accept", b"text/plain")],
        b"",
        "http",
        "1.1",
        CLIENT,
        SERVER,
        0,
    ),
    (
        "post-form",
        "POST",
        "/form",
        "",
        "",
        [
            (b"host", b"example.com"),
            (b"content-type", b"application/x-www-form-urlencoded"),
            (b"content-length", b"14"),
            (b"x-tag", b"a"),
            (b"x-tag", b"b"),
        ],
        b"name=moon&n=1",
        "http",
        "1.1",
        CLIENT,
        SERVER,
        2,
    ),
    (
        "mounted",
        "POST",
        "/items",
        "/legacy",
        "page=2",
        [
            (b"host", b"example.com"),
            (b"content-type", b"text/plain"),
            (b"content-length", b"9"),
        ],
        b"name=moon",
        "http",
        "1.1",
        CLIENT,
        SERVER,
        0,
    ),
    (
        "https",
        "GET",
        "/secure",
        "",
        "",
        [(b"host", b"api.test")],
        b"",
        "https",
        "1.1",
        CLIENT,
        ("api.test", 443),
        0,
    ),
    (
        "latin1-header",
        "GET",
        "/note",
        "",
        "",
        [(b"host", b"example.com"), (b"x-note", "café".encode("latin-1"))],
        b"",
        "http",
        "1.1",
        CLIENT,
        SERVER,
        0,
    ),
    (
        "no-length",
        "GET",
        "/empty",
        "",
        "",
        [(b"host", b"example.com")],
        b"",
        "http",
        "1.1",
        CLIENT,
        SERVER,
        0,
    ),
    (
        "http2",
        "GET",
        "/",
        "",
        "",
        [(b"host", b"example.com")],
        b"",
        "https",
        "2",
        CLIENT,
        ("testserver", 443),
        0,
    ),
    (
        "bytes",
        "GET",
        "/bytes",
        "",
        "",
        [(b"host", b"example.com")],
        b"",
        "http",
        "1.1",
        CLIENT,
        SERVER,
        3,
    ),
]


def echo(environ, start_response):
    start_response(
        "201 Created",
        [("Content-Type", "text/plain"), ("X-Method", environ["REQUEST_METHOD"])],
    )
    return [b"hello", b"", b", ", b"world"]


def writer(environ, start_response):
    write = start_response("200 OK", [("Content-Type", "text/plain")])
    write(b"a")
    write(b"b")
    return [b"c"]


def reader(environ, start_response):
    start_response("200 OK", [("Content-Type", "application/octet-stream")])
    return [environ["wsgi.input"].read()]


def binary(environ, start_response):
    start_response("200 OK", [("Content-Type", "application/octet-stream")])
    return [bytes(range(16)) + bytes(range(16))]


# asgiref's `start_response` returns no write callable, so nothing here uses the
# writer: a PEP 3333 application that writes before it yields has no counterpart
# on that side to be compared with, and `wsgi_test.mbt` covers it on its own.
APPS = [echo, writer, reader, binary]


def scope_of(case):
    _, method, path, root, query, headers, _, scheme, version, client, server, _ = case
    return {
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.5"},
        "http_version": version,
        "method": method,
        "scheme": scheme,
        "path": path,
        "raw_path": path.encode(),
        "root_path": root,
        "query_string": query.encode("latin-1"),
        "headers": list(headers),
        "client": client,
        "server": server,
    }


def environ_of(case):
    """What asgiref builds for the request, minus the adapter's own metadata."""
    instance = WsgiToAsgiInstance(lambda environ, start: [])
    instance.scope = scope_of(case)
    environ = instance.build_environ(instance.scope, io.BytesIO(case[6]))
    skip = {
        "wsgi.version",
        "wsgi.input",
        "wsgi.errors",
        "wsgi.multithread",
        "wsgi.multiprocess",
        "wsgi.run_once",
    }
    return [(key, value) for key, value in environ.items() if key not in skip]


def reply_of(case):
    """The status, headers and body asgiref's adapter sends for the request."""
    messages = []
    body = case[6]

    async def receive():
        return {"type": "http.request", "body": body, "more_body": False}

    async def send(message):
        messages.append(message)

    asyncio.run(WsgiToAsgi(APPS[case[11]])(scope_of(case), receive, send))
    status = None
    headers = []
    sent = b""
    for message in messages:
        if message["type"] == "http.response.start":
            status = message["status"]
            headers = [
                (name.decode("latin-1"), value.decode("latin-1"))
                for name, value in message["headers"]
            ]
        elif message["type"] == "http.response.body":
            sent += message.get("body", b"")
    return status, headers, sent


def mbt_string(text):
    """A MoonBit string literal; anything outside ASCII as an escape, so the file is ASCII."""
    out = ['"']
    for char in text:
        code = ord(char)
        if char == '"':
            out.append('\\"')
        elif char == "\\":
            out.append("\\\\")
        elif char == "\n":
            out.append("\\n")
        elif 0x20 <= code < 0x7F:
            out.append(char)
        else:
            out.append("\\u{%x}" % code)
    out.append('"')
    return "".join(out)


def mbt_bytes(data):
    out = ['b"']
    for byte in data:
        if byte == 0x22:
            out.append('\\"')
        elif byte == 0x5C:
            out.append("\\\\")
        elif 0x20 <= byte < 0x7F:
            out.append(chr(byte))
        else:
            out.append("\\x%02x" % byte)
    out.append('"')
    return "".join(out)


def mbt_pair_list(pairs):
    return "[" + ", ".join("(%s, %s)" % (mbt_string(k), mbt_string(v)) for k, v in pairs) + "]"


def mbt_peer(peer):
    if peer is None:
        return "None"
    host, port = peer
    return 'Some((%s, %d))' % (mbt_string(host), port)


def mbt_server(server):
    if server is None:
        return "None"
    host, port = server
    if port is None:
        return 'Some((%s, None))' % mbt_string(host)
    return 'Some((%s, Some(%d)))' % (mbt_string(host), port)


HEADER = '''// Generated by scripts/gen_wsgi_vectors.py from asgiref %s. Do not edit by hand.
//
// Each vector is one request and the same application run through asgiref's
// `WsgiToAsgi`: the environment it built, and the status, headers and body it
// sent. `asgiref_test.mbt` replays them through this library's adapter.

///|
struct AsgirefVector {
  name : String
  http_method : String
  path : String
  root_path : String
  query : String
  headers : Array[(String, String)]
  body : Bytes
  scheme : String
  version : String
  client : (String, Int32)?
  server : (String, Int32?)?
  app : Int32
  environ : Array[(String, String)]
  status : Int32
  response_headers : Array[(String, String)]
  response_body : Bytes
}

///|
fn asgiref_vectors() -> Array[AsgirefVector] {
  [
'''


def main():
    import asgiref

    body = [HEADER % asgiref.__version__]
    for case in CASES:
        (
            name,
            method,
            path,
            script_name,
            query,
            headers,
            request_body,
            scheme,
            version,
            client,
            server,
            app,
        ) = case
        environ = environ_of(case)
        status, response_headers, response_body = reply_of(case)
        decoded = [
            (name.decode("latin-1"), value.decode("latin-1")) for name, value in headers
        ]
        body.append("    {")
        body.append("      name: %s," % mbt_string(name))
        body.append("      http_method: %s," % mbt_string(method))
        body.append("      path: %s," % mbt_string(path))
        body.append("      root_path: %s," % mbt_string(script_name))
        body.append("      query: %s," % mbt_string(query))
        body.append("      headers: %s," % mbt_pair_list(decoded))
        body.append("      body: %s," % mbt_bytes(request_body))
        body.append("      scheme: %s," % mbt_string(scheme))
        body.append("      version: %s," % mbt_string(version))
        body.append("      client: %s," % mbt_peer(client))
        body.append("      server: %s," % mbt_server(server))
        body.append("      app: %d," % app)
        body.append("      environ: %s," % mbt_pair_list(environ))
        body.append("      status: %d," % status)
        body.append("      response_headers: %s," % mbt_pair_list(response_headers))
        body.append("      response_body: %s," % mbt_bytes(response_body))
        body.append("    },")
    body.append("  ]")
    body.append("}")

    root = pathlib.Path(__file__).resolve().parent.parent
    target = root / "src/wsgi/asgiref_vectors_test.mbt"
    target.write_text("\n".join(body) + "\n", encoding="utf-8", newline="\n")
    print("wrote %s" % target.relative_to(root))
    moon = shutil.which("moon") or shutil.which("moon.exe")
    if moon is None:
        print("moon is not on PATH: run `moon fmt src/wsgi` before committing")
        return
    subprocess.run([moon, "fmt", "src/wsgi"], cwd=root, check=True)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--json":
        for case in CASES:
            print(json.dumps({"name": case[0], "environ": environ_of(case)}))
    else:
        main()

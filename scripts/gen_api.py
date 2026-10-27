"""Write docs/api.html — and the site's search index — from each package's
generated interface and the `///` comments in its sources, so the reference
cannot drift from the code.

    python scripts/gen_api.py
"""
import html
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"

# (package, folder, blurb) in reading order: the contract, the cores built on it,
# the drivers, then the applications-level packages.
PACKAGES = [
    ("moonbitstack/moonasgi/spec", "src/spec",
     "The contract itself: the three scopes, the event set, the extensions, and the "
     "legacy 2.0 wrappers. Everything below is built on these types."),
    ("moonbitstack/moonasgi/http", "src/http",
     "The request and response a handler works in, and the synchronous cores that lower "
     "them onto events — a whole request without a socket."),
    ("moonbitstack/moonasgi/ws", "src/ws",
     "The WebSocket core: a connect / receive / disconnect handler, driven in-process by "
     "`ws_run`."),
    ("moonbitstack/moonasgi/lifespan", "src/lifespan",
     "The lifespan core: a startup and a shutdown hook, driven in-process by "
     "`run_lifespan`."),
    ("moonbitstack/moonasgi/client", "src/client",
     "`TestClient`: drive a handler or a WebSocket session in-process and read back the "
     "reassembled answer."),
    ("moonbitstack/moonasgi/mid", "src/mid",
     "Application-level middleware, each one a record implementing `Layer`, stackable in "
     "any order."),
    ("moonbitstack/moonasgi/dispatch", "src/dispatch",
     "Several applications behind one: by path prefix, by host name, over one shared "
     "lifespan."),
    ("moonbitstack/moonasgi/wsgi", "src/wsgi",
     "A synchronous application, run on the same events as everything else."),
    ("moonbitstack/moonasgi/testing", "src/testing",
     "Drive a real `AsgiApp` in-process: requests, WebSocket sessions, the lifespan, and "
     "the events one at a time."),
    ("moonbitstack/moonasgi/conform", "src/conform",
     "Check the seam wiring: a conformance harness, and the message-ordering rules as "
     "code."),
]

DECL = re.compile(
    r"^pub(?:\((?:all|open)\))?\s+"
    r"(fn(?:\[[^\]]*\])?|let|struct|enum|suberror|trait|type)\s+"
    r"([A-Za-z_][\w]*(?:::[A-Za-z_][\w]*)?)"
)
DERIVED = re.compile(
    r"::(equal|not_equal|to_repr|to_string|hash|hash_combine|compare|op_\w+|default)\("
)
BLOCK = ("struct", "enum", "suberror", "trait")


# ---------- sources: the doc comments ----------

def docs_of(folder):
    """Doc paragraphs by declared name, and by `Type.field` for fields and variants."""
    out = {}
    for path in sorted((ROOT / folder).glob("*.mbt")):
        if path.name.endswith("_test.mbt") or path.name.endswith("_wbtest.mbt"):
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        pending, owner = [], None
        for line in lines:
            stripped = line.strip()
            if stripped == "///|":
                pending = []
                continue
            if stripped.startswith("///"):
                pending.append(stripped[3:].strip())
                continue
            m = DECL.match(line)
            if m:
                name = m.group(2)
                if pending:
                    out[name] = pending
                owner = name if m.group(1) in BLOCK and line.rstrip().endswith("{") else None
                pending = []
                continue
            if owner and line.startswith("}"):
                owner = None
            elif owner and pending:
                field = re.match(r"\s+(?:fn\s+)?(?:mut\s+)?([A-Za-z_]\w*)", line)
                if field:
                    out[owner + "." + field.group(1)] = pending
            pending = []
    return out


# ---------- interfaces: the declarations ----------

def items_of(folder):
    """(kind, name, text, owner) from the generated interface file."""
    text = (ROOT / folder / "pkg.generated.mbti").read_text(encoding="utf-8").splitlines()
    items, block = [], None
    for line in text:
        if block is not None:
            block[2].append(line)
            if line.startswith("}"):
                items.append((block[0], block[1], "\n".join(block[2]), None))
                block = None
            continue
        if not line.startswith("pub"):
            continue
        m = re.match(r"pub(?:\((?:all|open)\))?\s+(struct|enum|suberror|trait)\s+(\w+)", line)
        if m and line.rstrip().endswith("{"):
            block = [m.group(1), m.group(2), [line]]
            continue
        if m:
            items.append((m.group(1), m.group(2), line, None))
            continue
        m = re.match(r"pub fn(?:\[[^\]]*\])?\s+(\w+)::(\w+)", line)
        if m:
            items.append(("method", m.group(1) + "::" + m.group(2), line, m.group(1)))
            continue
        m = re.match(r"pub (?:async )?fn(?:\[[^\]]*\])?\s+(\w+)", line)
        if m:
            items.append(("fn", m.group(1), line, None))
            continue
        m = re.match(r"pub let (\w+)", line)
        if m:
            items.append(("let", m.group(1), line, None))
            continue
        m = re.match(r"pub type (\w+)", line)
        if m:
            items.append(("type", m.group(1), line, None))
            continue
        m = re.match(r"pub impl[^(]* for (\w+)", line)
        if m:
            items.append(("impl", m.group(1), line, None))
    return items


# ---------- rendering ----------

def prose(lines):
    if not lines:
        return ""
    text = " ".join(lines) if isinstance(lines, list) else lines
    chunks, buf = [], []
    for line in (lines if isinstance(lines, list) else [lines]):
        if line.strip() == "":
            if buf:
                chunks.append(" ".join(buf))
                buf = []
        else:
            buf.append(line.strip())
    if buf:
        chunks.append(" ".join(buf))
    out = []
    for chunk in chunks:
        escaped = html.escape(chunk)
        escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
        escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
        out.append("<p>%s</p>" % escaped)
    return "".join(out)


def short(pkg):
    return pkg.split("/", 1)[1]


def anchor(pkg, name):
    return (short(pkg).replace("/", "-") + "-" + name).replace("::", "-").lower()


def sig(text):
    return '<pre class="sig mono">%s</pre>' % html.escape(text.rstrip())


def render_package(pkg, folder, blurb):
    docs = docs_of(folder)
    items = items_of(folder)
    nav, body = [], []
    nav.append('<div class="side-group"><span class="side-label">%s</span>' % html.escape(short(pkg).split("/")[-1]))
    body.append(
        '<section class="pkg" id="%s"><div class="pkg-head">'
        '<h2>%s</h2><span class="count">%d items</span></div>%s'
        % (anchor(pkg, "top"), html.escape(short(pkg)), len(items), prose(blurb))
    )

    types = [i for i in items if i[0] in BLOCK or i[0] == "type"]
    methods = {}
    impls = {}
    for kind, name, text, owner in items:
        if kind == "method":
            if DERIVED.search(text):
                continue
            methods.setdefault(owner, []).append((name, text))
        elif kind == "impl":
            impls.setdefault(name, []).append(text.strip())
    values = [i for i in items if i[0] == "let"]
    fns = [i for i in items if i[0] == "fn"]

    jumps = []
    for kind, name, text, _ in types:
        jumps.append('<a href="#%s">%s</a>' % (anchor(pkg, name), html.escape(name)))
    if fns:
        jumps.append('<a href="#%s">functions</a>' % anchor(pkg, "functions"))
    if values:
        jumps.append('<a href="#%s">values</a>' % anchor(pkg, "values"))
    if jumps:
        body.append('<div class="jump">%s</div>' % "".join(jumps))

    for kind, name, text, _ in types:
        nav.append('<a class="side-link" href="#%s">%s</a>' % (anchor(pkg, name), html.escape(name)))
        body.append('<article class="item">')
        body.append('<h3 id="%s"><span class="kind k-%s">%s</span>%s</h3>' % (
            anchor(pkg, name), kind, kind, html.escape(name)))
        body.append(prose(docs.get(name)))
        body.append(sig(text))
        fields = [(k.split(".", 1)[1], v) for k, v in docs.items() if k.startswith(name + ".")]
        if fields:
            body.append('<dl class="fields">%s</dl>' % "".join(
                "<dt>%s</dt><dd>%s</dd>" % (html.escape(f), " ".join(d))
                for f, d in fields))
        if name in impls:
            body.append('<p class="doc">%s</p>' % html.escape(" · ".join(impls[name])))
        for mname, mtext in methods.get(name, []):
            body.append('<div class="member" id="%s">%s%s</div>' % (
                anchor(pkg, mname), sig(mtext), prose(docs.get(mname))))
        body.append("</article>")

    if fns:
        nav.append('<a class="side-link" href="#%s">functions</a>' % anchor(pkg, "functions"))
        body.append('<h3 id="%s">Functions</h3>' % anchor(pkg, "functions"))
        for kind, name, text, _ in sorted(fns, key=lambda i: i[1]):
            body.append('<div class="item member" id="%s">%s%s</div>' % (
                anchor(pkg, name), sig(text), prose(docs.get(name))))

    if values:
        nav.append('<a class="side-link" href="#%s">values</a>' % anchor(pkg, "values"))
        body.append('<h3 id="%s">Values</h3>' % anchor(pkg, "values"))
        for kind, name, text, _ in sorted(values, key=lambda i: i[1]):
            body.append('<div class="item member" id="%s">%s%s</div>' % (
                anchor(pkg, name), sig(text), prose(docs.get(name))))

    nav.append("</div>")
    body.append("</section>")
    return "".join(nav), "".join(body), items, docs


def build_search(entries):
    """Headings of every page plus every API item, for the search dialog."""
    for page in sorted(DOCS.glob("*.html")):
        if page.name in ("api.html", "api.template.html"):
            continue
        text = page.read_text(encoding="utf-8")
        title = re.search(r"<title>([^<]*)</title>", text)
        page_title = html.unescape(title.group(1).split("—")[0].strip()) if title else page.stem
        for m in re.finditer(r"<h([23]) id=\"([^\"]+)\"[^>]*>(.*?)</h\1>", text, re.S):
            label = re.sub(r"<[^>]+>", "", m.group(3))
            label = html.unescape(label).replace("#", "").strip()
            entries.append({
                "name": label,
                "href": "%s#%s" % (page.name, m.group(2)),
                "where": page_title,
                "words": label.lower(),
            })
    (DOCS / "assets" / "search.json").write_text(
        json.dumps(entries, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


def main():
    nav, body, entries = [], [], []
    total = 0
    for pkg, folder, blurb in PACKAGES:
        group_nav, group_body, items, _ = render_package(pkg, folder, blurb)
        nav.append(group_nav)
        body.append(group_body)
        total += len(items)
        for kind, name, text, owner in items:
            if kind in ("method", "impl"):
                continue
            entries.append({
                "name": name,
                "kind": "fn" if kind == "fn" else ("value" if kind == "let" else kind),
                "href": "api.html#%s" % anchor(pkg, name),
                "where": short(pkg).split("/")[-1],
                "words": "%s %s" % (short(pkg), name.lower()),
            })

    template = (DOCS / "api.template.html").read_text(encoding="utf-8")
    page = template.replace("<!-- nav -->", "".join(nav)).replace("<!-- body -->", "".join(body))
    (DOCS / "api.html").write_text(page, encoding="utf-8", newline="\n")

    build_search(entries)
    print("docs/api.html: %d declarations across %d packages" % (total, len(PACKAGES)))


if __name__ == "__main__":
    main()

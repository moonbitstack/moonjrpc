"""Write docs/api.html from the sources' public declarations and `///` comments, so the reference follows the code.

Every name in a package's pkg.generated.mbti must end up on the page with a description; a public item
without one stops the script. Run it from anywhere; the output is deterministic.
"""
import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
PACKAGES = [
    ("moonjrpc", SRC, "Messages and the method table. No I/O."),
    ("moonjrpc/peer", SRC / "peer", "Two-way calls over any transport, and the two framings."),
]
# Trait methods every type gets from `derive`; listing them per type would bury the rest.
PLUMBING = {"equal", "not_equal", "to_repr", "to_json", "from_json"}
DECL = re.compile(
    r"^(?:pub(?:\((?:all|open)\))?\s+)?(?:async\s+)?(fn(?:\[[^\]]*\])?|let|struct|enum|suberror|trait)\s+([A-Za-z_][\w:]*)"
)


def version():
    return re.search(r'^version = "([^"]+)"', (ROOT / "moon.mod").read_text(encoding="utf-8"), re.M).group(1)


def signature(lines, at):
    """A declaration's head, on one line, up to the brace or the `=` that opens its body."""
    text = lines[at].rstrip()
    i = at
    if re.match(r"^(?:pub(?:\(\w+\))?\s+)?(?:async\s+)?fn", text):
        while not re.search(r"\{\s*$", lines[i]):
            i += 1
        head = " ".join(l.strip() for l in lines[at : i + 1])
        head = re.sub(r"\(\s+", "(", head)
        head = re.sub(r",\s*\)", ")", head)
        return re.sub(r"\s*\{$", "", head)
    if " let " in f" {text}":
        return text.split(" = ")[0]
    return text.rstrip("{ ").strip()


def block(lines, at):
    """The body of a type, for showing its fields or variants."""
    if not lines[at].rstrip().endswith("{"):
        return ""
    out = []
    i = at + 1
    while not lines[i].startswith("}"):
        if not lines[i].strip().startswith("///"):
            out.append(lines[i])
        i += 1
    return "\n".join(out)


def scan(folder):
    """Public declarations in source order: name, kind, signature, doc, body."""
    items = []
    files = sorted(p for p in folder.glob("*.mbt") if not p.name.endswith("_test.mbt") and not p.name.endswith("_wbtest.mbt"))
    for path in files:
        lines = path.read_text(encoding="utf-8").replace("\r\n", "\n").split("\n")
        doc = []
        for i, line in enumerate(lines):
            s = line.strip()
            if s == "///|":
                doc = []
            elif line.startswith("///"):
                doc.append(s[3:].strip())
            elif line.startswith("#") or line.startswith("//"):
                continue
            else:
                m = DECL.match(line)
                abstract = line.startswith("struct ")
                if m and (line.startswith("pub") or abstract):
                    kind = m.group(1).split("[")[0]
                    items.append(
                        {
                            "name": m.group(2),
                            "kind": kind,
                            "sig": signature(lines, i),
                            "doc": " ".join(doc),
                            "body": block(lines, i) if kind in ("struct", "enum", "suberror", "trait") and not abstract else "",
                        }
                    )
                if line and not line.startswith(" "):
                    doc = []
    return items


def public_names(folder):
    """Names the interface file lists, so a public item cannot be left off the page."""
    text = (folder / "pkg.generated.mbti").read_text(encoding="utf-8")
    names = set()
    for line in text.split("\n"):
        m = re.match(r"^(?:pub(?:\(\w+\))?\s+)?(?:async\s+)?(?:fn(?:\[[^\]]*\])?|let|struct|enum|suberror|trait|type)\s+([A-Za-z_][\w:]*)", line)
        if m and m.group(1).split("::")[-1] not in PLUMBING:
            names.add(m.group(1))
    return names


def inline(text):
    return re.sub(r"`([^`]+)`", lambda m: f"<code>{m.group(1)}</code>", html.escape(text, quote=False))


def anchor(pkg, name):
    return (pkg.replace("/", "-") + "-" + name.replace("::", "-")).lower()


def render(pkg, intro, items):
    side = [f'<div class="pk">{pkg}</div>']
    body = [f'<h2 id="{anchor(pkg, "top")}">{pkg}</h2>', f"<p>{inline(intro)}</p>"]
    methods = {}
    for item in items:
        if "::" in item["name"]:
            methods.setdefault(item["name"].split("::")[0], []).append(item)
    tops = [i for i in items if "::" not in i["name"]]
    for item in sorted(tops, key=lambda i: (i["kind"] in ("fn", "let"), i["name"].lower())):
        side.append(f'<a href="#{anchor(pkg, item["name"])}">{item["name"]}</a>')
        body.append(card(pkg, item))
        for m in methods.get(item["name"], []):
            body.append(card(pkg, m))
    return side, body


def card(pkg, item):
    out = [f'<section class="item" id="{anchor(pkg, item["name"])}">']
    out.append(f'<h3><span class="kind">{item["kind"]}</span><a href="#{anchor(pkg, item["name"])}">{item["name"]}</a></h3>')
    text = item["sig"]
    if item["body"]:
        text += " {\n" + item["body"] + "\n}"
    out.append(f'<pre><code class="mbt">{html.escape(text, quote=False)}</code></pre>')
    out.append(f"<p>{inline(item['doc'])}</p>")
    out.append("</section>")
    return "\n".join(out)


def main():
    side, body = [], []
    missing = []
    for pkg, folder, intro in PACKAGES:
        items = [i for i in scan(folder) if i["name"].split("::")[-1] not in PLUMBING]
        listed = {i["name"] for i in items}
        missing += [f"{pkg}: {n} is not in the sources" for n in sorted(public_names(folder) - listed)]
        missing += [f"{pkg}: {i['name']} has no description" for i in items if not i["doc"]]
        s, b = render(pkg, intro, items)
        side += s
        body += b
    if missing:
        sys.exit("\n".join(missing))
    page = (ROOT / "docs/api.template.html").read_text(encoding="utf-8").replace("\r\n", "\n")
    page = page.replace("<!-- version -->", version())
    page = page.replace("<!-- side -->", "\n".join(side)).replace("<!-- body -->", "\n".join(body))
    (ROOT / "docs/api.html").write_text(page, encoding="utf-8", newline="\n")
    print("wrote docs/api.html")


main()

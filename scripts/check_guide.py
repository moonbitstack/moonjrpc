"""Every line of code and output the pages mark `data-check` must appear in the guide's tests.

The tests are what actually ran, so a page that drifts from them stops here.
"""
import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
tests = ""
for path in [ROOT / "src/guide_test.mbt", ROOT / "src/peer/guide_test.mbt"]:
    tests += path.read_text(encoding="utf-8")
known = {line.strip() for line in tests.replace("\r\n", "\n").split("\n")}
known |= {line.strip().removeprefix("#|") for line in tests.replace("\r\n", "\n").split("\n")}
# A one-line output may sit inside `content="..."`.
known |= set(re.findall(r'content="([^"]*)"', tests))

missing = []
count = 0
for page in ["index.html", "guide.html"]:
    text = (ROOT / "docs" / page).read_text(encoding="utf-8")
    for block in re.findall(r"<pre[^>]*data-check[^>]*>(.*?)</pre>", text, re.S):
        code = html.unescape(re.sub(r"<[^>]+>", "", block))
        for line in code.split("\n"):
            line = line.strip()
            if not line:
                continue
            count += 1
            if line not in known:
                missing.append(f"{page}: {line}")
if count == 0:
    sys.exit("no marked code found")
if missing:
    sys.exit("not in the guide's tests:\n" + "\n".join(missing))
print(f"{count} lines of code and output match the tests")

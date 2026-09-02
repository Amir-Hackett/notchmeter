#!/bin/bash
# Fetches Anthropic's pricing page and compares its per-model input/output rates with the committed snapshot,
# Sources/Notchmeter/Resources/pricing-snapshot.json. Exits 1 with the diff when a rate moved or a model in the
# snapshot is no longer found, so the weekly workflow (.github/workflows/pricing.yml) fails loudly.
#   scripts/pricing-check.sh              fetch and compare
#   scripts/pricing-check.sh page.html    compare against a saved copy of the page
# The page is marketing HTML; the extraction is a best effort over its text. A parse failure is reported as such,
# which is still a signal that the page changed.
set -euo pipefail
cd "$(dirname "$0")/.."
SNAPSHOT=Sources/Notchmeter/Resources/pricing-snapshot.json
URL="https://platform.claude.com/docs/en/about-claude/pricing"
if [ $# -ge 1 ]; then
  PAGE="$1"
else
  PAGE="$(mktemp)"
  curl -fsSL -A "Notchmeter pricing check (https://github.com/Amir-Hackett/notchmeter)" "$URL" -o "$PAGE"
fi
python3 - "$SNAPSHOT" "$PAGE" <<'PY'
import html, json, re, sys
snapshot = json.load(open(sys.argv[1]))
raw = open(sys.argv[2], encoding="utf-8", errors="replace").read()
text = html.unescape(re.sub(r"<[^>]+>", " ", raw))
text = re.sub(r"\s+", " ", text)

# The page names each row "Claude Opus 4.8" and follows it with five "$X / MTok" figures: base input, 5m cache
# write, 1h cache write, cache hit, output. The same name also appears in the navigation without figures, so the
# first occurrence followed closely by a dollar figure is the row. A snapshot entry marked "retired" may be absent.
def phrases(prefix):
    parts = prefix.replace("claude-", "").split("-")
    digits = [p for p in parts if p.isdigit()]
    family = [p for p in parts if not p.isdigit()]
    version = ".".join(digits)
    fam = family[0].capitalize() if family else ""
    return [f"Claude {fam} {version}".strip(), f"Claude {version} {fam}".strip()]

money = re.compile(r"\$\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*MTok", re.I)

def row(name):
    start = 0
    while True:
        idx = text.find(name, start)
        if idx < 0:
            return None
        after = text[idx + len(name) : idx + len(name) + 400]
        # The next row's name (or a footnote) ends this one; only the figures before it count.
        stop = re.search(r"Claude [A-Z]", after)
        segment = after[: stop.start()] if stop else after
        figures = money.findall(segment)
        if len(figures) >= 5 and segment.lstrip().startswith(("$", "(")):
            return name, float(figures[0]), float(figures[4])
        start = idx + len(name)

failures = []
found_any = False
for prefix, rates in snapshot["models"].items():
    hit = None
    for name in phrases(prefix):
        hit = row(name)
        if hit:
            break
    if hit is None:
        if rates.get("retired"):
            print(f"pricing-check: {prefix} is marked retired and is not on the page (kept for old transcripts)")
        else:
            failures.append(f"{prefix}: not found on the page (snapshot input {rates['input']}, output {rates['output']})")
        continue
    found_any = True
    name, page_in, page_out = hit
    if abs(page_in - rates["input"]) > 1e-9 or abs(page_out - rates["output"]) > 1e-9:
        failures.append(f"{prefix} ({name}): page says ${page_in}/${page_out}, snapshot says ${rates['input']}/${rates['output']}")

if not found_any:
    print("pricing-check: could not find any model row on the page; its layout may have changed", file=sys.stderr)
    sys.exit(1)
if failures:
    print("pricing-check: the pricing page differs from the snapshot dated " + snapshot["snapshotDate"] + ":")
    for f in failures:
        print("  " + f)
    print("Update ModelPricing.swift, the snapshot and docs/accuracy.md together.")
    sys.exit(1)
print(f"pricing-check: every model in the snapshot ({snapshot['snapshotDate']}) matches the page")
PY

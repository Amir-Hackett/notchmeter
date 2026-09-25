#!/bin/bash
# Checks the two price documents in the repository against each other and against Anthropic's pricing page:
#   Sources/Notchmeter/Resources/pricing-snapshot.json   the table compiled into the app, dated
#   pricing/catalog.json                                 the catalog the app fetches daily (docs/accuracy.md, "The pricing catalog")
# The catalog is validated on the rules PricingCatalog.swift applies (schema 1, a YYYY-MM-DD day per entry, every
# rate above zero and at most $1,000 per million, a cache read no dearer than the input, fast rates in pairs, no
# two entries for one model on one day), and its newest entry per Anthropic model must agree with the snapshot,
# so the two cannot drift apart. Then, unless --offline is given, the page is fetched and both documents' per-model
# input/output rates are compared with it. Exits 1 with the differences when anything moved, so the weekly workflow
# (.github/workflows/pricing.yml) fails loudly.
#   scripts/pricing-check.sh              validate, then fetch the page and compare
#   scripts/pricing-check.sh --offline    validate the catalog and its agreement with the snapshot; no network
#   scripts/pricing-check.sh page.html    compare against a saved copy of the page
# The page is marketing HTML; the extraction is a best effort over its text. A parse failure is reported as such,
# which is still a signal that the page changed.
set -euo pipefail
cd "$(dirname "$0")/.."
SNAPSHOT=Sources/Notchmeter/Resources/pricing-snapshot.json
CATALOG=pricing/catalog.json
URL="https://platform.claude.com/docs/en/about-claude/pricing"
PAGE=""
if [ $# -ge 1 ] && [ "$1" = "--offline" ]; then
  PAGE="--offline"
elif [ $# -ge 1 ]; then
  PAGE="$1"
else
  PAGE="$(mktemp)"
  curl -fsSL -A "Notchmeter pricing check (https://github.com/Amir-Hackett/notchmeter)" "$URL" -o "$PAGE"
fi
python3 - "$SNAPSHOT" "$CATALOG" "$PAGE" <<'PY'
import datetime, html, json, re, sys
snapshot = json.load(open(sys.argv[1]))
catalog = json.load(open(sys.argv[2]))
page = sys.argv[3]
failures = []

# --- The catalog, on PricingCatalog.swift's rules ---------------------------------------------------------------
MOST = 1000.0
ID = re.compile(r"^[a-z0-9][a-z0-9.-]{1,63}$")

def day(text):
    if not isinstance(text, str) or len(text) != 10:
        return None
    try:
        return datetime.date.fromisoformat(text)
    except ValueError:
        return None

def rate(row, key, where, required):
    if key not in row:
        if required:
            failures.append(f"{where}: {key} is missing")
        return None
    value = row[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not (0 < value <= MOST):
        failures.append(f"{where}: {key} must be above 0 and at most {int(MOST)}")
        return None
    return float(value)

if catalog.get("schema") != 1 or isinstance(catalog.get("schema"), bool):
    failures.append(f"catalog: schema {catalog.get('schema')!r}; the app reads schema 1")
if day(catalog.get("published")) is None:
    failures.append("catalog: published is not a YYYY-MM-DD day")
seen = set()
newest = {}
for index, row in enumerate(catalog.get("anthropic") or []):
    where = f"anthropic[{index}]"
    prefix = row.get("prefix")
    if not isinstance(prefix, str) or not ID.match(prefix) or not prefix.startswith("claude-"):
        failures.append(f"{where}: prefix must be a lower-case claude- model id")
        continue
    where += f" {prefix}"
    effective = day(row.get("effective"))
    if effective is None or row["effective"] < "2020-01-01":
        failures.append(f"{where}: effective must be a YYYY-MM-DD day from 2020 on")
        continue
    if (prefix, row["effective"]) in seen:
        failures.append(f"{where}: two entries effective {row['effective']}")
    seen.add((prefix, row["effective"]))
    i = rate(row, "input", where, True)
    o = rate(row, "output", where, True)
    cr = rate(row, "cacheRead", where, False)
    rate(row, "cacheWrite5m", where, False)
    rate(row, "cacheWrite1h", where, False)
    if i is not None and cr is not None and cr > i:
        failures.append(f"{where}: cacheRead is above input")
    fi = rate(row, "fastInput", where, False)
    fo = rate(row, "fastOutput", where, False)
    if (fi is None) != (fo is None):
        failures.append(f"{where}: fastInput and fastOutput go together")
    fcr = rate(row, "fastCacheRead", where, False)
    if fi is not None and fcr is not None and fcr > fi:
        failures.append(f"{where}: fastCacheRead is above fastInput")
    if i is not None and o is not None and effective <= datetime.date.today():
        if prefix not in newest or newest[prefix][0] < effective:
            newest[prefix] = (effective, i, o)
for index, row in enumerate(catalog.get("openai") or []):
    where = f"openai[{index}]"
    model = row.get("id")
    if not isinstance(model, str) or not ID.match(model):
        failures.append(f"{where}: id must be a lower-case model id")
        continue
    where += f" {model}"
    if day(row.get("effective")) is None or row["effective"] < "2020-01-01":
        failures.append(f"{where}: effective must be a YYYY-MM-DD day from 2020 on")
        continue
    if (model, row["effective"]) in seen:
        failures.append(f"{where}: two entries effective {row['effective']}")
    seen.add((model, row["effective"]))
    i = rate(row, "input", where, True)
    rate(row, "output", where, True)
    ci = rate(row, "cachedInput", where, False)
    if i is not None and ci is not None and ci > i:
        failures.append(f"{where}: cachedInput is above input")
    if "cacheWrite" in row:
        cw = row["cacheWrite"]
        if isinstance(cw, bool) or not isinstance(cw, (int, float)) or not (0 <= cw <= MOST):
            failures.append(f"{where}: cacheWrite must be 0 to {int(MOST)}")
    if "longContext" in row:
        lc = row["longContext"]
        if isinstance(lc, bool) or not isinstance(lc, int) or not (1000 <= lc <= 100_000_000):
            failures.append(f"{where}: longContext must be a token count")

# --- The catalog against the snapshot ---------------------------------------------------------------------------
for prefix, rates in snapshot["models"].items():
    if prefix not in newest:
        failures.append(f"catalog: no entry for {prefix}, which the snapshot has")
        continue
    _, i, o = newest[prefix]
    if abs(i - rates["input"]) > 1e-9 or abs(o - rates["output"]) > 1e-9:
        failures.append(f"catalog: {prefix} says ${i}/${o}, the snapshot says ${rates['input']}/${rates['output']}")

if failures:
    print("pricing-check: the catalog or the snapshot fails a check:")
    for f in failures:
        print("  " + f)
    sys.exit(1)
print(f"pricing-check: the catalog ({catalog['published']}, {len(catalog['anthropic'])} Anthropic and {len(catalog['openai'])} OpenAI entries) "
      f"passes every check and agrees with the snapshot ({snapshot['snapshotDate']})")
if page == "--offline":
    sys.exit(0)

# --- Both against the page --------------------------------------------------------------------------------------
raw = open(page, encoding="utf-8", errors="replace").read()
text = html.unescape(re.sub(r"<[^>]+>", " ", raw))
text = re.sub(r"\s+", " ", text)

# The page names each row "Claude Opus 4.8" and follows it with five "$X / MTok" figures. Their order is read
# from the table's own header, because it has changed once already: until 2026-09 the columns ran input, 5m cache
# write, 1h cache write, cache hit, output, and now run input, output, 5m, 1h, hits. The headline rows carry a
# one-line description between the name and the first figure, and the same name appears in the navigation
# without figures, so the first occurrence with five figures before the next row's name is the row. A name is
# matched on a word boundary, so "Claude Opus 5" is not the "Claude Opus 5.5" row. A snapshot entry marked
# "retired" may be absent.
def phrases(prefix):
    parts = prefix.replace("claude-", "").split("-")
    digits = [p for p in parts if p.isdigit()]
    family = [p for p in parts if not p.isdigit()]
    version = ".".join(digits)
    fam = family[0].capitalize() if family else ""
    return [f"Claude {fam} {version}".strip(), f"Claude {version} {fam}".strip()]

money = re.compile(r"\$\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*MTok", re.I)
columns = [("input", r"\bInput\b"), ("output", r"\bOutput\b"), ("5m", r"\b5m\b"), ("1h", r"\b1h\b"), ("hits", r"\bHits\b")]

def output_column():
    """The index of the output figure among a row's five, from the first header naming all five columns."""
    for match in re.finditer(r"\bModel\b", text):
        segment = text[match.start() : match.start() + 300]
        stop = re.search(r"Claude [A-Z]", segment)
        if stop:
            segment = segment[: stop.start()]
        positions = {}
        for key, pattern in columns:
            hit = re.search(pattern, segment, re.I)
            if not hit:
                break
            positions[key] = hit.start()
        else:
            return sorted(positions, key=positions.get).index("output")
    return None

def row(name, out):
    for match in re.finditer(re.escape(name) + r"(?![\d.])", text):
        after = text[match.end() : match.end() + 400]
        # The next row's name (or a footnote) ends this one; only the figures before it count.
        stop = re.search(r"Claude [A-Z]", after)
        segment = after[: stop.start()] if stop else after
        figures = money.findall(segment)
        if len(figures) >= 5:
            return name, float(figures[0]), float(figures[out])
    return None

out = output_column()
if out is None:
    print("pricing-check: could not read the table header on the page; its layout may have changed", file=sys.stderr)
    sys.exit(1)

found_any = False
for prefix, rates in snapshot["models"].items():
    hit = None
    for name in phrases(prefix):
        hit = row(name, out)
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
    _, cat_in, cat_out = newest[prefix]
    if abs(page_in - cat_in) > 1e-9 or abs(page_out - cat_out) > 1e-9:
        failures.append(f"{prefix} ({name}): page says ${page_in}/${page_out}, catalog says ${cat_in}/${cat_out}")

if not found_any:
    print("pricing-check: could not find any model row on the page; its layout may have changed", file=sys.stderr)
    sys.exit(1)
if failures:
    print("pricing-check: the pricing page differs from the snapshot dated " + snapshot["snapshotDate"] + " or the catalog published " + catalog["published"] + ":")
    for f in failures:
        print("  " + f)
    print("Update ModelPricing.swift, the snapshot and docs/accuracy.md together, and add a dated entry to pricing/catalog.json.")
    sys.exit(1)
print(f"pricing-check: every model in the snapshot ({snapshot['snapshotDate']}) and the catalog ({catalog['published']}) matches the page")
PY

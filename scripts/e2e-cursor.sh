#!/bin/bash
# End to end, with a hand on the notch: Cursor's *Require notch approval* answered on the panel itself. It launches
# the built app, sends the hook commands Cursor runs before a shell command and an MCP call, presses the notch's own
# Allow, Deny and Answer in Cursor through the Accessibility API (scripts/notch-press.swift), and checks what the
# hook printed for Cursor and what the oracle says the app did.
#
# scripts/e2e.sh covers everything that needs no click and runs in CI. This one needs the Accessibility permission
# for the terminal it runs in (System Settings › Privacy & Security › Accessibility), so it runs on a Mac with
# someone's grant, not on a runner. Like e2e.sh it writes the app's preferences and puts them back, so it wants
# E2E_ALLOW_PREFS=1, and it wants no other copy of Notchmeter running.
#
#   E2E_ALLOW_PREFS=1 scripts/e2e-cursor.sh [build/Notchmeter.app]
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Notchmeter.app}"
BIN="$APP/Contents/MacOS/Notchmeter"
DOMAIN=com.amirhackett.notchmeter

if [ -z "${E2E_ALLOW_PREFS:-}" ]; then
  echo "e2e-cursor: writes $DOMAIN preferences; run with E2E_ALLOW_PREFS=1" >&2
  exit 2
fi
[ -x "$BIN" ] || { echo "e2e-cursor: no app at $APP (run scripts/build.sh)" >&2; exit 2; }
if pgrep -U "$(id -u)" -x Notchmeter >/dev/null; then
  echo "e2e-cursor: Notchmeter is already running for this user; quit it first" >&2
  exit 2
fi

WORK="$(mktemp -d)"
ORACLE="$WORK/oracle.jsonl"
BACKUP="$WORK/prefs.plist"
PRESS="$WORK/notch-press"
defaults export "$DOMAIN" "$BACKUP" 2>/dev/null || true
APP_PID=""

cleanup() {
  if [ -n "$APP_PID" ]; then kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; fi
  defaults delete "$DOMAIN" 2>/dev/null || true
  if [ -s "$BACKUP" ]; then defaults import "$DOMAIN" "$BACKUP"; fi
  if [ -n "${KEEP_ORACLE:-}" ]; then cp "$ORACLE" "$KEEP_ORACLE" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

swiftc -O scripts/notch-press.swift -o "$PRESS"
"$PRESS" --trusted || { echo "e2e-cursor: this terminal has no Accessibility permission, which pressing the notch's buttons needs" >&2; exit 2; }

defaults delete "$DOMAIN" 2>/dev/null || true
defaults write "$DOMAIN" welcomed -bool true
defaults write "$DOMAIN" hookOfferShown -bool true
defaults write "$DOMAIN" cursorRequireApproval -bool true

mkdir -p "$WORK/proj"
"$BIN" --e2e-oracle "$ORACLE" --no-prompt >"$WORK/app.log" 2>&1 &
APP_PID=$!

count() {
  python3 - "$ORACLE" "$1" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
n = 0
try:
    for line in open(path):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if eval(expr, {}, {"o": o}):
            n += 1
except FileNotFoundError:
    pass
print(n)
PY
}

wait_for() { # description, predicate, at least, seconds
  local deadline=$((SECONDS + $4))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(count "$2")" -ge "$3" ]; then echo "ok: $1"; return 0; fi
    sleep 1
  done
  echo "FAIL: $1 (wanted $3, saw $(count "$2"))" >&2
  echo "--- oracle tail ---" >&2; tail -n 30 "$ORACLE" >&2 2>/dev/null || true
  return 1
}

# One Cursor hook event for the run's conversation, through the hook command Cursor runs; its answer on stdout.
cursor() { # event, extra JSON members
  printf '{"conversation_id":"e2e-press","hook_event_name":"%s","cursor_version":"e2e","workspace_roots":["%s"],"cwd":"%s"%s}' \
    "$1" "$WORK/proj" "$WORK/proj" "${2:-}" | "$BIN" --hook --tool cursor
}

# The panel opens by itself for a request; should it not have, a click on the closed notch opens it.
open_panel() {
  python3 - "$ORACLE" <<'PY' | xargs "$PRESS" --click
import json, sys
region = None
for line in open(sys.argv[1]):
    try:
        o = json.loads(line)
    except ValueError:
        continue
    if o.get("event") == "regions" and o.get("compact"):
        region = o["compact"]
print(region["x"] + region["width"] / 2, region["y"] + region["height"] / 2) if region else print(0, 0)
PY
}

press() { # label
  "$PRESS" "$1" 6 || { open_panel; sleep 1; "$PRESS" "$1" 6; }
}

# One held call answered on the notch: the event and its members, the button, what the hook must print (a fixed
# string to match exactly), and the behaviour the oracle must record.
answered() { # description, event, members, button, printed, behaviour
  local held before decided recorded
  held="$WORK/held.$RANDOM.out"
  recorded="o[\"event\"] == \"decision\" and o.get(\"session\") == \"cursor:e2e-press\" and o.get(\"behavior\") == \"$6\""
  before="$(count 'o["event"] == "hook" and o.get("session") == "e2e-press" and o.get("request") == "permission"')"
  decided="$(count "$recorded")"
  cursor "$2" "$3" >"$held" &
  local pid=$!
  wait_for "$1: held for the notch" 'o["event"] == "hook" and o.get("session") == "e2e-press" and o.get("request") == "permission"' $((before + 1)) 10
  press "$4"
  wait "$pid" || true
  case "$(cat "$held")" in
    *"$5"*) echo "ok: $1: Cursor is told $5" ;;
    *) echo "FAIL: $1: the hook printed: $(cat "$held")" >&2; return 1 ;;
  esac
  wait_for "$1: the app records $6" "$recorded" $((decided + 1)) 5
}

wait_for "the app launched" 'o["event"] == "launched"' 1 60
for _ in $(seq 1 30); do
  cursor beforeSubmitPrompt ',"composer_mode":"agent","prompt":"e2e"' >/dev/null
  if [ "$(count 'o["event"] == "hook"')" -ge 1 ]; then break; fi
  sleep 1
done
wait_for "the hook reached the app" 'o["event"] == "hook" and o.get("session") == "e2e-press"' 1 5

answered "Allow" beforeShellExecution ',"command":"echo one"' "Allow (⌘Y)" '"permission":"allow"' allow
answered "Deny" beforeShellExecution ',"command":"echo two"' "Deny (⌘N)" '"permission":"deny"' deny
answered "Answer in Cursor" beforeShellExecution ',"command":"echo three"' "Answer in Cursor" '{"permission":"ask"}' pass
# Cursor documents an MCP call's `tool_input` as a JSON string, not an object.
answered "an MCP call, allowed" beforeMCPExecution ',"tool_name":"search","tool_input":"{\"query\":\"notchmeter\"}"' "Allow (⌘Y)" '"permission":"allow"' allow

kill -0 "$APP_PID" 2>/dev/null || { echo "FAIL: the app exited during the run" >&2; exit 1; }
echo "e2e-cursor: all checks passed"

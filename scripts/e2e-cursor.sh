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
# The app's path as given, made absolute before the move to the repository's root.
APP="${1:-}"
if [ -n "$APP" ]; then APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"; fi
cd "$(dirname "$0")/.."
APP="${APP:-$PWD/build/Notchmeter.app}"
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
  if [ -s "$BACKUP" ]; then defaults import "$DOMAIN" "$BACKUP" || echo "e2e-cursor: could not put the preferences back from $BACKUP" >&2; fi
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
# The buttons are found by their English labels, whatever language the Mac speaks.
defaults write "$DOMAIN" AppleLanguages -array en
# *Mirror Cursor's cards*, and the file that stands for Cursor's window in this run (FileCursorUI): no card yet.
defaults write "$DOMAIN" cursorControl -bool true
CARDS="$WORK/cursor-cards.json"
printf '[]' >"$CARDS"

mkdir -p "$WORK/proj" "$WORK/card-proj"
"$BIN" --e2e-oracle "$ORACLE" --e2e-cursor-cards "$CARDS" --no-prompt >"$WORK/app.log" 2>&1 &
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

# One of Cursor's own cards (0.9.17), through the stand-in for its window: the notch opens on the card by itself,
# with no click to open it, Run is pressed on the notch, the press takes the card out of "Cursor's window", and
# the notch closes with it.
opened='o["event"] == "panel" and o.get("state") == "expanded" and o.get("cause") == "notification" and o.get("cards") == ["notice"]'
closed='o["event"] == "panel" and o.get("state") == "compact" and o.get("cause") == "notification"'
pressed='o["event"] == "decision" and o.get("source") == "cursorCard" and o.get("session") == "cursor:e2e-card" and o.get("behavior") == "pressed"'
opened_before="$(count "$opened")"; closed_before="$(count "$closed")"
printf '{"conversation_id":"e2e-card","hook_event_name":"beforeSubmitPrompt","cursor_version":"e2e","workspace_roots":["%s"],"prompt":"e2e card"}' "$WORK/card-proj" \
  | "$BIN" --hook --tool cursor >/dev/null
printf '[{"kind":"run","window":"card-proj","heading":"ls -la","options":["Skip","Run"]}]' >"$CARDS.new" && mv "$CARDS.new" "$CARDS"
wait_for "Cursor's Run card: the notch opens on it by itself" "$opened" $((opened_before + 1)) 10
"$PRESS" Run 8 || { echo "FAIL: no Run button on the notch" >&2; exit 1; }
wait_for "Run, pressed on the notch, is pressed in Cursor" "$pressed" 1 10
[ "$(cat "$CARDS")" = "[]" ] && echo "ok: and the card has left Cursor's window" || { echo "FAIL: the card is still there: $(cat "$CARDS")" >&2; exit 1; }
wait_for "and the notch closes with it" "$closed" $((closed_before + 1)) 10

kill -0 "$APP_PID" 2>/dev/null || { echo "FAIL: the app exited during the run" >&2; exit 1; }
echo "e2e-cursor: all checks passed"

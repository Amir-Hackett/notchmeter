#!/bin/bash
# End to end: launches the built app, drives it with real hook commands (the same `Notchmeter --hook` an assistant
# runs, over the same socket) and checks what it did from the oracle (docs/testing.md "The oracle"). Covers the
# quiet-turn nudge, a muted project's nudge, and a session's back-off after a nudge it went on from by itself.
#
# It writes the app's preferences, so it runs only in CI or with E2E_ALLOW_PREFS=1, and puts the previous
# preferences back on the way out. Needs a logged-in GUI session (a GitHub macOS runner has one).
set -euo pipefail

APP="${1:-build/Notchmeter.app}"
BIN="$APP/Contents/MacOS/Notchmeter"
DOMAIN=com.amirhackett.notchmeter
QUIET=15

if [ -z "${CI:-}" ] && [ -z "${E2E_ALLOW_PREFS:-}" ]; then
  echo "e2e: writes $DOMAIN preferences; run in CI or with E2E_ALLOW_PREFS=1" >&2
  exit 2
fi
[ -x "$BIN" ] || { echo "e2e: no app at $APP (run scripts/build.sh)" >&2; exit 2; }
# A copy already running holds the hook socket and Application Support: the events would reach it, not this run.
if pgrep -U "$(id -u)" -x Notchmeter >/dev/null; then
  echo "e2e: Notchmeter is already running for this user; quit it first" >&2
  exit 2
fi

WORK="$(mktemp -d)"
ORACLE="$WORK/oracle.jsonl"
BACKUP="$WORK/prefs.plist"
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

# A first launch shows the Welcome and the hook offer; neither is under test. The quiet spell is the floor of its
# range so the run stays short, and one project is muted.
defaults delete "$DOMAIN" 2>/dev/null || true
defaults write "$DOMAIN" welcomed -bool true
defaults write "$DOMAIN" hookOfferShown -bool true
defaults write "$DOMAIN" quietNudgeSeconds -int "$QUIET"
defaults write "$DOMAIN" mutedNudgeProjects -array muted-proj

mkdir -p "$WORK/loud-proj" "$WORK/muted-proj"
"$BIN" --e2e-oracle "$ORACLE" --no-prompt >"$WORK/app.log" 2>&1 &
APP_PID=$!

# The oracle's lines, as JSON, counted by a predicate on the parsed object.
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
  echo "--- oracle tail ---" >&2; tail -n 40 "$ORACLE" >&2 2>/dev/null || true
  echo "--- app log tail ---" >&2; tail -n 40 "$WORK/app.log" >&2 || true
  return 1
}

expect_none() { # description, predicate
  local n; n="$(count "$2")"
  if [ "$n" -eq 0 ]; then echo "ok: $1"; else echo "FAIL: $1 (saw $n)" >&2; tail -n 40 "$ORACLE" >&2; return 1; fi
}

# One Cursor hook event, through the hook command an assistant runs.
cursor() { # conversation, folder, event
  printf '{"conversation_id":"%s","hook_event_name":"%s","cursor_version":"e2e","workspace_roots":["%s"]}' "$1" "$3" "$WORK/$2" \
    | "$BIN" --hook --tool cursor --event "$3" >/dev/null
}

wait_for "the app launched" 'o["event"] == "launched"' 1 60
# The socket comes up with the store; the first hook retries until it is heard.
for _ in $(seq 1 30); do
  cursor e2e-loud loud-proj beforeSubmitPrompt
  if [ "$(count 'o["event"] == "hook"')" -ge 1 ]; then break; fi
  sleep 1
done
wait_for "the hook reached the app" 'o["event"] == "hook"' 1 5
cursor e2e-loud loud-proj afterAgentThought
cursor e2e-muted muted-proj beforeSubmitPrompt
cursor e2e-muted muted-proj afterAgentThought
wait_for "four hook events heard" 'o["event"] == "hook"' 4 10

nudged='o["event"] == "session" and o.get("action") == "nudged"'
wait_for "a quiet turn is nudged" "$nudged and o.get(\"session\") == \"cursor:e2e-loud\" and o.get(\"muted\") is False" 1 $((QUIET + 20))
wait_for "a muted project's quiet turn is nudged as muted" "$nudged and o.get(\"session\") == \"cursor:e2e-muted\" and o.get(\"muted\") is True" 1 10
expect_none "the muted project is never nudged as unmuted" "$nudged and o.get(\"session\") == \"cursor:e2e-muted\" and o.get(\"muted\") is False"

# The loud turn goes on by itself (no command started): a false alarm, so its next quiet spell is doubled.
cursor e2e-loud loud-proj afterAgentResponse
cursor e2e-loud loud-proj beforeSubmitPrompt
cursor e2e-loud loud-proj afterAgentThought
sleep $((QUIET + 5))
expect_none "the next nudge waits past the set spell" "$nudged and o.get(\"session\") == \"cursor:e2e-loud\" and o.get(\"quietFalseAlarms\") == 1"
wait_for "and comes at the doubled one" "$nudged and o.get(\"session\") == \"cursor:e2e-loud\" and o.get(\"quietFalseAlarms\") == 1" 1 $((QUIET + 15))

kill -0 "$APP_PID" 2>/dev/null || { echo "FAIL: the app exited during the run" >&2; exit 1; }
echo "e2e: all checks passed"

#!/bin/bash
# End to end: launches the built app, drives it with real hook commands (the same `Notchmeter --hook` an assistant
# runs, over the same socket) and checks what it did from the oracle (docs/testing.md "The oracle"). Covers the
# quiet-turn nudge, a muted project's nudge, and a session's back-off after a nudge it went on from by itself; and since
# 0.9.13 every assistant's task list through its own hook command (Cursor's from a transcript the run writes under
# ~/.cursor/projects and removes), the compaction and the model another assistant reports, and a turn nobody typed.
# Since 0.9.15 Cursor's own: a plan on the row from `CreatePlan` before it is built, the statuses of the plan file
# the run writes under ~/.cursor/plans and removes, a change to that file with no hook, a Build, and *Require notch
# approval* at its three edges that need no hand on the notch: off (nothing printed), on with no app running, and
# on with nobody answering (both hand the call back to Cursor's own prompt). The answers themselves, pressed on
# the notch, are scripts/e2e-cursor.sh.
#
# It writes the app's preferences, so it runs only in CI or with E2E_ALLOW_PREFS=1, and puts the previous
# preferences back on the way out. Needs a logged-in GUI session (a GitHub macOS runner has one).
#
# On a Mac where Cursor is in use: for the two minutes of the run *Require notch approval* is on in the real
# preferences, which Cursor's own hook reads, so a command a real Cursor chat runs meanwhile is held or handed to
# Cursor's own prompt. The exit trap puts the setting back; a run killed with SIGKILL leaves it on, and
# `defaults delete com.amirhackett.notchmeter cursorRequireApproval` takes it off.
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
# Cursor's transcripts live under ~/.cursor/projects; the app reads none anywhere else, so the run's one goes there.
CURSOR_PROJECT="$HOME/.cursor/projects/notchmeter-e2e-$$"
# And its plan files under ~/.cursor/plans, where the app reads none anywhere else either.
CURSOR_PLAN="$HOME/.cursor/plans/notchmeter_e2e_$$.plan.md"
ORACLE="$WORK/oracle.jsonl"
BACKUP="$WORK/prefs.plist"
defaults export "$DOMAIN" "$BACKUP" 2>/dev/null || true
APP_PID=""

cleanup() {
  if [ -n "$APP_PID" ]; then kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; fi
  if [ -n "${HELD_PID:-}" ]; then kill "$HELD_PID" 2>/dev/null || true; fi
  # What the run put under ~/.cursor goes first, so nothing below can leave it behind; the two folders go too when
  # the run made them and they are empty again.
  rm -rf "$CURSOR_PROJECT"
  rm -f "$CURSOR_PLAN"
  if [ -n "$MADE_PROJECTS" ]; then rmdir "$HOME/.cursor/projects" 2>/dev/null || true; fi
  if [ -n "$MADE_PLANS" ]; then rmdir "$HOME/.cursor/plans" 2>/dev/null || true; fi
  if [ -n "$MADE_CURSOR" ]; then rmdir "$HOME/.cursor" 2>/dev/null || true; fi
  defaults delete "$DOMAIN" 2>/dev/null || true
  if [ -s "$BACKUP" ]; then defaults import "$DOMAIN" "$BACKUP" || echo "e2e: could not put the preferences back from $BACKUP" >&2; fi
  if [ -n "${KEEP_ORACLE:-}" ]; then cp "$ORACLE" "$KEEP_ORACLE" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
MADE_CURSOR=""; MADE_PROJECTS=""; MADE_PLANS=""
[ -d "$HOME/.cursor" ] || MADE_CURSOR=1
[ -d "$HOME/.cursor/projects" ] || MADE_PROJECTS=1
[ -d "$HOME/.cursor/plans" ] || MADE_PLANS=1
trap cleanup EXIT

# A first launch shows the Welcome and the hook offer; neither is under test. The quiet spell is the floor of its
# range so the run stays short, and one project is muted.
defaults delete "$DOMAIN" 2>/dev/null || true
defaults write "$DOMAIN" welcomed -bool true
defaults write "$DOMAIN" hookOfferShown -bool true
defaults write "$DOMAIN" quietNudgeSeconds -int "$QUIET"
defaults write "$DOMAIN" mutedNudgeProjects -array muted-proj

mkdir -p "$WORK/loud-proj" "$WORK/muted-proj"

# Cursor's *Require notch approval*, before the app is up. Off, the hook holds nothing and prints nothing, so
# Cursor's own flow decides. On with no app to ask, the call is handed to Cursor's own prompt, never left to run.
held_shell() { # conversation, command
  printf '{"conversation_id":"%s","hook_event_name":"beforeShellExecution","cursor_version":"e2e","workspace_roots":["%s"],"cwd":"%s","command":"%s"}' \
    "$1" "$WORK/loud-proj" "$WORK/loud-proj" "$2" | "$BIN" --hook --tool cursor
}
out="$(held_shell e2e-approve 'echo off')"
[ -z "$out" ] && echo "ok: with Require notch approval off the hook prints nothing" || { echo "FAIL: approval off printed: $out" >&2; exit 1; }
defaults write "$DOMAIN" cursorRequireApproval -bool true
# The shortest hold the setting allows, so the unanswered call below comes back inside the run.
defaults write "$DOMAIN" promptHoldSeconds -int 15
out="$(held_shell e2e-approve 'echo closed')"
[ "$out" = '{"permission":"ask"}' ] && echo "ok: with the app closed a held call is handed to Cursor's own prompt" \
  || { echo "FAIL: app closed printed: $out" >&2; exit 1; }
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

# Every assistant's task list (0.9.13), each through the hook command its installer writes.
hook() { # tool, payload[, event]
  if [ -n "${3:-}" ]; then printf '%s' "$2" | "$BIN" --hook --tool "$1" --event "$3" >/dev/null
  else printf '%s' "$2" | "$BIN" --hook --tool "$1" >/dev/null; fi
}
heard='o["event"] == "hook"'
hook codex '{"hook_event_name":"PostToolUse","session_id":"e2e-codex","cwd":"'"$WORK"'/loud-proj","model":"gpt-5.5","tool_name":"update_plan","tool_input":{"plan":[{"step":"Read","status":"completed"},{"step":"Draw","status":"in_progress"},{"step":"Ship","status":"pending"}]}}'
wait_for "Codex's plan reaches the row" "$heard and o.get(\"tool\") == \"codex\" and o.get(\"todos\") == {\"done\": 1, \"total\": 3}" 1 10
wait_for "and its model" "$heard and o.get(\"tool\") == \"codex\" and o.get(\"reportedModel\") == \"gpt-5.5\"" 1 5
hook gemini '{"hook_event_name":"AfterTool","session_id":"e2e-gemini","cwd":"'"$WORK"'/loud-proj","tool_name":"write_todos","tool_input":{"todos":[{"description":"a","status":"completed"},{"description":"b","status":"blocked"},{"description":"c","status":"cancelled"},{"description":"d","status":"pending"}]}}'
wait_for "Gemini's plan, a cancelled step out of the count" "$heard and o.get(\"tool\") == \"gemini\" and o.get(\"todos\") == {\"done\": 1, \"total\": 3}" 1 10
hook kimi '{"hook_event_name":"PostToolUse","session_id":"e2e-kimi","cwd":"'"$WORK"'/loud-proj","tool_name":"SetTodoList","tool_input":{"todos":[{"title":"a","status":"done"},{"title":"b","status":"in_progress"}]}}'
wait_for "Kimi's plan" "$heard and o.get(\"tool\") == \"kimi\" and o.get(\"todos\") == {\"done\": 1, \"total\": 2}" 1 10
hook copilot '{"sessionId":"e2e-copilot","timestamp":1,"cwd":"'"$WORK"'/loud-proj","toolName":"update_todo","toolArgs":{"todos":"- [x] a\n- [ ] b\n- [ ] c"}}' postToolUse
wait_for "Copilot's plan" "$heard and o.get(\"tool\") == \"copilot\" and o.get(\"todos\") == {\"done\": 1, \"total\": 3}" 1 10
hook opencode '{"hook_event_name":"todo.updated","session_id":"e2e-opencode","cwd":"'"$WORK"'/loud-proj","todos":[{"content":"a","status":"completed"},{"content":"b","status":"completed"},{"content":"c","status":"pending"}]}'
wait_for "OpenCode's plan" "$heard and o.get(\"tool\") == \"opencode\" and o.get(\"todos\") == {\"done\": 2, \"total\": 3}" 1 10

# Cursor's, from the conversation's transcript: a whole list, then a merge by id.
TRANSCRIPT="$CURSOR_PROJECT/agent-transcripts/e2e-cursor/e2e-cursor.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"
todo_line() { printf '{"role":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":%s}]}}\n' "$1" >>"$TRANSCRIPT"; }
cursor_event() { # event
  printf '{"conversation_id":"e2e-cursor","hook_event_name":"%s","cursor_version":"e2e","workspace_roots":["%s"],"transcript_path":"%s","model":"claude-opus-4-7"}' "$1" "$WORK/loud-proj" "$TRANSCRIPT" \
    | "$BIN" --hook --tool cursor --event "$1" >/dev/null
}
planned='o["event"] == "session" and o.get("action") == "plan" and o.get("session") == "e2e-cursor"'
todo_line '{"merge":false,"todos":[{"id":"1","content":"a","status":"in_progress"},{"id":"2","content":"b","status":"pending"},{"id":"3","content":"c","status":"pending"}]}'
cursor_event beforeSubmitPrompt
wait_for "Cursor's plan, read from its transcript" "$planned and o.get(\"todos\") == {\"done\": 0, \"total\": 3}" 1 10
todo_line '{"merge":true,"todos":[{"id":"1","status":"completed"},{"id":"3","status":"cancelled"}]}'
cursor_event afterAgentResponse
wait_for "and a merge by id, read from where the last read ended" "$planned and o.get(\"todos\") == {\"done\": 1, \"total\": 2}" 1 10

# Cursor's plan (0.9.15): on the row before it is built, then the plan file's statuses, a change to that file with no
# hook, and a Build.
PLAN_TRANSCRIPT="$CURSOR_PROJECT/agent-transcripts/e2e-plan/e2e-plan.jsonl"
mkdir -p "$(dirname "$PLAN_TRANSCRIPT")" "$(dirname "$CURSOR_PLAN")"
plan_event() { # event, extra JSON members
  printf '{"conversation_id":"e2e-plan","hook_event_name":"%s","cursor_version":"e2e","workspace_roots":["%s"],"transcript_path":"%s"%s}' \
    "$1" "$WORK/loud-proj" "$PLAN_TRANSCRIPT" "${2:-}" | "$BIN" --hook --tool cursor --event "$1" >/dev/null
}
plan_file() { # status of a, b, c
  printf -- '---\nname: notchmeter e2e %s\noverview: A plan the end-to-end run wrote.\ntodos:\n  - id: a\n    content: "One: first"\n    status: %s\n  - id: b\n    content: Second\n    status: %s\n  - id: c\n    content: Third\n    status: %s\nisProject: false\n---\n\n# E2E\n' \
    "$$" "$1" "$2" "$3" >"$CURSOR_PLAN"
}
its_plan='o["event"] == "session" and o.get("action") == "plan" and o.get("session") == "e2e-plan"'
printf '{"role":"assistant","message":{"content":[{"type":"tool_use","name":"CreatePlan","input":{"name":"notchmeter e2e %s","overview":"A plan the end-to-end run wrote.","todos":[{"id":"a","content":"One: first"},{"id":"b","content":"Second"},{"id":"c","content":"Third"}]}}]}}\n' "$$" >>"$PLAN_TRANSCRIPT"
plan_event beforeSubmitPrompt ',"composer_mode":"plan","prompt":"plan it"'
wait_for "Cursor's plan is on the row before it is built" "$its_plan and o.get(\"source\") == \"transcript\" and o.get(\"todos\") == {\"done\": 0, \"total\": 3}" 1 10
wait_for "and its mode is the prompt's" "$heard and o.get(\"session\") == \"e2e-plan\" and o.get(\"composerMode\") == \"plan\"" 1 5
plan_file completed pending pending
plan_event afterAgentResponse
wait_for "the plan file's statuses reach the row" "$its_plan and o.get(\"source\") == \"plan\" and o.get(\"todos\") == {\"done\": 1, \"total\": 3}" 1 10
plan_event stop ',"status":"completed"'
# The turn's last hook has been read before the file changes, so the read that sees the change is the app's own
# look at the file's date, not a hook's.
wait_for "the turn ended" "$heard and o.get(\"session\") == \"e2e-plan\" and o.get(\"name\") == \"Stop\"" 1 10
sleep 2
plan_file completed completed pending
wait_for "a plan file changed with no hook is read again" "$its_plan and o.get(\"todos\") == {\"done\": 2, \"total\": 3}" 1 15
plan_event beforeSubmitPrompt ',"composer_mode":"agent","prompt":"E2E\n\nImplement the plan as specified, it is attached for your reference. Do NOT edit the plan file itself."'
wait_for "a Build is a Build, in Agent mode" "$heard and o.get(\"session\") == \"e2e-plan\" and o.get(\"planBuild\") is True and o.get(\"composerMode\") == \"agent\"" 1 10

# *Require notch approval* with nobody at the notch: the call is held, the app's own hold runs out, and the hook
# hands the call to Cursor's own prompt. Nothing runs on silence.
cursor e2e-approve loud-proj beforeSubmitPrompt
held_shell e2e-approve 'echo held' >"$WORK/held.out" &
HELD_PID=$!
wait_for "a shell command is held for the notch" "$heard and o.get(\"session\") == \"e2e-approve\" and o.get(\"request\") == \"permission\"" 1 10
# The app's hold is 15 seconds; a hook still waiting well past it is a failure, not something to sit out.
for _ in $(seq 1 45); do kill -0 "$HELD_PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$HELD_PID" 2>/dev/null; then echo "FAIL: the held hook was still waiting 45 s on" >&2; exit 1; fi
wait "$HELD_PID" || true
HELD_PID=""
[ "$(cat "$WORK/held.out")" = '{"permission":"ask"}' ] && echo "ok: unanswered, the held call goes to Cursor's own prompt" \
  || { echo "FAIL: the unanswered call printed: $(cat "$WORK/held.out")" >&2; exit 1; }
wait_for "and the app says it passed it back" 'o["event"] == "decision" and o.get("session") == "cursor:e2e-approve" and o.get("behavior") == "pass"' 1 5

# A compaction another assistant reports, start and end.
hook codex '{"hook_event_name":"PreCompact","session_id":"e2e-codex","cwd":"'"$WORK"'/loud-proj","model":"gpt-5.5","trigger":"auto"}'
hook codex '{"hook_event_name":"PostCompact","session_id":"e2e-codex","cwd":"'"$WORK"'/loud-proj","model":"gpt-5.5","trigger":"auto"}'
wait_for "Codex's compaction starts and ends" "$heard and o.get(\"tool\") == \"codex\" and o.get(\"compaction\") == \"auto\"" 2 10

# A turn nobody typed: another agent's message is a turn, never a title.
printf '{"hook_event_name":"UserPromptSubmit","session_id":"e2e-claude","cwd":"%s","prompt":"<agent-message from=\\"e2e\\">done</agent-message>"}' "$WORK/loud-proj" \
  | "$BIN" --hook >/dev/null
wait_for "an agent's message is a turn nobody typed" "$heard and o.get(\"session\") == \"e2e-claude\" and o.get(\"harnessTurn\") is True" 1 10

kill -0 "$APP_PID" 2>/dev/null || { echo "FAIL: the app exited during the run" >&2; exit 1; }
echo "e2e: all checks passed"

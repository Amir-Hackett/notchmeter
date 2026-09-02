# Claude Code hook

Notchmeter polls each vendor's usage endpoint on a schedule ([README, "How often"](../README.md#how-often)). Claude Code can do better than a schedule: its hooks run a command of your choosing whenever a session starts, a turn ends, or Claude stops to ask you something. Wiring one hook line into `~/.claude/settings.json` gives the notch three things it cannot get by polling:

- **A refresh the moment a turn ends**, instead of up to three minutes later.
- **The right polling cadence.** A hook event is proof an agent is active, so the meter stays on its base interval while you work and backs off when you stop, even when the file check in [PollingPolicy.swift](../Sources/Notchmeter/PollingPolicy.swift) would lag.
- **A "waiting for you" badge.** When Claude Code raises a permission prompt or asks a question, a small white dot appears on the Claude ring beside the notch (with a count once more than one session waits) and the panel's Advice strip says *Claude Code is waiting in notchmeter (and 1 more)*, above everything else it has to say. It clears when that session's next turn starts, when its `Stop`, `SessionEnd` or an `agent_completed` / elicitation-answered notification arrives, or after ten minutes.
- **Session presence.** Each session is tracked by its id: started, working since its `UserPromptSubmit`, idle after its `Stop`, waiting. The Claude card says "2 sessions · working 2m 10s" and, with the hook installed and no session running, the rings stay quiet however full a window is, because nothing is being spent. Two optional notifications hang off this: when a session begins waiting for you, and when a turn longer than N minutes finishes, both silent while a terminal or editor is frontmost.

The hook is optional. Without it everything works; the meter simply learns about activity from file modification times once a minute.

## What the hook sends

The command is `Notchmeter --hook`. Claude Code pipes the event's JSON to it on standard input. The command reads `hook_event_name`, `notification_type` (for `Notification` events), `session_id` and `cwd`, and posts one `DistributedNotificationCenter` notification named `com.amirhackett.notchmeter.hook` whose payload is:

| Key | Value |
|---|---|
| `hook_event_name` | the event name, e.g. `Stop` |
| `needsInput` | `true` for `PermissionRequest`, `Elicitation`, and `Notification` with type `permission_prompt`, `idle_prompt`, `elicitation_dialog`, `elicitation_url_dialog` or `agent_needs_input`; `false` otherwise |
| `notification_type` | the `Notification` event's type, so `agent_completed`, `elicitation_complete` and `elicitation_response` can end a wait without a `Stop` |
| `session_id` | Claude Code's session id, the key of the per-session state |
| `project` | the last path component of `cwd` ("notchmeter"), never the path |

Nothing else leaves the payload: not the transcript path, the working directory beyond its basename, the prompt, the tool input or the notification text. The `quota_auto_resume_fired`, `quota_auto_resume_stale` and `quota_auto_resume_disabled` notification types (Claude Code's own quota wait) are passed through as plain activity today; they are a natural input for the wait-for-reset advice and are noted in the roadmap. The command prints nothing, so Claude Code sees no decision and proceeds as normal, and it exits 0 within 50 ms including launch: measured on an M5 Pro at 6 ms with a payload on a pipe or `/dev/null`, and 31 ms when standard input is a pipe nobody writes to, because the read gives up after 25 ms rather than block (an empty or absent payload is not an error). The first launch after a rebuild can take a couple of hundred milliseconds more while dyld warms its cache. It never touches the network or the Keychain. If Notchmeter is not running, the notification goes nowhere and nothing happens. The code is [Hook.swift](../Sources/Notchmeter/Hook.swift).

## Installing it

Open **Settings…** from the panel's Options menu and find the **Claude Code hook** section.

- **Show snippet…** shows the exact JSON for the running copy of Notchmeter, with a **Copy** button. Paste it into `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`), merging the `hooks` object with any you already have.
- **Add to settings.json…** does the merge for you, after asking. It first copies `settings.json` to `settings.json.bak-<yyyyMMdd-HHmmss>` beside it, then appends Notchmeter's entry under each event that lacks one. Hooks already in the file, their matchers and their order are kept; the file's permissions are preserved; nothing is written when every event already has the entry. If the file is not a JSON object it is left untouched and the button reports why.

The snippet, for an app in `/Applications`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook", "async": true, "timeout": 5 } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook", "async": true, "timeout": 5 } ] }
    ],
    "PermissionRequest": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook", "async": true, "timeout": 5 } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook", "async": true, "timeout": 5 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook", "async": true, "timeout": 5 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook", "async": true, "timeout": 5 } ] }
    ]
  }
}
```

The event names, the `hooks` layout and the `async` and `timeout` fields follow the [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) as of 2026-09-02, including the `elicitation_url_dialog` and `agent_completed` notification types. `async` lets Claude Code carry on without waiting for the command; `Stop`, `SessionEnd` and `UserPromptSubmit` take no matcher, and the others are left unmatched so the command itself decides what counts as waiting. Claude Code runs the command through `sh -c`, which is why the path is single-quoted.

The path in the snippet is the executable that is running when you open Settings. The section shows the state of the file: *Installed · pointing at /Applications/Notchmeter.app*, *Installed but points at an old path* (you moved the app, or ran it from `build/` and later installed it), or *Not installed*. **Repair** rewrites only Notchmeter's own entries to the running executable and adds any event that lacks one, after the same backup; every other hook is untouched. On the first launch, Settings opens once with the offer to add the hook; it is a button, never automatic, and the offer is not repeated.

## The status line

Claude Code's [status line](https://code.claude.com/docs/en/statusline) hands a command a JSON object after every turn (debounced 300 ms) with `context_window.used_percentage`, `rate_limits.five_hour` and `seven_day` (`used_percentage`, `resets_at`; Pro and Max plans, present once the first API response has arrived, either window possibly absent), `cost.total_cost_usd`, `model.display_name`, `session_id` and `cwd`. `Notchmeter --statusline` reads it, posts `com.amirhackett.notchmeter.statusline` with the context fill, the two windows, the cost, the model, the session id and the folder name, and then prints one line for Claude Code's own bar:

```
Opus · ctx 62% · 5h 45% ↻2h · 7d 13% ↻5d · $1.23
```

In the app: a thin arc around the Claude ring shows the context fill, the Claude card gains "Context 62% · Opus · $1.23 this session", the session and weekly meters carry the official figures with the note "From Claude Code's status line", and while a report is under three minutes old the Claude endpoint is not polled at all (the footer says so). That makes the status line a sanctioned, zero-network source for the two main windows, and the fallback if Anthropic answers the inquiry with a no.

**Install status line…** in Settings sets `statusLine` to Notchmeter's command after a backup. A status line you already had is not lost: it is chained with `--then '<your command>'`, so Notchmeter runs it with the same JSON on standard input and passes its output through, and Claude Code's bar shows your line. The snippet, for an app in `/Applications`:

```json
{
  "statusLine": { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --statusline", "padding": 0 }
}
```

The command never touches the network or the Keychain, forwards nothing but the fields above (never `transcript_path`, never `cwd` beyond its basename), and exits 0 whether or not the app is running.

## What the app does with an event

In [UsageStore.swift](../Sources/Notchmeter/UsageStore.swift), `hookReceived`:

1. Records Claude activity now, so the polling policy treats Claude as active for the next thirty minutes, and brings hidden rings back.
2. Feeds the per-session state machine (`SessionTracker.swift`): the card's session count and the waiting badge come from it, and the two session notifications fire from its transitions.
3. Refreshes the Claude reading immediately, at most once every 30 seconds however many events arrive; the loop's next scheduled read is recomputed from that refresh.

Each event is written to the unified log as `hook <event>`; nothing else about it is logged.

## Removing it

Delete the groups whose command contains `Notchmeter … --hook` from `~/.claude/settings.json`, and the `statusLine` entry (restoring the `--then` command as your own if you had one), or restore the `settings.json.bak-…` copy. Turning Claude off in Notchmeter's Settings, or quitting Notchmeter, also stops both from having any effect; the commands still run and exit at once.

## Troubleshooting

```bash
echo '{"hook_event_name":"Stop"}' | /Applications/Notchmeter.app/Contents/MacOS/Notchmeter --hook; echo "exit $?"
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.amirhackett.notchmeter" AND eventMessage BEGINSWITH "hook"' --style compact
```

The first line should print `exit 0` at once; the second should list `hook Stop` if Notchmeter was running. If it is missing, check that the path in `settings.json` is the copy of Notchmeter that is actually running, and that `disableAllHooks` is not set in your settings.

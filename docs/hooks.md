# Claude Code hook

Notchmeter polls each vendor's usage endpoint on a schedule ([README, "How often"](../README.md#how-often)). Claude Code can do better than a schedule: its hooks run a command of your choosing whenever a session starts, a turn ends, or Claude stops to ask you something. Wiring one hook line into `~/.claude/settings.json` gives the notch three things it cannot get by polling:

- **A refresh the moment a turn ends**, instead of up to three minutes later.
- **The right polling cadence.** A hook event is proof an agent is active, so the meter stays on its base interval while you work and backs off when you stop, even when the file check in [PollingPolicy.swift](../Sources/Notchmeter/PollingPolicy.swift) would lag.
- **A "waiting for you" badge.** When Claude Code raises a permission prompt or asks a question, a small white dot appears on the Claude ring beside the notch and the panel's Advice strip says *Claude Code is waiting for your input*, above everything else it has to say. It clears on the next `Stop`, `SessionEnd` or `UserPromptSubmit` event, or after ten minutes.

The hook is optional. Without it everything works; the meter simply learns about activity from file modification times once a minute.

## What the hook sends

The command is `Notchmeter --hook`. Claude Code pipes the event's JSON to it on standard input. The command reads two fields, `hook_event_name` and, for `Notification` events, `notification_type`, and posts one `DistributedNotificationCenter` notification named `com.amirhackett.notchmeter.hook` whose payload is:

| Key | Value |
|---|---|
| `hook_event_name` | the event name, e.g. `Stop` |
| `needsInput` | `true` for `PermissionRequest`, `Elicitation`, and `Notification` with type `permission_prompt`, `idle_prompt`, `elicitation_dialog` or `agent_needs_input`; `false` otherwise |

Nothing else leaves the payload: not the session id, the transcript path, the working directory, the prompt, the tool input or the notification text. The command prints nothing, so Claude Code sees no decision and proceeds as normal, and it exits 0 within 50 ms including launch: measured on an M5 Pro at 6 ms with a payload on a pipe or `/dev/null`, and 31 ms when standard input is a pipe nobody writes to, because the read gives up after 25 ms rather than block (an empty or absent payload is not an error). The first launch after a rebuild can take a couple of hundred milliseconds more while dyld warms its cache. It never touches the network or the Keychain. If Notchmeter is not running, the notification goes nowhere and nothing happens. The code is [Hook.swift](../Sources/Notchmeter/Hook.swift).

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

The event names, the `hooks` layout and the `async` and `timeout` fields follow the [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) as of 2026-09-01. `async` lets Claude Code carry on without waiting for the command; `Stop`, `SessionEnd` and `UserPromptSubmit` take no matcher, and the others are left unmatched so the command itself decides what counts as waiting. Claude Code runs the command through `sh -c`, which is why the path is single-quoted.

The path in the snippet is the executable that is running when you open Settings. If you move the app, or you ran it from `build/` and later install it to `/Applications`, run **Add to settings.json…** again: the merge only checks that some `Notchmeter … --hook` entry exists per event, so replace the old path by hand or remove the old groups first.

## What the app does with an event

In [UsageStore.swift](../Sources/Notchmeter/UsageStore.swift), `hookReceived`:

1. Records Claude activity now, so the polling policy treats Claude as active for the next thirty minutes.
2. Refreshes the Claude reading immediately, at most once every 30 seconds however many events arrive; the loop's next scheduled read is recomputed from that refresh.
3. Sets or clears the waiting badge as described above.

Each event is written to the unified log as `hook <event>`; nothing else about it is logged.

## Removing it

Delete the groups whose command contains `Notchmeter … --hook` from `~/.claude/settings.json`, or restore the `settings.json.bak-…` copy. Turning Claude off in Notchmeter's Settings, or quitting Notchmeter, also stops the hook from having any effect; the command still runs and exits at once.

## Troubleshooting

```bash
echo '{"hook_event_name":"Stop"}' | /Applications/Notchmeter.app/Contents/MacOS/Notchmeter --hook; echo "exit $?"
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.amirhackett.notchmeter" AND eventMessage BEGINSWITH "hook"' --style compact
```

The first line should print `exit 0` at once; the second should list `hook Stop` if Notchmeter was running. If it is missing, check that the path in `settings.json` is the copy of Notchmeter that is actually running, and that `disableAllHooks` is not set in your settings.

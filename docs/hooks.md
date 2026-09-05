# Hooks (Claude Code, Codex, Cursor, Gemini CLI, GitHub Copilot)

Notchmeter polls each vendor's usage endpoint on a schedule ([README, "Privacy and terms", *How often*](../README.md#privacy-and-terms)). Claude Code can do better than a schedule: its hooks run a command of your choosing whenever a session starts, a turn ends, or Claude stops to ask you something. Wiring one hook line into `~/.claude/settings.json` gives the notch three things it cannot get by polling. Codex, Cursor, Gemini CLI and GitHub Copilot CLI have hooks too, and the same command reads them; what each lights, and what it cannot, is under its own heading below ([Codex](#codex), [Cursor](#cursor), [Gemini CLI](#gemini-cli), [GitHub Copilot CLI](#github-copilot-cli)), in the rings' order. Everything up to there is Claude Code's hook:

- **A refresh the moment a turn ends**, instead of up to five minutes later.
- **The right polling cadence.** A hook event is proof an agent is active, so the meter stays on its base interval while you work and backs off when you stop, even when the file check in [PollingPolicy.swift](../Sources/Notchmeter/PollingPolicy.swift) would lag.
- **A "waiting for you" badge.** When Claude Code raises a permission prompt or asks a question, a small white dot appears on the Claude ring beside the notch (with a count once more than one session waits), the rings take the blue that means *needs you, not running out*, the card says *Waiting for your answer*, and the panel's Advice strip says *Claude Code is waiting in notchmeter (and 1 more)*, above everything else it has to say. It clears when that session's next turn starts, when its `Stop`, `SessionEnd` or an `agent_completed` / elicitation-answered notification arrives, when the session starts a subagent (Claude Code reports a permission prompt but never its answer, so a `SubagentStart` is the one sign the hook gives that the session is running again; a `SubagentStop` is not taken as one, because a background agent can finish while the main loop is still held at the prompt), or after ten minutes.
- **A "just finished" badge.** When a turn longer than twenty seconds ends, the same rings turn the same blue and carry a white disc with a tick in it, and the card says *Just finished*. It lets go after ninety seconds, or sooner: the moment the next prompt starts a turn, the moment any of that tool's sessions starts working again, or the moment you rest the pointer on the rings. It does not wait for the *Notify when a turn finishes* threshold, which is measured in minutes because a banner interrupts you and a ring does not. A window at 80 % or more keeps its own orange or vermillion on the cap at the arc's end throughout. Turning off *Colour the rings when an assistant waits or finishes* in Settings withdraws the colour and leaves both marks. The two states are drawn side by side in [`docs/media/signal-rings.png`](media/signal-rings.png), which is the README's picture of them.
- **Session presence.** Each session is tracked by its id: started, working since its `UserPromptSubmit`, idle after its `Stop`, waiting. The Claude card says "2 sessions · working 2m 10s" and, with the hook installed and no session running, the rings stay quiet however full a window is, because nothing is being spent. The waiting and just-finished colours on the rings come from it too. Two optional notifications hang off this: when a session begins waiting for you (time-sensitive, so it breaks through a Focus when the entitlement is signed in), and when a turn longer than N minutes finishes, both silent while a terminal or editor is frontmost, and both withdrawn from Notification Center again when the wait ends.
- **Subagents, the branch and the permission mode.** `SubagentStart` and `SubagentStop` count a session's running subagents (the card says "working · 2 agents"; one whose stop never arrives is dropped after ten minutes). The git branch of `cwd` rides along, read from `.git/HEAD` (a worktree's `gitdir:` file is followed) without running git, and so does Claude Code's `permission_mode`, so the card and the status line can say `notchmeter · main` and show a badge while a session runs with permissions bypassed.
- **Limit hits and quota waits.** A `StopFailure` whose failure is a rate limit marks the session as stopped at its limit: the Claude ring goes to the *Limit hit* stage at once instead of at the next poll, and the wait-for-reset advice names the reset. `quota_auto_resume_stale` and `quota_auto_resume_disabled` say Claude Code is parked on its quota without an automatic resume, which the card shows as waiting; `quota_auto_resume_fired` ends it the way a finished turn does.

Every hook is optional. Without one everything works; the meter simply learns about activity from file modification times once a minute.

## What the hook sends

The command is `Notchmeter --hook` for Claude Code, `--hook --tool codex` for Codex, `--hook --tool cursor` for Cursor, `--hook --tool antigravity` for Gemini CLI (it lights the Antigravity ring) and `--hook --tool copilot --event <name>` for Copilot CLI, whose payload does not name its event. The assistant pipes the event's JSON to it on standard input. For Claude Code the command reads `hook_event_name`, `notification_type` (for `Notification` events), `session_id` and `cwd` (the other assistants' fields are listed in their own sections, and land in the same keys), and posts one `DistributedNotificationCenter` notification named `com.amirhackett.notchmeter.hook` whose payload is:

| Key | Value |
|---|---|
| `hook_event_name` | the event name, e.g. `Stop` |
| `needsInput` | `true` for `PermissionRequest`, `Elicitation`, and `Notification` with type `permission_prompt`, `idle_prompt`, `elicitation_dialog`, `elicitation_url_dialog` or `agent_needs_input`; `false` otherwise. For Codex, `true` on `PermissionRequest` only; for Gemini CLI, on `Notification` with type `ToolPermission` only; for Copilot, on `Notification` with type `permission_prompt` or `elicitation_dialog` only; for Cursor, never |
| `notification_type` | the `Notification` event's type, so `agent_completed`, `elicitation_complete` and `elicitation_response` can end a wait without a `Stop`. Gemini CLI's and Copilot's hooks carry it only for a type that starts a wait (`ToolPermission`; `permission_prompt`, `elicitation_dialog`), so a Copilot `agent_completed`, which is about a background subagent, can never end a wait it does not answer; Codex has no `Notification` event |
| `session_id` | the assistant's session id (Codex's `session_id`, Cursor's `conversation_id`, Gemini CLI's `session_id`, Copilot's `sessionId`), the key of the per-session state |
| `project` | the last path component of `cwd` ("notchmeter"), never the path |
| `branch` | the branch named by `.git/HEAD` under `cwd` (following a worktree's `gitdir:` file); absent when there is none or HEAD is detached |
| `permission_mode` | Claude Code's or Codex's `permission_mode` field when the event carries one (the same five words: `default`, `acceptEdits`, `plan`, `dontAsk`, `bypassPermissions`); the other three assistants document none |
| `agent_id` | the subagent's id on `SubagentStart` and `SubagentStop` (Claude Code and Codex on both; Cursor on start only; Copilot on neither, so its agents are counted, not named) |
| `failure` | on `StopFailure`, the failure's kind (`rate_limit` marks a limit hit); never its message. For Cursor, an aborted or errored stop's `status` (`aborted`, `error`), which is never a rate limit. For Codex, `interrupted` when you interrupted the turn. Gemini CLI and Copilot never send a `StopFailure` |
| `host` | a label for the machine the event came from, only for events posted to the local API from another machine (below); absent for a local hook |
| `tool` | absent for Claude Code; `codex`, `cursor`, `antigravity` or `copilot` otherwise, so the payload of the hook that shipped first is byte for byte what it has always been |

Nothing else leaves the payload: not the transcript path, the working directory beyond its basename, the prompt, the tool input or the notification text. The command prints nothing, so the assistant sees no decision and proceeds as normal, and it exits 0 within 50 ms including launch: measured on an M5 Pro at 6 ms with a payload on a pipe or `/dev/null`, and 31 ms when standard input is a pipe nobody writes to, because the read gives up after 25 ms rather than block (an empty or absent payload is not an error). The first launch after a rebuild can take a couple of hundred milliseconds more while dyld warms its cache. It never touches the network or the Keychain. If Notchmeter is not running, the notification goes nowhere and nothing happens. The code is [Hook.swift](../Sources/Notchmeter/Hook.swift).

## Installing it

Open **Settings…** from the panel's Options menu and find the **Hooks** section. It has a row per assistant, in the rings' order; this is the Claude Code row, and the other four are described under their own headings.

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
    "StopFailure": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook", "async": true, "timeout": 5 } ] }
    ],
    "SubagentStart": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook", "async": true, "timeout": 5 } ] }
    ],
    "SubagentStop": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook", "async": true, "timeout": 5 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook", "async": true, "timeout": 5 } ] }
    ]
  }
}
```

The event names, the `hooks` layout and the `async` and `timeout` fields follow the [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) as of 2026-09-02, including the `elicitation_url_dialog` and `agent_completed` notification types. `async` lets Claude Code carry on without waiting for the command; `Stop`, `SessionEnd` and `UserPromptSubmit` take no matcher, and the others are left unmatched so the command itself decides what counts as waiting. Claude Code runs the command through `sh -c`, which is why the path is single-quoted.

The path in the snippet is the executable that is running when you open Settings. The row shows the state of the file: *Installed · pointing at /Applications/Notchmeter.app*, *Installed but points at an old path* (you moved the app, or ran it from `build/` and later installed it), *Installed, but an entry is out of date* (an event has no entry, or an entry's flags are not the current ones), or *Not installed*. An entry is judged on its path and its flag, not on matching the snippet byte for byte: one you wrote by hand at the right path with an unquoted path or a redirect after the flag counts as installed and is left alone. **Repair** rewrites only Notchmeter's own entries to the running executable and its current flags and adds any event that lacks one, after the same backup; every other hook is untouched. With *Repair a hook that points at an old copy at launch* on (Settings › Hooks, on by default) the running app does that repair itself at launch, for every assistant's file alike, whenever one of them names an old path or holds an entry that is out of date, after the same backup, except when it runs from a `build/` or `.build/` folder or under `--smoke` or the asset renderers, so a copy under development never rewrites the entry the installed copy uses; the repair is logged and reported to the oracle as `hookRepair`. On the first launch, Settings opens once with the offer to add the Claude Code hook; it is a button, never automatic, and the offer is not repeated. There is no such offer for the other assistants: the offer's text promises a dot while the assistant waits, which Cursor cannot deliver, and Codex, Gemini CLI and Copilot each want a step of their own after the file is written (trusting the entry, starting a new session, restarting the CLI), which a first-launch button cannot take for you. Their rows are a click away in the same section.

## Codex

Codex's [hooks](https://learn.chatgpt.com/docs/hooks) borrow Claude Code's vocabulary almost word for word: the same `hooks.json` layout, the same UpperCamel event names, `session_id` and `cwd` on every payload. The same `Notchmeter --hook` command reads them, carrying `--tool codex`, and that flag is doing more work here than for any other assistant, because a Codex payload is shaped exactly like a Claude Code one and nothing in it says which assistant sent it. With the entry in `hooks.json`, the Codex ring and card get nearly everything the Claude ring gets from its hook:

- **Presence and cadence.** A Codex event is proof Codex is active: the meter stays on its base interval while you work and backs off when you stop, and hidden rings come back.
- **Sessions.** Each thread is tracked by its id: started at `SessionStart`, working from `UserPromptSubmit`, idle after `Stop`, gone at `SessionEnd`. The Codex card carries the same sessions line as the Claude card ("2 sessions · working 2m 10s"), and, with the hook installed and no thread running, the Codex ring stays quiet however full a window is. Each hook speaks for its own ring only.
- **The waiting hand.** `PermissionRequest` is documented as running "when Codex is about to ask for approval, such as a shell escalation or managed-network approval" and not "for commands that don't need approval", so it is a documented wait, the same one Claude Code's event of the same name is: the white dot appears on the Codex ring, the rings take the blue that means *needs you, not running out*, the card says *Waiting for your answer*, the Advice strip says *Codex is waiting in proj*, and *Notify when an assistant waits for you* fires. Codex never reports the answer, so the hand lets go at the thread's next `UserPromptSubmit`, `Stop`, `Interrupt`, `SubagentStart` or `SessionEnd`, or after ten minutes.
- **The finished tick.** A `Stop` after a turn of twenty seconds or more gives the Codex ring the same blue and the same tick for ninety seconds, and the *Notify when a turn finishes* banner says *Codex finished a 10m turn in proj*. Codex's `Stop` carries no status field, so every `Stop` is a finish; an interrupted turn fires `Interrupt` instead (below).
- **Subagents.** `SubagentStart` and `SubagentStop` count a thread's running subagents on the card. Both carry `agent_id`, so the exact agent that stopped is the one dropped; `session_id` on both is the parent's, which Codex documents.
- **The permission mode.** `permission_mode` rides along with the same five words Claude Code uses (`default`, `acceptEdits`, `plan`, `dontAsk`, `bypassPermissions`), so the card and the status line show the same badge while a thread runs with permissions bypassed.
- **A refresh the moment a turn ends,** at most once every 30 seconds however many events arrive, the same rule as Claude's.
- **The project and its branch.** `cwd` is on every Codex payload, so the basename and the branch named by its `.git/HEAD` are always there.

**What Codex does not report.** The Codex ring never shows a limit hit or a quota wait from the hook: Codex's `Stop` has no failure kind, and no event fires for an errored turn or a rate limit, so a limit hit waits for the next poll of the meter, which is where the *Limit hit* stage comes from for Codex. It never shows a question, an idle prompt or an elicitation, because Codex has no `Notification` event and no elicitation event; MCP elicitation appears in its reference only as time that "doesn't count against the timeout". An `Interrupt`, documented "when you interrupt an active turn on the main thread", ends the turn without the tick and without a limit: it reads as `StopFailure` with `failure` `interrupted`, which is never a rate limit. And the hand can stay up when nobody was asked: another hook, a plugin's or Codex's auto-review path can answer a `PermissionRequest` before the prompt is drawn, and no hook reports that, so the hand stays until the next signal or ten minutes, the same exposure Claude Code's hook has. Nothing here asserts more than a documented signal proves.

**Trust, and when the file is read.** Codex requires you to review and trust "the exact hook definition" before a non-managed hook runs, and records that trust against the hook's hash: "new or changed hooks are marked for review and skipped until trusted". So an entry Notchmeter writes does nothing until you open `/hooks` inside Codex and trust it, and the row keeps saying *Installed* meanwhile, because the trust store is Codex's and not the file's. A **Repair** that re-points the command at a moved app changes the hash, so the repaired entry must be trusted again; the launch-time auto-repair is such a change, and the panel footer's *Hook repaired* is the cue. `hooks.json` is read when a session starts: a session already running keeps the hooks it started with. The note after Add and Repair says both things.

**The file and the snippet.** Codex discovers `hooks.json` beside `config.toml` in its home folder: `$CODEX_HOME` when set, else `~/.codex`, the only two places Codex documents and the two Notchmeter writes to. Nothing is written under `~/.config/codex`, which Codex does not read. Notchmeter never reads or writes `config.toml`: Codex documents `hooks.json` as a source equivalent to the inline `[hooks]` table, loads both, and "warns at startup" if a single layer has both, so a `[hooks]` table you already keep goes on working beside the file and the warning is Codex's way of telling you to keep one. The Codex row in Settings › Hooks has the same three parts as Claude Code's: **Show snippet…**, **Add to hooks.json…**, which merges after a `hooks.json.bak-<yyyyMMdd-HHmmss>` backup and keeps everything already there (the file's `description`, every foreign group and its `matcher`, `statusMessage` and `additionalContextLimit`, the order), and **Repair**. The snippet, for an app in `/Applications`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool codex", "async": true, "timeout": 5 } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool codex", "async": true, "timeout": 5 } ] }
    ],
    "PermissionRequest": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool codex", "timeout": 5 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool codex", "async": true, "timeout": 5 } ] }
    ],
    "Interrupt": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool codex", "timeout": 3 } ] }
    ],
    "SubagentStart": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool codex", "async": true, "timeout": 5 } ] }
    ],
    "SubagentStop": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool codex", "async": true, "timeout": 5 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool codex", "timeout": 3 } ] }
    ]
  }
}
```

The handlers differ per event on purpose. `SessionEnd` and `Interrupt` are synchronous with `"timeout": 3`: `SessionEnd` is documented as always synchronous ("`SessionEnd` hooks always run synchronously, even when `async` is `true`"), and `Interrupt` shares its one-second default and three-second cap ("`SessionEnd` and `Interrupt` use `1` second by default and support up to `3` seconds"), which is why both entries omit `async` and carry the cap. `PermissionRequest` is synchronous with `"timeout": 5`, because an asynchronous hook's output lands "at the next safe point", which is not documented to be before the prompt is drawn; the command prints nothing, so blocking costs the few milliseconds of its launch. Everything else is `"async": true, "timeout": 5`, seconds, as in Claude Code's snippet. Codex runs the string through `$SHELL -lc`, a login shell, so your profile runs before the command does; the single-quoted path is right in sh, bash, zsh and fish. Exit 0 with nothing on standard output is accepted on every event, including `Stop`, which otherwise "expects JSON on `stdout`".

**The eight events.** Only the events the session tracker can act on are registered; `PreToolUse`, `PostToolUse`, `PreCompact` and `PostCompact` would cost a process launch per tool call for nothing. Seven of the eight are Claude Code's names already; only `Interrupt` is renamed, and the unified log and the oracle carry the canonical name with `tool: codex` beside it:

| Codex event | Notchmeter reads it as | Effect |
|---|---|---|
| `SessionStart` (any `source`, `compact` included) | `SessionStart` | the thread is tracked, idle; a `compact` start is the same thread after compaction, and passes through because the tracker's `SessionStart` only touches the session's last event |
| `UserPromptSubmit` | `UserPromptSubmit`; `SubagentPromptSubmit` when it carries `agent_id` | working; the turn's clock starts. A submission carrying `agent_id` is a subagent's, on the parent's `session_id`, and passes through under its own name so it counts as activity without restarting the parent's clock or wiping its finished mark |
| `PermissionRequest` | `PermissionRequest`, `needsInput` true | waiting: the dot, the blue, *Waiting for your answer*, the notification |
| `Stop` | `Stop` | the turn finished: the tick after a turn of twenty seconds or more, held ninety seconds |
| `Interrupt` | `StopFailure` with `failure` `interrupted` | idle, subagents cleared, no tick, no limit |
| `SubagentStart` | `SubagentStart` | one more running subagent, keyed by `agent_id`; a session that starts one is no longer waiting |
| `SubagentStop` | `SubagentStop` | that subagent is dropped |
| `SessionEnd` | `SessionEnd` | the thread is dropped; Codex sends it when a conversation is archived or deleted, when Codex closes, or after the thread has been idle and open in no client for 30 minutes, and never after a crash, so the tracker's own expiry covers the rest |
| anything else Codex can send | passed through under its own name | nothing; it still counts as activity for the polling policy |

**What the command reads, and what it never reads.** From Codex's JSON the command keeps `hook_event_name`, `session_id`, the basename of `cwd` for `project` and that folder's `.git/HEAD` for `branch`, `permission_mode`, and `agent_id` on the subagent events and on `UserPromptSubmit`, where its presence marks a subagent's submission. It never reads `transcript_path`, `model`, `turn_id`, `prompt`, `last_assistant_message`, `stop_hook_active`, `tool_name`, `tool_input` or `source`. The Codex payload therefore carries no `notification_type` and no `host`, and `tool` is `codex`. The code is [Hook+Codex.swift](../Sources/Notchmeter/Hook+Codex.swift).

**`--tool codex`, and the import hazard.** A Codex payload is Claude-shaped, so without the flag, or a `"tool": "codex"` key, the command reads it as Claude Code's: same names, same fields, and a Codex `Stop` on a plain `--hook` lights the Claude ring. Codex's external-agent migration imports Claude Code's and Cursor's hook configs into Codex, and an imported Notchmeter entry runs exactly that plain `--hook`. The Codex row shows such an entry as *Installed, but an entry is out of date*, and **Repair** rewrites it to `--hook --tool codex` (after which Codex wants it trusted again); with auto-repair on, the first launch of an installed copy does that rewrite itself, after a `hooks.json.bak-<date>` backup.

**Around the app.** A Codex thread's id reads `codex:<session_id>` (and `codex:<session_id>@<host>` from another machine) in the `--json` and `/v1/limits` reports and in the identifiers of the notifications it raises, so a Codex thread and a Claude Code session with the same id can never share an entry. The session notifications name the assistant (*Codex is waiting in proj*, *Codex finished*), and stay quiet while a terminal is frontmost the way every session notification does.

## Cursor

Cursor's [hooks](https://cursor.com/docs/agent/hooks) run a command on the agent's events the way Claude Code's do, and the same `Notchmeter --hook` command reads them, carrying `--tool cursor` so the app knows the sender before it reads a byte of payload. With the entry in `~/.cursor/hooks.json`, the Cursor ring and card get most of what the Claude ring gets from its hook:

- **Presence and cadence.** A Cursor event is proof Cursor is active: the meter stays on its base interval while you work and backs off when you stop, and hidden rings come back.
- **Sessions.** Each conversation is tracked by its id: started at `sessionStart`, working from `beforeSubmitPrompt`, idle after `stop`, gone at `sessionEnd`. The Cursor card carries the same sessions line as the Claude card ("2 sessions · working 2m 10s"), and, with the hook installed and no conversation running, the Cursor ring stays quiet however full a window is. Each hook speaks for its own ring only: Cursor's reporting no conversation never quietens the Claude ring, whose hook may not be installed at all. The keep-awake assertion (*Keep the Mac awake while an assistant is working*) holds for a working Cursor turn too.
- **The finished tick.** A `stop` whose `status` is `completed`, after a turn longer than twenty seconds, gives the Cursor ring the same blue and the same tick for ninety seconds, and the *Notify when a turn finishes* banner says *Cursor finished a 10m turn in proj*.
- **Subagents.** `subagentStart` and `subagentStop` count a conversation's running subagents on the card.
- **A refresh the moment a turn ends.** Cursor's meter is re-read at once, at most once every 30 seconds however many events arrive, the same rule as Claude's.
- **The project and its branch.** The first workspace root's basename and the branch named by its `.git/HEAD`, so the card and the notifications can say `notchmeter · main`.

**What Cursor does not report.** The Cursor ring never shows the waiting hand, never a permission badge, never a limit hit and never a quota wait, because Cursor documents no event for any of them: its Claude-compatibility page marks `Notification` and `PermissionRequest` as not supported, and the events that fire before a shell command or a tool call (`beforeShellExecution`, `preToolUse`) fire whether or not you will be asked, so a hand lit on them would be false most of the time. Nothing here asserts more than a documented signal proves ([`ToolSignal.swift`](../Sources/Notchmeter/ToolSignal.swift)). Three consequences: *Notify when an assistant waits for you* never fires for Cursor, because only an assistant with a documented wait event can say so (Claude Code, Codex, Gemini CLI and Copilot have one; Cursor does not); a `stop` whose `status` is `aborted`, `error`, anything else, or absent ends the turn without the tick and without a limit (a `stop` with no status is not a finish); and the subagent count is approximate, because `subagentStop` carries no id, so the oldest running subagent is the one dropped.

**The file and the snippet.** Cursor's user-level hooks live in `~/.cursor/hooks.json` (no environment override is documented, so none is honoured). The Cursor row in Settings › Hooks has the same three parts as Claude Code's: **Show snippet…**, **Add to hooks.json…**, which merges after the same `hooks.json.bak-<yyyyMMdd-HHmmss>` backup, keeps every entry already there (a `matcher`, a `timeout`, a `loop_limit`, a `failClosed`, a `type: "prompt"` entry, an event whose value is not an array), writes `"version": 1` only when the file has no version, and never overwrites one it has, and **Repair**. The snippet, for an app in `/Applications`:

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [ { "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool cursor" } ],
    "beforeSubmitPrompt": [ { "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool cursor" } ],
    "stop": [ { "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool cursor" } ],
    "subagentStart": [ { "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool cursor" } ],
    "subagentStop": [ { "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool cursor" } ],
    "sessionEnd": [ { "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool cursor" } ]
  }
}
```

The file **Add** writes is the same object with its keys sorted, so `"hooks"` comes before `"version"` on disk; Cursor does not mind. Each entry deliberately carries nothing but `command`: no `timeout` (Cursor's default is its platform default, and the command exits within 50 ms), no `failClosed` (it must stay false: the command prints nothing, and under `failClosed` no output counts as a failure that would stop the agent), no `loop_limit` (the command never emits a `followup_message`) and no `matcher`. Cursor reloads `hooks.json` as soon as it is saved, so a new entry takes effect without a restart. A project-level `.cursor/hooks.json` runs additively beside the user-level file; Notchmeter neither reads nor writes those.

**The six events.** Only the events the session tracker can act on are registered; the rest of Cursor's vocabulary (shell, MCP and file events) would cost a process launch per tool call for nothing. The command puts each name onto Claude Code's, so the tracker needs no second grammar, and that is the name the unified log and the oracle carry, with `tool: cursor` beside it:

| Cursor event | Notchmeter reads it as | Effect |
|---|---|---|
| `sessionStart` | `SessionStart` | the conversation is tracked, idle |
| `beforeSubmitPrompt` | `UserPromptSubmit` | working; the turn's clock starts |
| `stop` with `"status": "completed"` | `Stop` | the turn finished: the tick after a turn of twenty seconds or more, held ninety seconds |
| `stop` with any other status, or none | `StopFailure` (with `failure` = the status, when there is one) | idle, subagents cleared, no tick, no limit |
| `sessionEnd` | `SessionEnd` | the conversation is dropped |
| `subagentStart` | `SubagentStart` | one more running subagent, keyed by `subagent_id`, on the conversation `parent_conversation_id` names |
| `subagentStop` | `SubagentStop` | the oldest running subagent is dropped (the payload carries no id) |
| anything else Cursor can send | passed through under its own name | nothing; it still counts as activity for the polling policy |

`stop` is taken to fire when the agent loop ends for one message, which is what Cursor documents; if it fired once per conversation the tick would come late, and nothing else would change. A turn is a turn: a local background agent's conversation is tracked like any other.

**What the command reads, and what it never reads.** From Cursor's JSON the command keeps `hook_event_name`, `status` (on `stop`), `conversation_id` (falling back to `session_id`, which `sessionStart` documents as the same value; on `subagentStart`, `parent_conversation_id` outranks both, so a subagent counts under the conversation that started it rather than opening one of its own) for the session id, the basename of the first non-empty entry of `workspace_roots` (else `cwd`, which Cursor sends on tool events only, else the `CURSOR_PROJECT_DIR` it gives its hook processes) for `project`, that folder's `.git/HEAD` for `branch`, and `subagent_id` on `subagentStart`. It never reads the prompt, the attachments, the transcript path, `user_email`, the model fields, `generation_id`, `loop_count`, `duration_ms`, `reason`, `is_background_agent`, the agent's text, or `cursor_version` beyond noticing it exists; `composer_mode` is not mapped onto the permission badge, whose vocabulary is Claude Code's. The Cursor payload therefore carries no `notification_type`, `permission_mode` or `host`, and `needsInput` is always `false`. The code is [Hook+Cursor.swift](../Sources/Notchmeter/Hook+Cursor.swift).

**`--tool cursor`, and the fallback.** The flag is what the installer writes, and it settles the sender before any parsing. An entry that runs plain `--hook` still works: a payload carrying `conversation_id` or `cursor_version`, or naming any event in Cursor's reference, is recognised as Cursor's by its shape, since Claude Code sends none of those. The row shows such an entry as *Installed, but an entry is out of date*, and **Repair** rewrites it to `--hook --tool cursor`. With auto-repair on, the first launch of an installed copy does that rewrite itself, once, after a `hooks.json.bak-<date>` backup, and the panel footer says *Hook repaired*; the same launch repair covers a `hooks.json` that names an old path of the app. Running the command by hand with neither the flag nor a Cursor-shaped payload reads it as Claude Code's, which is what a Claude payload is.

**Cursor's third-party configs.** With *Include third-party Plugins, Skills, and other configs* on, Cursor also runs the hooks in `~/.claude/settings.json`, so a Mac with both entries installed sends each Cursor event twice: once under Cursor's name from `hooks.json` and once under Claude Code's name from `settings.json`. The second carries `conversation_id`, so the shape rule tags it Cursor's as well, and its `Stop` obeys `status` like a lowercase `stop` would; the same conversation id keeps both one session. Two things show. A doubled `UserPromptSubmit` resets the turn's clock by a few milliseconds, which is harmless (the second `Stop` finds no turn running and finishes nothing). A doubled `SubagentStop` is not: `subagentStop` carries no id, so each copy drops the oldest running subagent, and the card's agent count under-reports while both entries run. If you keep the third-party setting on, remove Notchmeter's entry from one of the two files. The Cursor ring is never lit by a Claude event this way, and the Claude ring never by a Cursor one.

**Around the app.** A Cursor session's id reads `cursor:<conversation_id>` (and `cursor:<conversation_id>@<host>` from another machine) in the `--json` and `/v1/limits` reports and in the identifiers of the notifications it raises, so a Cursor conversation and a Claude Code session with the same id can never share an entry; Claude Code's ids stay the bare ids they have always been. The session notifications name the assistant (*Cursor finished*), and, since Cursor's bundle id is on the list of terminals and editors the notifier stays quiet for, a Mac with Cursor frontmost suppresses its own banners the way it does for a terminal.

## Gemini CLI

Gemini CLI's [hooks](https://geminicli.com/docs/hooks/reference/) run a command on the agent's events the way Claude Code's do, from the `hooks` object of `~/.gemini/settings.json`, and the same `Notchmeter --hook` command reads them, carrying `--tool antigravity`. The flag names the ring rather than the product: Gemini CLI and Antigravity meter against one Google quota, so they share one ring in the notch, and it is Gemini CLI's hook that lights it, because the Antigravity IDE's own hooks report none of what the notch needs (the last paragraph of this section). The row in Settings is titled *Gemini CLI hook*. With the entry in place, the Antigravity ring and card get:

- **Presence and cadence.** A Gemini CLI event is proof the tool is active: the meter stays on its base interval while you work and backs off when you stop, and hidden rings come back.
- **Sessions.** Each session is tracked by its id: started at `SessionStart`, working from `BeforeAgent`, which Gemini documents as firing "after a user submits a prompt, but before the agent begins planning", idle after `AfterAgent`, gone at `SessionEnd`. The card carries the sessions line, and, with the hook installed and no session running, the ring stays quiet however full a window is. `/clear` ends one session and starts another: Gemini issues a new id between the `SessionEnd` (reason `clear`) and the `SessionStart` (source `clear`), both documented, so the card's count is right through it.
- **The waiting hand.** Gemini CLI's `Notification` event with `notification_type` `ToolPermission` is documented as firing "when the CLI emits a system alert (for example, Tool Permissions)" and as "observability only: this hook cannot block alerts or grant permissions automatically", so it is a documented wait and the one this hook has: the dot appears on the Antigravity ring, the rings take the blue, the card says *Waiting for your answer*, the Advice strip says *Antigravity is waiting in proj*, and *Notify when an assistant waits for you* fires. Nothing reports the answer, so an approved prompt keeps the hand up until the turn ends (`AfterAgent`), the next prompt is sent (`BeforeAgent`), the session ends, or ten minutes pass.
- **The finished tick.** `AfterAgent`, documented as firing "once per turn after the model generates its final response", after a turn of twenty seconds or more, gives the ring the same blue and the same tick for ninety seconds, and the *Notify when a turn finishes* banner names the ring (*Antigravity finished a 10m turn in proj*).
- **A refresh the moment a turn ends,** at most once every 30 seconds however many events arrive.
- **The project and its branch.** The basename of `cwd`, else of the `GEMINI_CWD` or `GEMINI_PROJECT_DIR` Gemini gives its hook processes, and that folder's `.git/HEAD`. Never `CLAUDE_PROJECT_DIR`, which Gemini also sets "for compatibility" and Claude Code sets for real.

**What Gemini CLI does not report.** No subagents, no permission mode, no limit hit and no quota wait: Gemini CLI documents no event, field or notification type for any of them, so the ring shows none from the hook (a limit hit still comes from the meter's own reading). No cancelled or errored turn: whether `AfterAgent` fires for one is undocumented, so no `StopFailure` is ever emitted for Gemini, and a cancelled turn stays *working* until the next signal or the tracker's expiry. `ToolPermission` is the only notification type Gemini documents; a `Notification` of any other type is passed through with no type and neither starts nor ends a wait. And the same caveat as Claude Code's and Codex's permission prompts: nothing reports the answer, so an approved prompt keeps the hand up until the turn ends or ten minutes pass, and the help text says so.

**The file and the snippet.** Gemini CLI's user-level hooks live in the `hooks` object of `~/.gemini/settings.json`; `GEMINI_CLI_HOME` moves the folder that `.gemini` is appended to, and Notchmeter honours it. The row has the same three parts as Claude Code's: **Show snippet…**, **Add to settings.json…**, which merges after a `settings.json.bak-<yyyyMMdd-HHmmss>` backup and keeps every other setting in the file (the theme, `mcpServers`, `hooksConfig`, every hook group already there with its `matcher`, `name`, `description`, `sequential` or `env`), and **Repair**. One refusal is deliberate: if `settings.json` is not strict JSON, because it carries comments Gemini may tolerate, the file is left exactly as it is, the row reads *Not installed*, and Add reports why; paste the snippet in by hand in that case, because a merge written through a JSON serialiser would strip the comments. The snippet, for an app in `/Applications`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "name": "notchmeter", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool antigravity", "timeout": 5000 } ] }
    ],
    "BeforeAgent": [
      { "hooks": [ { "type": "command", "name": "notchmeter", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool antigravity", "timeout": 5000 } ] }
    ],
    "AfterAgent": [
      { "hooks": [ { "type": "command", "name": "notchmeter", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool antigravity", "timeout": 5000 } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "name": "notchmeter", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool antigravity", "timeout": 5000 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "name": "notchmeter", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool antigravity", "timeout": 5000 } ] }
    ]
  }
}
```

Three things differ from Claude Code's entry, each because Gemini's reference does: `timeout` is in **milliseconds** (default 60 000), so it reads `5000`; there is no `async` field, because none exists ("Gemini CLI waits for all matching hooks to complete before continuing"), which is why the command's 50 ms exit matters more here; and `name` is written, because Gemini uses it in its hook panel and its `hooksConfig.disabled` list. No `matcher` is written: on lifecycle events Gemini's matchers are exact strings on `source`, `reason` or `notification_type`, and omitting one receives every occurrence, which is what the wait rule needs. Exit 0 with nothing on standard output is the documented way to "take no action" ("silence is mandatory"). Gemini CLI reads `settings.json` when it starts, so the hook works from the next session; the note after Add and Repair says so.

**The five events.** Gemini's tool, model and compression events (`BeforeTool`, `AfterTool`, `BeforeModel`, `AfterModel`, `BeforeToolSelection`, `PreCompress`) are not registered; `AfterModel` in particular fires for every chunk the model generates. The command puts each name onto Claude Code's:

| Gemini CLI event | Notchmeter reads it as | Effect |
|---|---|---|
| `SessionStart` (source `startup`, `resume` or `clear`) | `SessionStart` | the session is tracked, idle |
| `BeforeAgent` | `UserPromptSubmit` | working; the turn's clock starts (once per prompt) |
| `AfterAgent` | `Stop` | the turn finished: the tick after a turn of twenty seconds or more, held ninety seconds |
| `Notification` with `"notification_type": "ToolPermission"` | `Notification`, `needsInput` true, type `ToolPermission` | waiting: the dot, the blue, *Waiting for your answer*, the notification |
| `Notification` with any other type | `Notification`, no type | nothing; neither starts nor ends a wait |
| `SessionEnd` (any `reason`) | `SessionEnd` | the session is dropped |
| anything else Gemini can send | passed through under its own name | nothing; it still counts as activity for the polling policy |

**What the command reads, and what it never reads.** From Gemini's JSON the command keeps `hook_event_name`, `session_id` (else the `GEMINI_SESSION_ID` in its environment), `cwd` (else `GEMINI_CWD`, else `GEMINI_PROJECT_DIR`) for the basename and the branch, and `notification_type`. It never reads `transcript_path`, `timestamp`, `prompt`, `prompt_response`, `stop_hook_active`, `message`, `details` (the alert's tool name and file path live there), `reason`, `trigger` or `source`. The payload therefore carries no `permission_mode`, `agent_id`, `failure` or `host`, and `tool` is `antigravity`. The code is [Hook+Gemini.swift](../Sources/Notchmeter/Hook+Gemini.swift).

**`--tool antigravity`, and the fallback.** The flag is what the installer writes. An entry that runs plain `--hook` is still recognised as Gemini's when the payload names an event only Gemini sends (`BeforeAgent`, `AfterAgent`, `BeforeModel`, `AfterModel`, `BeforeToolSelection`, `BeforeTool`, `AfterTool`, `PreCompress`), when `GEMINI_SESSION_ID` is in the hook's environment, or when a `Notification` carries type `ToolPermission`; a bare `SessionStart` or `SessionEnd` with none of those reads as Claude Code's, which is what the flag is for. The row shows such an entry as *Installed, but an entry is out of date*, and **Repair** adds the flag.

**Around the app.** A Gemini CLI session's id reads `antigravity:<session_id>` in the reports and notification identifiers. The session notifications name the ring, *Antigravity*, because the ring is shared and that is its name in the notch; the Settings row and the alerts about the file say *Gemini CLI*, because that is whose file it is.

**The Antigravity IDE.** The IDE has a hooks file of its own, `~/.gemini/config/hooks.json` (or `.agents/hooks.json` in a workspace), with its own shape, and Notchmeter registers nothing there, by decision. Its reference documents `PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation` and `Stop` only: no session start or end, no prompt submission, no notification or permission event, camelCase payloads without `cwd` or an event name, and no exit-code contract. A `Stop` alone cannot drive the finished tick, because the tracker measures a turn from its `UserPromptSubmit`; a `PreToolUse` on `ask_question` proves a tool is about to run, not that you are being waited on, since the same page lets a hook's `decision` auto-allow it. So the Antigravity ring never reacts to the IDE, and the row's help says so. Revisit when Google documents a prompt-submit or a wait event.

## GitHub Copilot CLI

GitHub Copilot CLI's [hooks](https://docs.github.com/en/copilot/reference/hooks-reference) run a command on the agent's events, from JSON files in `~/.copilot/hooks/`, and the same `Notchmeter --hook` command reads them, carrying `--tool copilot` and, alone among the assistants, `--event <name>`. The second flag exists because Copilot's camelCase payloads carry no event name: a `sessionStart` and an `agentStop` arrive as `{ "sessionId", "timestamp", "cwd", … }` and nothing in the JSON says which, so each entry in the file names the event it was registered under, and the command takes the name from the command line. Copilot also accepts PascalCase registrations ("VS Code compatible"), whose payloads carry `hook_event_name` and snake_case fields, and the command reads those too, with the payload's own name outranking the argument, but `subagentStart` and `notification` exist only in camelCase, so registering the PascalCase names would lose the subagent count and the wait. With the file in place, the Copilot ring and card get:

- **Presence and cadence.** A Copilot event is proof Copilot is active: the meter stays on its base interval while you work and backs off when you stop, and hidden rings come back.
- **Sessions.** Each session is tracked by its id: started at `sessionStart`, working from `userPromptSubmitted`, idle after `agentStop`, gone at `sessionEnd`. The Copilot card carries the sessions line, and, with the hook installed and no session running, the Copilot ring stays quiet however full a window is.
- **The waiting hand.** Copilot's `notification` event carries a `notification_type`, and two of its documented types are the agent asking you: `permission_prompt`, "the agent requests permission to execute a tool" (since Copilot CLI 1.0.26 it fires only when a prompt is actually shown), and `elicitation_dialog`, "the agent requests additional information from the user". Both are documented waits: the dot appears on the Copilot ring, the rings take the blue, the card says *Waiting for your answer*, the Advice strip says *GitHub Copilot is waiting in proj*, and *Notify when an assistant waits for you* fires. Nothing reports the answer, so the hand lets go at the session's next `userPromptSubmitted`, `agentStop`, `subagentStart` or `sessionEnd`, or after ten minutes.
- **The finished tick.** An `agentStop`, "the main agent finishes a turn", after a turn of twenty seconds or more, gives the Copilot ring the same blue and the same tick for ninety seconds, and the *Notify when a turn finishes* banner says *GitHub Copilot finished a 10m turn in proj*. Its `stopReason` is documented as always `end_turn`, so every `agentStop` is a finish.
- **Subagents.** `subagentStart` and `subagentStop` count a session's running subagents on the card, approximately: `subagentStart` carries no agent id, so the oldest running subagent is the one dropped at each stop, as with Cursor. Copilot documents that its built-in general-purpose agent emits neither event; the other built-in agents and custom agents do.
- **A refresh the moment a turn ends,** at most once every 30 seconds however many events arrive.
- **The project and its branch.** `cwd` is on every Copilot payload, so the basename and the branch named by its `.git/HEAD` are always there.

**What Copilot does not report.** No limit hit and no quota wait: no Copilot hook payload carries a rate-limit or quota field, and `agentStop` has no failing variant, so the ring never shows a limit from the hook and never a `StopFailure`; `errorOccurred` fires mid-turn for recoverable errors as well as fatal ones (`recoverable` is a documented field) and is passed through under its own name, lighting nothing. No permission mode. `permissionRequest` is not a wait: it "fires before the permission service runs, before rule checks, session approvals, auto-allow/auto-deny, and user prompting", so it fires for calls that never prompt, and a hand lit on it would be false most of the time; it passes through under its own name. The other four notification types, `shell_completed`, `shell_detached_completed`, `agent_completed` and `agent_idle`, are about background shells and background subagents and neither start nor end a wait; the entry's `matcher` keeps them from launching the command at all, and if one arrives anyway it carries no type and does nothing.

**The file and the snippet.** Copilot CLI loads every `*.json` file in its user-level hooks directory, `~/.copilot/hooks/` (or `$COPILOT_HOME/hooks/`), and combines them, so Notchmeter owns a file of its own there, `notchmeter.json`, and never merges into anyone else's: **Add to notchmeter.json…** creates the folder if it is missing and writes the file (after a `notchmeter.json.bak-<yyyyMMdd-HHmmss>` backup when one exists), **Repair** rewrites only the commands in it, and removing the hook is deleting the file. The row's status is usually *Not installed* until the first Add, because the file does not exist before it. The snippet, for an app in `/Applications`:

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool copilot --event sessionStart", "timeoutSec": 5 } ],
    "userPromptSubmitted": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool copilot --event userPromptSubmitted", "timeoutSec": 5 } ],
    "agentStop": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool copilot --event agentStop", "timeoutSec": 5 } ],
    "subagentStart": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool copilot --event subagentStart", "timeoutSec": 5 } ],
    "subagentStop": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool copilot --event subagentStop", "timeoutSec": 5 } ],
    "notification": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool copilot --event notification", "matcher": "permission_prompt|elicitation_dialog", "timeoutSec": 5 } ],
    "sessionEnd": [ { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool copilot --event sessionEnd", "timeoutSec": 5 } ]
  }
}
```

`command` is the documented cross-platform key ("copied to both bash and powershell when those fields are absent"), so on a Mac it runs as the bash entry; the shell-free `exec` and `args` form was considered and not used, because VS Code cannot run it and it would need a second way of recognising Notchmeter's own entries. `timeoutSec` is Copilot's word (`timeout` is an alias) and defaults to 30; five is generous for a command that exits in 50 ms. There is no `async` field, because none exists: every event but `notification` runs synchronously and fail-open ("timeouts are fail-open for every event"; only `preToolUse`, which is not registered, is fail-closed), and `notification` is documented as fire-and-forget. The `notification` entry's `matcher` is an anchored regular expression on `notification_type`, so only the two waiting types launch the command. Exit 0 with nothing on standard output is documented as "take no action". Copilot CLI reads its hook files when it starts, so after Add or Repair restart it; `/env` inside Copilot then lists the hook files it loaded, with their paths, which is the check that the file was seen. The note after Add and Repair says so.

Two other Copilot surfaces are worth knowing about. Copilot's cloud coding agent runs hooks only from `.github/hooks/*.json` inside its Linux sandbox and "does not ship with user-level hook files", so this file never reaches it, and nothing Notchmeter does can. VS Code's Copilot agent mode reads Claude Code's `~/.claude/settings.json` as one of its hook sources, in PascalCase with `session_id` and `hook_event_name`; a Mac with the Claude Code hook installed therefore counts VS Code's Copilot sessions on the Claude ring, and no documented marker in the payload tells them apart. Whether VS Code also loads `~/.copilot/hooks` is contradictory in its own documentation; if it does, it sends PascalCase names with `hook_event_name`, which this parser reads correctly, and the `--event` argument is simply outranked.

**The seven events.** Copilot's tool events (`preToolUse`, `postToolUse`, `postToolUseFailure`), `userPromptTransformed`, `preCompact`, `permissionRequest` and `errorOccurred` are not registered. The command puts each name onto Claude Code's, accepting both spellings:

| Copilot event | Notchmeter reads it as | Effect |
|---|---|---|
| `sessionStart` / `SessionStart` | `SessionStart` | the session is tracked, idle; `source` (`startup`, `resume`, `new`) is not read |
| `userPromptSubmitted` / `UserPromptSubmit` | `UserPromptSubmit` | working; the turn's clock starts |
| `agentStop` / `Stop` | `Stop` | the turn finished: the tick after a turn of twenty seconds or more, held ninety seconds |
| `subagentStart` | `SubagentStart` | one more running subagent, counted (no id on start); a session that starts one is no longer waiting |
| `subagentStop` / `SubagentStop` | `SubagentStop` | the oldest running subagent is dropped |
| `notification` with type `permission_prompt` or `elicitation_dialog` | `Notification`, `needsInput` true, the type | waiting: the dot, the blue, *Waiting for your answer*, the notification |
| `notification` with any other type | `Notification`, no type | nothing; neither starts nor ends a wait (the matcher keeps these from arriving) |
| `sessionEnd` / `SessionEnd` (any `reason`) | `SessionEnd` | the session is dropped; in `-p` mode Copilot documents it firing once per turn, which is harmless |
| anything else Copilot can send | passed through under its own name | nothing; it still counts as activity for the polling policy |

**What the command reads, and what it never reads.** From Copilot's JSON the command keeps `sessionId` (else `session_id`; on subagent events it is taken to be the parent session's, since no parent field is documented), the basename of `cwd` for `project` and that folder's `.git/HEAD` for `branch`, and `notification_type`. It never reads `timestamp`, `transcriptPath`, `prompt`, `stopReason`, `stop_hook_active`, `response`, `agentId`, `agentName`, `agentType`, `title`, `message`, `traceparent`, `reason` or `source`. The payload therefore carries no `permission_mode`, `agent_id`, `failure` or `host`, and `tool` is `copilot`. The code is [Hook+Copilot.swift](../Sources/Notchmeter/Hook+Copilot.swift).

**`--tool copilot --event <name>`, and the fallback.** Both flags are what the installer writes. A payload with a camelCase `sessionId` is recognised as Copilot's by its shape even on a plain `--hook`, since no other assistant sends that key and it is checked before Cursor's names are; so is one naming an event only Copilot documents (`userPromptSubmitted`, `userPromptTransformed`, `agentStop`, `permissionRequest`, `errorOccurred`, `notification`). The eight camelCase names Copilot shares with Cursor (`sessionStart`, `sessionEnd`, `subagentStart`, `subagentStop`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `preCompact`) settle nothing on their own: without `sessionId` or the `tool` key, a payload under one of them reads as Cursor's. But a camelCase payload with no `hook_event_name` and no `--event` names no event at all, so the command posts nothing; the row shows an entry without `--event`, or with another event's, as *Installed, but an entry is out of date*, and **Repair** rewrites it to the current form.

**Around the app.** A Copilot session's id reads `copilot:<sessionId>` in the reports and notification identifiers. The session notifications name the assistant (*GitHub Copilot is waiting in proj*, *GitHub Copilot finished*).

## The status line

Claude Code's [status line](https://code.claude.com/docs/en/statusline) hands a command a JSON object after every turn (debounced 300 ms) with `context_window.used_percentage`, `rate_limits.five_hour`, `seven_day` and `spend_limit` (`used_percentage`, `resets_at`; Pro and Max plans, present once the first API response has arrived, any window possibly absent; the spend limit is extra usage against its cap and may pass 100 %), `cost.total_cost_usd`, `model.display_name`, `effort`, `session_id`, `cwd` and the git branch and pull request when Claude Code knows them. `Notchmeter --statusline` reads it, posts `com.amirhackett.notchmeter.statusline` with the context fill and size, the windows, the cost, the model and effort, the session id, the folder name, and the git branch and pull-request URL when Claude Code sends them, and then prints one line for Claude Code's own bar, coloured by pace where the bar allows ANSI:

```text
Opus high · ctx 62% · 5h 45% ↻2h · 7d 13% ↻5d · $1.23 · today $12 · block $3.10 ↻2h
```

The model's effort level follows its name; the today and block figures come from the running app's report file (`~/Library/Application Support/Notchmeter/report-v1.json`, rewritten every 30 seconds) when it is fresh, so the status line never prices transcripts itself. In the app: a thin arc around the Claude ring shows the context fill, the Claude card gains "Context 62% · Opus · $1.23 this session", the session, weekly and spend-limit meters carry the official figures with the note "From Claude Code's status line" (and "over by 30%" past the cap), and while a report is under three minutes old the Claude endpoint is not polled at all (the footer says so). That makes the status line a sanctioned, zero-network source for the two main windows, and the fallback if Anthropic answers the inquiry with a no.

**Install status line…** in Settings sets `statusLine` to Notchmeter's command after a backup. A status line you already had is not lost: it is chained with `--then '<your command>'`, so Notchmeter runs it with the same JSON on standard input and passes its output through, and Claude Code's bar shows your line. The snippet, for an app in `/Applications`:

```json
{
  "statusLine": { "type": "command", "command": "'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --statusline", "padding": 0 }
}
```

The command never touches the network or the Keychain, forwards nothing but the fields above (never `transcript_path`, never `cwd` beyond its basename), and exits 0 whether or not the app is running.

## Hooks from another machine

An assistant on another machine (a Linux box over SSH, a container) can reach the notch through the local API. Turn *Local API* on in Settings (it listens on 127.0.0.1 only), open a reverse tunnel from the remote machine, and give its Claude Code a hook that posts each event to the tunnel with a label for the machine:

```bash
ssh -R 6737:127.0.0.1:6737 host
```

```json
{ "type": "command", "command": "jq -c '. + {host: \"devbox\"}' | curl -s -X POST http://127.0.0.1:6737/v1/hook -d @-", "async": true, "timeout": 5 }
```

`POST /v1/hook` takes the same JSON Claude Code hands the hook and keeps the same fields (plus `host`, and a `branch` the remote side may add, since the app cannot read the remote `.git/HEAD`); it answers 202 and feeds the session tracker exactly as a local event would, with the session shown as `<project> @ devbox`. A remote payload is tagged by a `"tool": "<id>"` key (`codex`, `cursor`, `antigravity`, `copilot`) the remote side adds the way it adds `host`; Cursor's and Gemini CLI's payloads are also recognised by their shape without it, and Copilot's by its camelCase `sessionId` or a name only Copilot documents (a `sessionStart` or `subagentStart` with neither reads as Cursor's), while Codex's is Claude-shaped and needs the key; a remote Copilot post must also carry `hook_event_name` (or use the PascalCase names), since there is no `--event` argument on a POST. The session reads `<tool>:<id>@devbox`, `cursor:<conversation_id>@devbox` for one. Remote events count as activity for the polling policy and the waiting badge; they never carry a transcript path or the prompt.

## What the app does with an event

In [UsageStore.swift](../Sources/Notchmeter/UsageStore.swift), `hookReceived`:

1. Records the sending tool's activity now (whichever assistant sent it), so the polling policy treats that tool as active for the next thirty minutes, and brings hidden rings back.
2. Feeds the per-session state machine (`SessionTracker.swift`): the card's session count, its subagents, the branch, the permission badge, the waiting badge, the ninety-second finished colour and the limit-hit and quota-wait states come from it, and the session notifications fire from its transitions. While *Keep the Mac awake while an assistant is working* is on, a working session of any assistant holds a power assertion that lapses with the session (and, unless allowed, on battery).
3. Refreshes the sending tool's meter immediately, at most once every 30 seconds per tool however many events arrive; the loop's next scheduled read is recomputed from that refresh.

Each event is written to the unified log as `hook <event>`, with ` (<tool>)` after the name when it is not Claude Code's (`hook Stop (codex)`, `hook Stop (cursor)`, `hook Stop (antigravity)`, `hook Stop (copilot)`); nothing else about it is logged.

## Removing it

Delete the groups whose command contains `Notchmeter … --hook` from `~/.claude/settings.json`, and the `statusLine` entry (restoring the `--then` command as your own if you had one), or restore the `settings.json.bak-…` copy; for Codex, delete the groups whose command contains `--hook --tool codex` from `hooks.json` in its home folder, or restore the `hooks.json.bak-…` copy (Codex drops the trust record with the entry); for Cursor, delete the entries whose command contains `Notchmeter … --hook --tool cursor` from `~/.cursor/hooks.json`, or restore the `hooks.json.bak-…` copy; for Gemini CLI, delete the groups whose command contains `--hook --tool antigravity` from the `hooks` object of `~/.gemini/settings.json`, or restore the `settings.json.bak-…` copy; for Copilot CLI, delete `~/.copilot/hooks/notchmeter.json`, which is Notchmeter's own file, and restart Copilot. Turning the assistant off in Notchmeter's Settings, or quitting Notchmeter, also stops its hook from having any effect; the commands still run and exit at once.

## Troubleshooting

```bash
echo '{"hook_event_name":"Stop"}' | /Applications/Notchmeter.app/Contents/MacOS/Notchmeter --hook; echo "exit $?"
echo '{"hook_event_name":"Stop","session_id":"s","cwd":"/tmp"}' | /Applications/Notchmeter.app/Contents/MacOS/Notchmeter --hook --tool codex; echo "exit $?"
echo '{"hook_event_name":"stop","status":"completed","conversation_id":"c","workspace_roots":["/tmp"]}' | /Applications/Notchmeter.app/Contents/MacOS/Notchmeter --hook --tool cursor; echo "exit $?"
echo '{"hook_event_name":"AfterAgent","session_id":"s","cwd":"/tmp"}' | /Applications/Notchmeter.app/Contents/MacOS/Notchmeter --hook --tool antigravity; echo "exit $?"
echo '{"sessionId":"s","cwd":"/tmp","stopReason":"end_turn"}' | /Applications/Notchmeter.app/Contents/MacOS/Notchmeter --hook --tool copilot --event agentStop; echo "exit $?"
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.amirhackett.notchmeter" AND eventMessage BEGINSWITH "hook"' --style compact
```

The first five lines should each print `exit 0` at once; the last should list `hook Stop`, `hook Stop (codex)`, `hook Stop (cursor)`, `hook Stop (antigravity)` and `hook Stop (copilot)`, one per echo, if Notchmeter was running. If one is missing, check that the path in the assistant's file is the copy of Notchmeter that is actually running (Settings › Hooks says so per row), and, for Claude Code, that `disableAllHooks` is not set in your settings. When the log shows the echo but never a real event, the cause is usually the assistant's side of the contract:

- **Codex**: the row says *Installed* but nothing arrives. Open `/hooks` inside Codex and trust the entry; Codex skips a new or changed hook until you do, and prints a warning at startup saying so. A session that was already running when the file changed keeps its old hooks: start a new one. `codex --dangerously-bypass-hook-trust` runs untrusted hooks for one invocation, which is a way to test, not a way to live.
- **Cursor**: its own Hooks output channel (Output › Hooks) shows every command it ran and what it read back, which is where to look when the entry is in the file and the log stays empty.
- **Gemini CLI**: `settings.json` is read when Gemini starts, so the hook works from the next session, not the one that was open when you pressed Add. If the row says *Not installed* after an Add that reported the file is not a JSON object, the file has comments in it: paste the snippet in by hand. `/hooks` inside Gemini lists the hooks it loaded.
- **Copilot CLI**: hook files are read when Copilot starts, so restart it, then run `/env` inside Copilot, which lists the hook files it loaded with their paths; `~/.copilot/hooks/notchmeter.json` should be among them. An entry whose command lacks `--event` posts nothing, and the row shows it as out of date: Repair fixes it. VS Code's Copilot sessions land on the Claude ring, through `~/.claude/settings.json`, by VS Code's own design.
- **The Antigravity IDE**: never reacts, by design; only Gemini CLI documents the events the notch needs.

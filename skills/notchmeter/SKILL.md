---
name: notchmeter
description: Read this Mac's AI usage windows (Claude Code session/weekly/per-model, Codex, Cursor, Gemini CLI, Copilot), the local cost estimate and Notchmeter's advice before long work, so Claude can switch models or wait for a reset on its own. Use when the user asks how much quota is left, whether a long task fits before a reset, or when a task will run for more than a few minutes.
---

# Notchmeter

Notchmeter is a macOS app that shows AI coding-tool usage beside the MacBook notch. It also answers from the terminal, in JSON, without the app running and without a Keychain prompt. Use it before starting anything that will take a while, and whenever the user asks about their limits.

## When to use

- Before a long task (a large refactor, a migration, a research pass): check the Claude session and weekly windows and the advice line, and say what you found in one sentence.
- When the user asks "how much do I have left", "will this fit before the reset", "which model should I use", or "what has today cost".
- When a task is running out of quota: the advice names the tool or model with room and when the window resets.

## The command

```bash
/Applications/Notchmeter.app/Contents/MacOS/Notchmeter --probe --no-prompt --json
```

If the app is built from source instead, the path is `build/Notchmeter.app/Contents/MacOS/Notchmeter` inside the repository, or `swift run Notchmeter --probe --no-prompt --json` there. `--no-prompt` matters: without it a locked Keychain item raises a dialog. The command makes one read-only request per signed-in tool, prices the local Claude Code transcripts, and prints one JSON object (schema `notchmeter.limits.v1`) with sorted keys. It never prints a token.

The exit code summarises the picture: `0` fine, `10` a window is at 80 % or behind pace, `11` a window is at 100 %, `20` readings exist but nothing has been used, `30` no reading at all (nothing signed in, or the Keychain item is locked).

## Reading the output

- `tools[]`: one entry per tool. `status` is `ready`, `needsAttention` (the tool needs the user: sign in, allow the Keychain), `failed`, `offline` or `notInstalled`. `windows[]` carry `id` (`five_hour`, `seven_day`, `scoped_fable`…), `usedFraction` (0…1, or null for a window with no limit), `resetsAt` (ISO 8601), `pace` (`ahead`, `onTrack`, `behind`), `projectedFraction` (where an even burn lands at the reset), `model` for a per-model window, and `drainLastHour` when the app's log has the last hour's move.
- `cost`: the Claude Code estimate at API list prices (`today`, `yesterday`, `week` since the weekly window started, `month`, `last30Days`, `last90Days`, `lastHour`, `burnMultiple`, the current `block`, and `ranges` with per-model and per-project splits). It is not a bill; on a subscription it is the API-equivalent value of the work.
- `advice[]`: the prescriptive lines the app shows, highest priority first. Read them out as they are; they are worded as instructions ("Opus weekly is 91%. Sonnet is 34%. Switch models, not tools.").

## How to act on it

- A per-model window near 85 % with another model under 60 %: propose switching models for the task, not tools.
- A window `behind` pace with a run-out line in `advice`: say when it runs out and how long before the reset; offer to defer the heavy part.
- A window at 100 % that resets within the hour: wait rather than switch (the advice says so when nothing else has room).
- `exitCode` 30 or a `needsAttention` status: tell the user the meter cannot see that tool and why (the `problem` field), and do not guess.

## Example

```
User: This is going to be a long refactor across 40 files. Do I have the room for it today?

Claude: Checking the meter first.
$ /Applications/Notchmeter.app/Contents/MacOS/Notchmeter --probe --no-prompt --json
(exit 10)

Claude session is 61% used with 3h 50m left and behind pace (it drained 12% → 61% in the last hour); the weekly is at 13%.
Notchmeter's advice: "At this rate you hit the Claude session cap today at 1:20 PM, 2h 40m before reset." Fable weekly is 6%.
I would do the mechanical file moves now on Sonnet, which is the cheaper model and has room, and leave the design
review for after the session resets at 4:10 PM. Want me to proceed that way?
```

## Notes

- The Claude session and weekly figures are account-wide; the cost is this Mac's transcripts only.
- With the app running and the local API enabled in its Settings, the same JSON is at `http://127.0.0.1:6737/v1/limits` without a new read.
- Rules and divergences of the cost estimate: `docs/accuracy.md` in the repository.

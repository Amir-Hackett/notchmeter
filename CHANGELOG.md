# Changelog

Every released version of Notchmeter, newest first. From 0.7.0 each section is that version's release notes, the same text the update alert and the GitHub release carry, copied from [`docs/release-notes/`](docs/release-notes); write a new version's notes there first and add them here. Earlier versions had no notes file, so each has one line taken from the commits its tag points at, and the GitHub release page has the rest.

## [0.8.0](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.8.0) — 2026-09-24

### A simpler panel

- The panel now opens on a **Simple** layout: one row per assistant with its most urgent figure, cost on one line, and your sessions below, all on one surface. Click any row for everything behind it: every window, its pace and reset, where the figure came from, and the spend. The previous panel is still there as **Detailed** in Settings › Appearance › Panel layout.
- A header replaces the footer: the session count and when the next update is, with buttons for the Usage Dashboard, Settings and Options.
- Warnings sit on the row they are about instead of in a separate strip.

### Sessions, front and centre

- Sessions are grouped by project, with the branch and terminal on a second line.
- The session that needs you is highlighted.
- Each session shows its context fill when Claude Code's status line reports one.
- A chip lists the subagents running under a session.
- A session's task list shows as done/total, and opens to the checklist. It follows Claude Code's task tools, and Notchmeter's hook now also listens for them, so Repair (or the automatic repair at launch) adds one entry to your Claude Code settings.
- When no session is running, the card says so instead of disappearing.

### News in the notch

- When a session needs you or finishes, the notch briefly widens to say so ("notchmeter · Needs approval", "Finished") with a soft glow underneath. Hover or click opens the panel on that session. Both can be turned off in Settings, and the glow holds still under Reduce Motion.
- Optional assistant symbols inside the compact rings, for anyone who finds the colours hard to tell apart.

### Answering from the notch

- **Allow always**: when Claude Code suggests a rule, you can allow the request and add the rule in one step.
- Separate sounds for a permission request, a question and a plan ready for review.

### Also

- A short guided tour on first launch, and again from Settings.
- While your screen is shared, advice lines no longer show money or other figures.
- Cursor's Cost line no longer reports an unreadable export when you simply haven't used Cursor in the last 30 days.

## [0.7.9](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.7.9) — 2026-09-24

### Five more languages

- Notchmeter now speaks German, French, Spanish, Brazilian Portuguese and Russian, for eleven languages in all. Pick one under Settings › General › Language, or let it follow your Mac. These five were drafted without a native speaker; corrections are welcome as issues.

### Claude reads from Claude Code first

- When Claude Code's status line is installed and current, the session and weekly figures come from it and Claude's usage endpoint is not called on the timer. The endpoint is read only for what the status line doesn't carry (per-model weekly limits and extra-usage spend), at most every half hour and right after one of those resets, or when you press Refresh.

### Smaller updates

- Updates now download as a delta of about 1 MB instead of the full 11 MB app when you're on one of the last three versions. This starts with the next update after 0.7.9.

### Crash reports, kept on your Mac

- Settings › Advanced › Diagnostics shows the date of Notchmeter's last crash report, with **Copy crash report** (your home folder replaced by `~`) and **Show in Finder**. Nothing is sent anywhere.

### Fixes

- The Claude Code plugin's `get_limits` tool now works. Started as `notchmeter --mcp` through the command-line link, the app used to print its report and exit instead of starting the MCP server.
- A Cursor hook that sends an empty working folder now falls back to Cursor's own project folder.

### Also

- Notchmeter now needs macOS 15 Sequoia or later. Macs on macOS 14 stay on 0.7.8.
- The README is now a short page; everything it used to hold lives under `docs/`, alongside a new CHANGELOG, CONTRIBUTING guide and code of conduct.

## [0.7.8](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.7.8) — 2026-09-24

### A Sessions card that tidies itself

- An idle session that hasn't done anything for 30 minutes now drops off the list on its own, where before it stayed for up to four hours. If it does anything again, it comes straight back as it was.
- **Clear** in the Sessions header removes every idle and finished session in one click. Sessions that are working or waiting on you stay.
- Clearer status: a working session's dot pulses (it holds still under Reduce Motion), and an idle one is drawn dimmer with a dotted ring and reads "idle 12m", meaning how long it has been quiet rather than how old the session is.
- Sessions waiting on you are listed first, then working ones, then ones that just finished, then idle ones, so a pile of idle terminals can't push a working session off the card.
- A session removed from the list no longer comes back blank when Claude Code redraws its status line.

## [0.7.7](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.7.7) — 2026-09-21

### Remove a session from the list

- Hover a row in the Sessions card and click the ✕ where its time was, or right-click it for **Remove from the list**, to take it off the card. A conversation you closed in Cursor never tells Notchmeter it ended, so until now it stayed listed for hours.
- A removed session leaves the counts and the rings too. If it does anything again (a new prompt, a finished turn, any activity), it comes straight back as it was, so removing a session that's still working loses nothing.
- **Remove all idle sessions** in the same right-click menu clears every session that isn't working or waiting.
- A session holding a permission request or a question can't be removed: answer its card instead.

## [0.7.6](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.7.6) — 2026-09-21

### Cursor: a turn that may be waiting on you

- Cursor doesn't tell any other app when it stops to ask you to approve a command, so until now Notchmeter never knew. Now, when a Cursor turn goes 45 seconds without a sign of life and has no command running, Notchmeter treats it as a possible wait. You get **Cursor may be waiting**: the hand on the ring, the waiting notification (even with Cursor in front) and your glance card. It comes once per turn, and the next sign of life clears it, so approving the command withdraws the notification.
- It says "may" because a long model step with nothing running looks the same from outside. A command that's running, however long, never triggers it.
- To see signs of life, Notchmeter now also registers Cursor's shell, MCP, file-edit and agent-response hooks. The launch repair adds them to your `~/.cursor/hooks.json` by itself. They print nothing, so Cursor behaves exactly as before.

## [0.7.5](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.7.5) — 2026-09-21

### A glance is a card now

- **Glance** no longer opens the whole panel. When an assistant waits for you or a turn finishes, a glance opens one small card for that session: what happened, the notification's sentence, the prompt's first line, and **Jump to the terminal**. It settles by itself after a few seconds.
- 0.7.4's separate *Show a card* choice is folded into it. If you picked it, you are on Glance now and nothing changes for you. The choices are Do nothing, Glance (a card for a few seconds) and Open the panel.

### Fixes

- **Light appearance is readable.** On macOS 26, with Appearance set to Light, the card the panel opens in on an edge or top bar drew white text on light glass. Its glass is dark in every appearance now; the pill beside it still follows the setting.
- **The Accessibility repair alert no longer freezes the app.** While *Notchmeter's Accessibility permission belongs to an older copy* was on screen, hook events queued behind it. That included permission requests, which sat unanswered in the notch until the alert was dismissed. The alert is an ordinary window now: everything keeps working while it is up, and its buttons do what they did.

## [0.7.4](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.7.4) — 2026-09-21

### A card, not the whole panel

- *When an assistant waits for you, or a turn finishes* has a new choice: **Show a card (closes by itself)**. The notch opens on one small card for that session, the way a permission request opens on its own: the assistant, whether it is waiting or done, the same sentence the notification uses ("Claude Code finished a 12m turn in notchmeter"), the prompt's first line when titles are on, and a **Jump to the terminal** button when there is somewhere to jump to.
- The card settles by itself after a few seconds, like a glance, and stays while the pointer is on it. *Show the whole panel* under it opens everything else.
- A panel that is already open is left alone: the session's row and the advice line already say it there. A permission request or a question outranks the card.
- While the screen is shared the project and the prompt's line stay off the card, as they do in the notification.

## [0.7.3](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.7.3) — 2026-09-21

### All models, one pick away

- The ring pickers offer **All models** whenever an assistant reports two or more model meters with figures, whether or not those rows are showing on the card. Cursor hides its Cursor models and Other models rows by default when its included total is metered, so the one choice that covers both used to sit two Hide boxes away.
- Choosing All models shows the rows it combines, so the ring and the card always describe the same figures.
- Where both model meters are dead (a seat whose Cursor models and Other models read 0% however much it spends), there is nothing to combine and All models is not offered. Today's spend already counts every model on such a seat.

## [0.7.2](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.7.2) — 2026-09-21

### Clicking a session takes you to it

- A click on a Cursor or VS Code session in the Sessions card brings forward the window that session runs in, even with several windows open. Before, it only asked the app to come forward, which macOS often ignored and which could never pick a window.
- A session in Cursor's Agents window brings that window forward. Cursor offers no way for another app to open one particular local conversation in it, so the click stops at the window.
- For a terminal where Notchmeter can't select the session's tab, the click still brings the terminal forward, the way clicking its Dock icon does.
- A Cursor session running in Cursor shows one "Cursor" chip, not two.

### Behind it

- The hook sends the session's folder to the app only when the session runs in Cursor or VS Code, since that folder is what tells their windows apart. It stays on your Mac: never on a remote post, and never in the report, the local API or the log. docs/hooks.md lists it.
- The README's pictures render the same at any hour: the fixtures no longer pick up peak hours from the wall clock.

## [0.7.1](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.7.1) — 2026-09-20

### The icon

- Notchmeter has a Liquid Glass icon on macOS 26 and later: the same dark tile, notch and terracotta ring, now with the depth and the lighting Tahoe gives an icon, and a tinted variant for the appearances that ask for one. Every earlier macOS shows the icon it always showed.
- The website's mark is that icon too, rendered the way your Mac draws it rather than drawn flat.

Nothing else changed: 0.7.1 is 0.7.0 with the icon.

## [0.7.0](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.7.0) — 2026-09-20

Sparkle shows this file in the update alert, and the GitHub release page carries it too. Headings, paragraphs, lists, block quotes and code render there; tables and images do not.

### Answer Claude Code from the notch

- A permission request or a multiple-choice question from Claude Code (and a permission request from Codex or Copilot CLI) opens beside the notch as a card on its own, not the whole panel: **Allow** (⌘Y), **Deny** (⌘N), or the option you pick (⌘1…⌘9), *Answer in the terminal* to hand it back, and *Show the whole panel* for the rest. The card stays up while you read it, even if you click into the terminal; the terminal shows its own prompt meanwhile, so whichever you answer first wins. Once answered, the panel closes again. A request nobody answers falls back to the terminal's own prompt, as if the notch were not there.
- A **Sessions** card lists every running session with what it is working on (the prompt's first line, or the name Claude Code's status line carries before a prompt is sent), the terminal it runs in and how long the turn has taken; click a row to jump to that terminal window, tab or pane (iTerm2, Terminal, Ghostty, Warp, WezTerm, kitty and tmux are addressed directly; anything else is brought to the front).
- Each part has its own switch under Settings › Assistants › Sessions, and `docs/hooks.md` says exactly what the hook now sends: a prompt's first line as the session's title, a tool's name and a bounded summary of its input (never the raw input), a question's text and options, and the terminal's own identifiers. None of it reaches the log, the report file, the local API or `--json`.
- Claude Code's hook needs re-installing once for this: the Hooks row in Settings offers **Repair**.

### Sharper figures

- The run-out phrase names both days when a window crosses midnight; the headroom suffix is said once per strip and only for a paid plan; a `/limit-reset` reminder when the 5-hour window is spent and the week has room; a tokenizer caveat when a model-routing line compares models on different sides of the Claude 4.7 boundary.
- Prompt-cache diagnostics from the status line: misses, rewritten tokens and their cause on the Cost card, an advice line when they mount, and a `promptCache` object in `--json`.
- Cursor reads the current period's included spend from the dashboard's own endpoint, so an Enterprise on-demand seat meters what it really has; Copilot's credits join the Cost card; Antigravity tries the quota summary first and the two Code Assist hosts in turn.
- *Also poll Claude's usage endpoint* in Settings: off, the status line is the only Claude source and no request goes to Anthropic.

### The panel and Settings

- The first ring's figure sits beside the rings in the compact strip; tools with nothing to show are hidden until you add one; Settings has a search field and a Diagnostics group; the version moved from the panel footer to Settings › About; the terracotta accent replaces system blue; a first-launch Welcome window explains what is read and which permissions are asked for and why.

### Release

- Release notes ride in the appcast, so the update alert shows them; the Liquid Glass icon for macOS 26 when the build has Xcode 26's tools; a Claude Code plugin (`/plugin marketplace add Amir-Hackett/notchmeter`, then `/plugin install notchmeter@notchmeter`) that packages the skill and the MCP server.

## [0.6.1](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.6.1) — 2026-09-20

- Let a Cursor meter that reads 0 % behind Today's spend yield the rings to it.

## [0.6.0](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.6.0) — 2026-09-19

- The 0.5.0 follow-ups.

## [0.5.0](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.5.0) — 2026-09-19

- Audit fix batch.

## [0.4.7](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.4.7) — 2026-09-18

- Make the panel's quiet lines and a full share readable.

## [0.4.6](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.4.6) — 2026-09-18

- Stop calling a usual day a cap.

## [0.4.5](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.4.5) — 2026-09-18

- Give a Cursor seat with no included allowance a ring that moves.

## [0.4.4](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.4.4) — 2026-09-18

- Give the inner rings a colour of their own.

## [0.4.3](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.4.3) — 2026-09-18

- Every assistant keeps its windows across a limit reset: Cursor's new Enterprise summary, the Settings ring pickers, Claude's status line after a reset, Codex's snapshot fallback and Copilot Free.

## [0.4.2](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.4.2) — 2026-09-17

- The Cost card no longer grows past the panel's right edge when the range changes, and the panel's own SwiftUI controls no longer swallow their first click.

## [0.4.1](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.4.1) — 2026-09-14

- Give the usage dashboard a tab in Settings, and draw a nearly-full ring solid again.

## [0.4.0](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.4.0) — 2026-09-14

- Add a usage dashboard, and keep full rings in their assistant's colour.

## [0.3.0](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.3.0) — 2026-09-08

- Give Settings a sidebar instead of thirteen stacked sections.

## [0.2.4](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.2.4) — 2026-09-06

- Tell you when a session is blocked, whatever is in front, and ration the waiting banner to one a session every ten minutes.

## [0.2.3](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.2.3) — 2026-09-05

- Keep the app's own windows out from under the panel, and repair a stale Accessibility grant.

## [0.2.2](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.2.2) — 2026-09-05

- The first build whose entitlement is actually granted.

## [0.2.1](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.2.1) — 2026-09-05

- Stop claiming an entitlement macOS will not let the app launch with.

## [0.2.0](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.2.0) — 2026-09-05

- Let the readouts stay over a full-screen app, per app and on the spot.

## [0.1.0](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.1.0) — 2026-09-05

- The first release.

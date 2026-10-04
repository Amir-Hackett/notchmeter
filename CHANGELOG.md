# Changelog

Every released version of Notchmeter, newest first. From 0.7.0 each section is that version's release notes, the same text the update alert and the GitHub release carry, copied from [`docs/release-notes/`](docs/release-notes); write a new version's notes there first and add them here. Earlier versions had no notes file, so each has one line taken from the commits its tag points at, and the GitHub release page has the rest.

## [0.9.15](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.15) — 2026-10-03

### Cursor in the notch

Cursor's hooks report less than the other assistants': no task list, no plan, and no event that says it is waiting for you. This release reads the rest from Cursor itself.

- A Cursor plan shows on its chat's row when Cursor creates it, before it is built: its to-dos, **View Plan**, which opens the plan in Cursor, and **Build**. The to-dos are crossed off as Cursor finishes them, and one you tick in Cursor's plan editor is crossed off too.
- The turn that builds a plan is named for it, "Build: <plan>", not for the sentence Cursor submits.
- A Cursor row shows the chat's mode (Plan, Ask, Debug and the rest) as of its latest prompt, and a Background chip for a background agent.
- The compaction notice quotes the fill Cursor reports.

### Answering Cursor from the notch

Two switches on Cursor's page in Settings, both off until you turn them on:

- *Require notch approval for every command*: every shell command and MCP call Cursor runs waits for Allow or Deny on the session's row. *Answer in Cursor* hands one back to Cursor's own prompt, and so does a call nobody answers: Notchmeter never allows a call you did not answer.
- *Mirror Cursor's cards*: Cursor's own Run prompt (Skip, Run) and its switch-to-Plan-Mode card (Skip, Switch) appear on the row with Cursor's button labels, the Run card headed by the command it would run, and the one you pick is pressed in Cursor. With it on, the row's Build presses Build on the plan's card; without it, Build opens the plan in Cursor. It needs the Accessibility permission, re-reads the card before each press, and presses nothing if the card changed.
- Cursor's windows are read while a Cursor chat is in a turn and when you press Build, never while every chat is idle. While *Mirror Cursor's cards* is on, Cursor's editor shows Screen Reader Optimized unless `editor.accessibilitySupport` is off in Cursor's settings.

### Numbers

- Cursor's usage events are read defensively: a count that is negative, fractional, not a number or too large to hold is dropped instead of crashing the read, an amount is read only where the text holds one well-formed number, and an event dated outside 2020 to 2100 is skipped.

### Diagnostics

- The report has a `cursor:` line: the installed Cursor version, and for sessions, plans, run approval, mode switch, Build and View Plan, where each comes from on this Mac (the hook, Cursor's own files, Accessibility, or only opening Cursor).

### Fixes

- The offer that opens once after an update says "Updated to Notchmeter 0.9.15", not "New in": the usage card it offers has been there since 0.9.0.

## [0.9.14](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.14) — 2026-10-03

### The news across the notch

- A session that ends right after its turn keeps its name in the news. A `claude -p` run, or an agent that starts one every few minutes, used to be named by the temporary folder it ran in, often just "T"; it is now named by its prompt.
- A prompt that opens on a line of punctuation alone, such as a lone "-", is titled from the first line with words on it.
- The words fade where they stand before the strip goes back to its readouts, rather than passing across the camera housing on the way out.
- "Codex finished" fits whole: each assistant's symbol is measured as it is drawn.

### Answering from the notch

- The permission card says which assistant is asking: Claude, Codex or Copilot needs approval.

### Fixes

- With *Open on hover*, a panel opened with the keyboard shortcut stays open until the pointer has been in and gone again, or you close it. It used to close within a second when the pointer was elsewhere.

## [0.9.13](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.13) — 2026-10-02

### Every assistant's plan, crossed off as it goes

- Codex, Gemini CLI, Kimi Code, GitHub Copilot and OpenCode sessions now show their task list on the row, the way Claude Code's does: how far along it is, opening to the steps, with the finished ones crossed off.
- Cursor's too. Its hooks never report the to-do list, so Notchmeter reads it from the conversation's own transcript, with nothing to set up.
- A blocked step has a mark of its own. A cancelled step stays on the list, crossed out in grey, and is left out of the count.

### The model and compacting, for more assistants

- Codex, Cursor and OpenCode sessions show the model they run on, written the way you'd say it: GPT-5.5, Opus 4.7, Kimi K2.5.
- Codex, Kimi Code, Gemini CLI, Copilot and Cursor sessions show *Compacting* while the assistant summarises its context.

### Fixes

- A message from another agent, a background task or a command's output no longer becomes a session's title.

### Your hooks

- The new hook entries are added at the next launch while *Repair an out-of-date hook at launch* is on (it is by default), or with Repair in Settings › Integrations. Codex asks you to trust its changed hooks file again in `/hooks`. The OpenCode plugin updates itself.

## [0.9.12](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.12) — 2026-10-02

### Line icons in the Settings sidebar

- The Settings sidebar now draws simple line icons, with no coloured tiles behind them. The app's own sections are grey, and each assistant keeps the colour its rings wear, so the only colour in the list is your assistants'.

### A black Dashboard

- In Dark mode the Usage Dashboard now stands on the same black as the panel it opens from, rather than the system's grey. Light mode is unchanged.

### Fixes

- Settings: the search field keeps a gap under it while the page scrolls, so rows no longer run up against it.

## [0.9.11](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.11) — 2026-10-02

### Long names scroll through

- The news across the notch stays five seconds instead of four.
- A session's name too long for the room beside the notch now scrolls through once: it pauses so you can read the start, scrolls at a comfortable reading pace, and holds on the end. The news stays as long as that takes, up to seven seconds.
- *Scroll long names* (Settings › Notifications, under *News style*) turns it off. It is separate from *Reduce animations*, so you can keep other motion reduced and still read the whole name; left alone, it follows macOS's Reduce Motion.
- Everything new reads the same way in all eleven languages.

### A calmer Settings sidebar

- The app's own sections in Settings now share one graphite tile, so the only colours in the sidebar are your assistants', in the colours their rings wear.

## [0.9.10](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.10) — 2026-10-02

### Every symbol inside its rings

- With *Show assistant symbols in the rings* on, each assistant's symbol now sits in the middle of its rings however many there are. Until now it fit inside a single ring but went beside two or three, so one symbol sat inside its ring and the next beside it. With the setting on, the rings grow from 18 to 22 points, with thinner inner rings, to leave room in the middle.
- Each symbol is sized to fit inside its innermost ring and centred by its visible shape, so none sits off to one side or touches a ring.

## [0.9.9](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.9) — 2026-10-02

### News reads across the notch

- When a session waits for you or finishes a turn, the strip says so across the notch for four seconds: the assistant's symbol and what happened on the left, the session's name on the right. A long name ends in "…" where it runs out of room, instead of being cut off at the edge, which could turn "Finished" into "Fini".
- *News style* in Settings › Notifications chooses *Full*, which names the assistant and what happened ("Claude Code finished", "Claude Code needs approval"), or *Compact*, the symbols alone, which leaves more of the line to the session.
- While it shows, the line covers the menus beside the notch, and the readouts come back after.

### A quiet card when a login goes idle

- Claude Code renews its login only when claude runs in that Mac account, so in an account where it is rarely run, Notchmeter's Claude reading pauses. The card used to say so in orange, twice, with a warning beside the plan. Now the reading stays with one grey line saying how old it is and what renews it. Notchmeter still never renews the login itself, so nothing can sign Claude Code out.
- Everything new reads the same way in all eleven languages.

## [0.9.8](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.8) — 2026-10-02

### Fewer nudges you didn't need

- A session's right-click menu has *Don't nudge me for* its project. A possible wait there, a Cursor turn gone quiet or Claude Code's idle reminder, then sends no notification and no glance. A permission prompt or a question still reaches you. Settings › Notifications lists the muted projects, with *Nudge for all* to undo them.
- A Cursor session that goes on by itself after a nudge, without a command starting, was only thinking slowly. Its next nudge waits twice as long, up to three doublings and never past ten minutes; a nudge that was right, where a command starts next, takes one doubling back. A new conversation starts again from your setting. A muted project's ring still turns blue: muting stops the interruption, not the state.
- Both read the same way in all eleven languages.

## [0.9.7](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.7) — 2026-10-01

### A nudge reads like a nudge

- When a session only *may* be waiting, a Cursor turn gone quiet with nothing running or Claude Code's idle reminder, the glance in the notch is now one line: the assistant, the project, and a small jump back to the terminal. It settles after four seconds instead of six. A wait the session has actually stopped for, a permission prompt or a question, still opens the full card.
- How long a Cursor turn has to go quiet before it counts as a possible wait is now a setting: Settings › Notifications, *Call a quiet Cursor turn a possible wait after*, from 15 seconds to 10 minutes. It stays at 45 seconds until you change it. Claude Code's idle reminder keeps its own timing, which Claude Code sets.
- The new setting reads the same way in all eleven languages.

## [0.9.6](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.6) — 2026-09-27

### Two lines brought up to date

- The note under Settings › Appearance about scrolling over a ring now points at *Rings and windows* on each assistant's page, where the ring's choice is kept; it pointed at an Options section that no longer exists.
- With no assistant set up yet, the panel's line on getting started names OpenCode too, which needs no sign-in: installing it is enough.
- Both read the same way in all eleven languages.

## [0.9.5](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.5) — 2026-09-27

### The Usage Dashboard

- Resting the pointer on a bar now names that bar's day. Each day's hover area had come to cover the whole chart, so the tip named today whichever bar was under the pointer and kept it until the pointer left the chart; before 0.9.4 the line under the chart did the same.
- VoiceOver's frame for each day is that day's column, where it was the whole chart.

## [0.9.4](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.4) — 2026-09-27

### A week paced by its last day, not its busiest hours

- A weekly or monthly window is now projected at how far it rose over the last day, nights and breaks included, once the app has a day of its history. It used to be forecast at the pace of the hours you worked, which answers "if you work without stopping from now": a week spent mostly on the night it reset, and barely touched since, read as running out that afternoon. The ring's colour, the note beside the meter, the advice, the notifications, the dashboard, the command-line tool and the Claude Code status line all use this one projection, so none of them can disagree.
- The five-hour session is still projected at the pace of the hours you worked in it, now measured from each rise of the window rather than between two reads a few minutes apart. The figure moves in whole points, so any one-point step used to read as about 12% an hour however slowly the window was moving, and a figure flickering a point either way between two reads counted as a fresh rise each time it came back.
- A model already used up now leads the advice with where to go instead ("Fable weekly is 100%. Overall weekly is 56%. Switch models, not tools."), ahead of any forecast. It used to sit under one.

### The Usage Dashboard

- Resting the pointer on a bar names that day's figures in a tip over the chart, whatever else is pinned.
- A click pins a day's figures under the chart, and each further click pins another, in date order, so days can be read side by side. A second click on a pinned day lets it go; *Unpin all* or Escape lets them all go.

### Settings

- **Test in the notch**, under Notifications beside Test notification, sends a sample finished turn through the notch's own news: the words beside the notch, the glow under it and the VoiceOver announcement, under your settings as they stand. The line under it says whether it showed beside the notch, only glowed, or could not show.
- The search field's bottom edge is no longer cut off by the pane beneath it, in light or dark.

## [0.9.3](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.3) — 2026-09-25

### Settings, rows that open

- "Where each window comes from" on each assistant's page, and "Diagnostics" under Advanced, open like the rest of Settings reads: the whole row is the button, the title sits where every other title does, and a chevron at the right-hand edge, in line with the switches and menus below it, turns down as the row opens. It turns at once under Reduce Motion or Reduce animations. They used the small grey triangle in the left margin, which looked like a stray mark beside the label.
- A closed row is the same height as the rows around it, and VoiceOver says whether it is expanded or collapsed.

## [0.9.2](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.2) — 2026-09-25

### Settings, one set of icons

- Every tile in the Settings sidebar now carries a white symbol. The assistants' pages had black symbols on the light colours their rings wear beside the notch, under white symbols on the rest of the list, which made the sidebar read as two lists. Each assistant keeps its own colour, in the deeper tone its rings wear on the Paper theme, and every symbol clears 5:1 against its tile in light and dark.
- Symbols are drawn filled wherever they have a filled form, as the rest of the list already was.
- The Assistants row has its own grid symbol. It wore the terminal, which is Gemini CLI's own mark, one row above Gemini's page.

## [0.9.1](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.1) — 2026-09-25

### The Usage Dashboard, redrawn

- **The total leads.** The range's total is the largest figure in the window, with the range under it and the value line in the same card: "30 days: $412 of API-equivalent value on the $200 Claude Max 20x plan · 2.1x (estimate)", still marked the estimate it is. Daily average, peak day and today sit beside it, and move under it when the window is narrow.
- **The panel's colours, in place of the system blue.** Spend by model is drawn in each assistant's colour, and spend by project and the pin on a kept day in the accent chosen under Settings › Appearance › Theme, resolved the way the panel resolves it, under Increase Contrast too. Nothing in the window takes the system accent any more.
- **The panel's meters for the limits.** Every live limit is drawn on the meter the panel uses, with its pace tick and how much a day (or an hour, for the session window) lasts to the reset. The cards and captions are the panel's as well. The window follows the system appearance, light or dark, and both were measured for contrast.
- **Click a day to keep it.** Resting the pointer on a bar names that day under the chart, as before; a click keeps the day's figures there while you read the rest. A second click, Escape or *Unpin* lets it go. VoiceOver reads each day's bar as one element, with its total and its split by assistant, and pins it the same way.

### Also

- The dashboard's picture in docs/features.md and on notchmeter.com is current again. It was drawn on 2026-09-14 and showed the window before 0.9.0's value line; it is drawn from this version now.

## [0.9.0](https://github.com/Amir-Hackett/notchmeter/releases/tag/v0.9.0) — 2026-09-25

### Three more assistants

- **Kimi Code** has a ring, a card and a hook. The five-hour window, the week and the monthly pools come from the same endpoint Kimi Code's own `/usage` command reads, with the login the CLI already keeps on this Mac; the token is read, never refreshed. Where Kimi's two kinds of figure disagree about a window, the further-along one is shown. The hook goes into Kimi's TOML config with a backup, as every hook does.
- **OpenCode** is read from its own database on this Mac and nothing is written to it. Its spend joins the Cost card, its sessions appear from the database with no plugin installed, and an optional plugin (added from Settings, with a backup) reports turn ends and permission requests the moment they happen. On OpenCode Go, the plan publishes its limits but offers no way to read them, so Notchmeter works the meter out from your own turns at the Go page's published rates; every such window says "computed here", counts only this Mac, and can read higher than Go's own figure but never lower.
- **Gemini CLI and Antigravity are two rows now.** They were one ring that could show only one of them. Each is read under its own identity, so each shows its own quota, and the Gemini CLI hook lights Gemini CLI's ring. The old row's settings carry over to both once, and a Gemini CLI hook entry from an earlier version is repaired at launch.

### A page for each assistant in Settings

- Every assistant has its own page under Assistants in the sidebar, in the order you set: whether it is on, its rings and windows, its hook (status, snippet, Add or Repair), its sessions, its notifications, and where each of its windows comes from, in words.
- Four switches per assistant: **Read its sessions**, **Answer from the notch**, **Notify about its limits** and **Notify when it waits or finishes a turn**. Each sits under the app-wide switch of the same name and can only leave its own assistant out. **Read its sessions** covers every way a session reaches the card: its hook, the scan that finds sessions without one, and on Claude Code's page the Cowork tasks read from the Claude app.

### Sessions before any hook is installed

- The Sessions card no longer waits for a hook. With **Find sessions without the hook** on (it is, by default), the Claude Code, Codex, Cursor, Gemini CLI and Copilot sessions running in your terminals are listed from the first launch, each marked "detected". Such a row's working is a guess, it never shows a wait, and the card says what the hook adds: exact turn ends and answering from the notch.
- **Claude Cowork's tasks** are sessions too, read from the files the Claude app keeps for each one: finished when the task's log says so, working while a turn is open, idle otherwise, and never a wait. Off under Settings if you would rather not.

### More from Claude Code's hooks

- Claude Code's newer hook events reach the notch: a "Compacting" chip while a session compacts its context, the model in use and any switch Claude Code made on its own, a request for input from an MCP server (answered from the notch when it is a list of choices), idle teammates, a "may be stuck" mark after five tool calls fail in a row, refusals in auto mode, and a project or branch that changes after a `cd`. Repair, or the automatic repair at launch, adds the entries to your Claude Code settings with a backup.

### Themes

- Settings › Appearance › **Theme**, with a live preview: the panel in **Black** or **Paper**; a **Glassy**, **Smoked** or **Solid** material; a **Terracotta**, **Teal** or **Lilac** accent; usage as **Bars** or **Gauges**; and hour limits drawn on a clock. Every combination was measured for contrast, and Increase Contrast and Reduce Transparency still make the panel solid.

### The panel's controls

- Choose how many sessions are shown at once before "+N more", and whether a row leads with its title or its project.
- The closed notch has two modes, while an assistant works and when nothing is running: rings, numbers, assistant symbols or nothing.
- Scroll sideways over a readout to move its ring to the next window with a figure; a label names the window.
- A switch per connected display, under Settings › Appearance.
- The Cost row carries the last seven days as a strip of bars, with the days in words on hover and a chart split by assistant when opened.

### Six sounds

- Sounds come in six categories, each with its own sound, a Preview and a Silence box: Turn finished, Waiting reminder, Permission request, Question, Plan ready to approve and Limit alert. Your existing choices are kept. Two banners inside two seconds make one sound, except that a request or a limit still sounds after a finished turn.

### What the spend is worth, and a card to share

- The Cost card, the Simple panel's Cost row and the Usage Dashboard carry a value line: "30 days: $412 of API-equivalent value on the $200 Claude Max 20x plan · 2.1x (estimate)". The value is the card's own figure; the fee is the plan's published monthly price, read on 2026-09-24 and listed in docs/accuracy.md. A plan the table does not price gets no ratio rather than a guess.
- **Share usage card…** (in the Options menu, the Cost card's menu and the dashboard) draws a picture of a range of your usage to post: API value or tokens; today, 7 days, 30 days, this month or 90 days; feed, square or story; White, Black or Blue; an optional signature; a single day, with no series to chart, draws its split by assistant as one bar. It never carries a project, a prompt or a session title, and it says "API-equivalent estimate, not a bill". Once per version, after an update, the card opens by itself when the last thirty days hold at least a week of use; **Don't offer after updates**, or the switch in Settings › General, ends that.

### Prices that keep up between releases

- Once a day, while Settings › Appearance › Usage display › **Update model prices from notchmeter's catalog** is on (it is, by default), the app fetches this project's own price list, so a model that launches between releases is priced at its published rate within a day. The request carries nothing about you. The Cost card and the dashboard name the prices that priced the range on show, and turning the switch off leaves the built-in table and your overrides in charge.
- Opus 5.5 joins the built-in table, and the price snapshot moves to 2026-09-24.
- Claude Code's cost cache is rebuilt once on first launch, because every priced line now records the table that priced it.

### Costs in your currency, at today's rate

- Under Settings › Appearance › Usage display › Show costs in, a new **Fetch today's rate** switch (off by default) converts costs at the European Central Bank's daily euro reference rate instead of the rate you typed. It is fetched once a weekday after the ECB publishes, with no cookie and nothing about you in the request. The Cost card and the dashboard say which rate it was and its day, and the rate you typed stands in, saying so, before the first answer, while the ECB cannot be reached, for a currency it does not publish, and once its latest rate is over a week old.
- A budget keeps the currency it was typed in: the figure you set is the figure you see back, whatever the day's rate does.

### Send feedback

- Settings › General › **Send Feedback…** (also in the Options menu): a message, the diagnostics if you leave the box ticked, and the whole of what would leave shown first, with every project name, branch, session title, path and your home folder already replaced. Send opens the repository's Feedback issue form in your browser with the fields filled in, or a message to privacy@notchmeter.com in your mail app; nothing is filed or mailed until you send it there.
- It is not anonymous, and that is a decision rather than an oversight: Notchmeter has no server, so there is nothing to be anonymous through. An issue is filed under your GitHub account and a mail goes from your address, and the sheet says so before you send. Anonymous feedback would need a server of ours, which is a privacy decision of its own and not one this version makes.
- Copy puts the whole text on the clipboard, never cut to fit a link, for when no browser or mail app takes it.

### Also

- notchmeter.com has eight guides, each written to one question and stamped with the version it was checked on, and a page per assistant saying what the app shows for it and where every figure comes from.
- The privacy notice, in the app's docs and on the site, lists the two new requests (the price catalog and the ECB rate) and the two new vendors (Moonshot for Kimi Code; OpenCode is never asked anything) beside the ones it already named.

### Also in this update: everything from 0.8.0

0.8.0 was merged on 2026-09-24 but never tagged, so this is the first update to carry it. Its notes are in full in CHANGELOG.md; the short version:

- The panel opens on a **Simple** layout: one row per assistant with its most urgent figure, cost on one line and your sessions below. Click a row for everything behind it. The previous panel is still there as **Detailed** in Settings › Appearance › Panel layout. A header replaces the footer, and warnings sit on the row they are about.
- Sessions are grouped by project with the branch and terminal on a second line; the one that needs you is highlighted; each shows its context fill, its subagents and its task list; a Cursor chat that started before the app did is named from Cursor's own state.
- News in the notch: when a session needs you or finishes, the notch briefly widens to say so, with a soft glow underneath. Hover or click opens the panel on that session. Both can be turned off.
- **Allow always**: allow a request and add the rule Claude Code suggests in one step.
- A short guided tour on first launch, and again from Settings. Advice lines hide their figures while your screen is shared. Claude Desktop's Cowork sessions are priced once per response.

## 0.8.0 — 2026-09-24, merged as [#87](https://github.com/Amir-Hackett/notchmeter/pull/87) and never tagged; its changes first shipped in 0.9.0

### A simpler panel

- The panel now opens on a **Simple** layout: one row per assistant with its most urgent figure, cost on one line, and your sessions below, all on one surface. Click any row for everything behind it: every window, its pace and reset, where the figure came from, and the spend. The previous panel is still there as **Detailed** in Settings › Appearance › Panel layout.
- A header replaces the footer: the session count and when the next update is, with buttons for the Usage Dashboard, Settings and Options.
- Warnings sit on the row they are about instead of in a separate strip.

### Sessions, front and centre

- Sessions are grouped by project, with the branch and terminal on a second line.
- A Cursor chat whose prompt Notchmeter never saw (it started before the app did) now shows Cursor's own name for it, read from Cursor's local state while session titles are on and never while your screen is shared. Two untitled chats in one project are told apart by when each was first seen.
- Clicking a Cursor session brings Cursor's window for that project forward, and no other app. Cursor offers no way to open one particular chat from outside, and the row's help now says so.
- The session that needs you is highlighted.
- Each session shows its context fill when Claude Code's status line reports one.
- A chip lists the subagents running under a session.
- A session's task list shows as done/total, and opens to the checklist. It follows Claude Code's task tools, and Notchmeter's hook now also listens for them, so Repair (or the automatic repair at launch) adds one entry to your Claude Code settings.
- When no session is running, the card says so instead of disappearing.

### News in the notch

- When a session needs you or finishes, the notch briefly widens to say so ("notchmeter · Needs approval", "Finished") with a soft glow underneath. Hover or click opens the panel on that session. Both can be turned off in Settings, and the glow holds still under Reduce Motion.
- The news names the session by its title when titles are on, gives the name whichever side of the notch has room for it, and cuts a long name at its end rather than its middle.
- Optional assistant symbols inside the compact rings, for anyone who finds the colours hard to tell apart.

### Answering from the notch

- **Allow always**: when Claude Code suggests a rule, you can allow the request and add the rule in one step.
- Separate sounds for a permission request, a question and a plan ready for review.

### Also

- A short guided tour on first launch, and again from Settings.
- While your screen is shared, advice lines no longer show money or other figures.
- Cursor's Cost line no longer reports an unreadable export when you simply haven't used Cursor in the last 30 days.
- Claude Desktop's Cowork sessions are priced once per response. Their transcripts name the request id differently from Claude Code's, or leave it out, so a streamed Cowork response was counted once per content line, two or three times over. Responses are now grouped by message id alone, which is the rule Anthropic documents; Claude Code's own figures do not change, and the cost cache is rebuilt once on first launch.

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

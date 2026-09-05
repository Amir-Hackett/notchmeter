# Testing

Three layers, cheapest first: the unit tests pin every rule, `--smoke` checks the app on a real screen without a hand on the mouse, and the oracle lets an automated tester that can move the real mouse but cannot see the app's windows confirm what the app did.

## Unit tests

```bash
scripts/test.sh
```

Swift Testing through Command Line Tools alone (the script passes the framework paths), and serially: several suites touch AppKit, and two of them racing the first Window Server connection on a machine with no session abort the whole process inside CoreGraphics rather than failing a test (`CGSConnectionByID`), which is what took the first run of the release workflow down on 2026-09-05. A few minutes rather than ninety seconds, and the same answer every time. The suites are named after what they pin: the golden transcripts and the burn rate (`CostGoldenTests.swift`), the web-search fee, fast mode, projects, the week/month/90-day ranges, the daily history, the digests and pricing overrides (`CostBreakdownTests.swift`), the advice rules (`AdvisorTests.swift`, `ResetAlertTests.swift`), the hover state machine with click, swipe, Escape and the shortcut (`HoverIntentTests.swift`), the pace-crossing, reset and reminder notifications, the per-session state machine (`SessionTrackerTests.swift`), the drain log (`DrainLogTests.swift`), the status-line payload and installer (`StatuslineTests.swift`), the presence rule (`PresenceTests.swift`), the compact labels (`CompactLabelTests.swift`), the tool order, the localisation tables for six languages (`LocalizationTests.swift`), the oracle encoder (`OracleTests.swift`), the display choice, the edge placement, the machine-readable report and its exit codes (`PlatformTests.swift`), the Settings placement, the parsers for every provider, Copilot and the Codex extras included (`CopilotParsingTests.swift`), the hook parsers and installers per assistant (`HookTests.swift` for Claude Code's, `CursorHookTests.swift`, `CodexHookTests.swift`, `GeminiHookTests.swift`, `CopilotHookTests.swift`: each pins that only the vendor's documented wait lights the hand, that only the listed fields reach the payload, that the snippet is what the installer writes and that a merge keeps every foreign entry), and since the round-2 gap fixes: the peak-hours window (`PeakHoursTests.swift`), the run-out interval and the session metering ratio (`RunOutTests.swift`), the budget as a window (`BudgetTests.swift`), the local API's refusals and the remote hook (`LocalAPITests.swift`), the command-line tool and the MCP server (`CommandLineToolTests.swift`), the Keychain prompt policy (`KeychainPolicyTests.swift`), display identity (`DisplayIdentityTests.swift`) and the tests' own discipline (`TestHygieneTests.swift`, which fails a test that leaves its expectations in a task nobody awaits). Tests that need `UserDefaults` use fixed suite names, `NotchmeterTests.*`, emptied before and after each test, so a run leaves nothing new under `~/Library/Preferences`.

## The self check

```bash
scripts/build.sh
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke
```

Runs the real app for 8 to 90 seconds, never prompts for the Keychain, never starts Sparkle, and exits 0 only when everything it checks holds. It prints:

- the bundle path and whether it is App-Translocated; every screen (frame, visible frame, notch, main, primary); menu bar and Dock auto-hide, Low Power Mode and the accessibility display flags; the display choice and which presenter each chosen screen got;
- the panel's window frame and whether it is visible, the window's level and full-screen behaviour; the compact and expanded hover regions; the hover mode, delay and gestures;
- whether another app is judged full-screen on the panel's display, with the display's size, the camera housing's band, whether the Dock and the menu bar have windows on screen, every application that has one, the windows that were weighed and the system's own windows along the top edge (`full screen:`), so a wrong verdict can be read off one line. The app logs the same line on every reading at debug level, which is how to catch a wrong verdict in the Space it happens in rather than after leaving it: `log stream --level debug --predicate 'subsystem == "com.amirhackett.notchmeter"' > /tmp/fs.log &` in a terminal, then use the Mac normally and read `/tmp/fs.log` afterwards. `apps=1` beside a covering window is a Space; `apps=8` with the same window is a desktop;
- `panel sizing`: the open panel as drawn against the window and the screen cap, with the content's natural height beside it (`scrolls` where the content is taller than the cap, which is what the panel's scroll view is for; `CLIPPED`, and a failed run, only where the drawn panel is larger than the room it has), and, for the top layout, that a click below the panel still reaches the window under it;
- `compact style rings|ringsAndNumbers|numbers`: the compact hover region measured for each style, and again with the reset countdown on, so a wider readout is seen to widen the region the hover machine uses;
- with `--idle-sim`, the Hide when idle rule with the clock 31 minutes ahead and the pure rule's answers; the glance rule on the pure hover machine every run, and with `--glance-sim` a real glance through the presenter (open half a second in, closed again once it has passed);
- each provider's reading (labels and percentages, never a token), the tool order, the polling schedule (fast user switching included), the presence level, the session count with its subagents and the keep-awake state, the cost summary (ranges, block, projects, models, the metering ratio and the cache-write share), the advice, the notification state with the Keychain prompt policy, the updater, the menu bar item, the local API, the screen-capture probe in use, the proxy, the hook install state per vendor (`hooks: claude: …; codex: …; cursor: …; antigravity: …; copilot: …`, one per assistant's file: Claude Code's `settings.json`, Codex's `hooks.json`, Cursor's `hooks.json`, Gemini CLI's `settings.json` and Copilot's `notchmeter.json`) and the status-line install state with the auto-repair flag and the command-line tool's link, the main menu's key equivalents, and five lines of copy in the run's language;
- `cost card`: which assistants the Cost card carries and in what order, which one leads it (the detail block under the legend is that one's), which of them the card is set to carry at all, and the reason under the legend for each carried assistant that had nothing to show. The verdict is `follows`: the card's order must be the panel's own tool order, so moving an assistant up under Settings moves it on the Cost card too. An assistant that reports no spend is named rather than drawn as a zero slice, so it cannot lead the card however high it is placed (docs/accuracy.md);
- `panel scroll`: where the panel opens, which nothing on the screen spells out. It reads the live scroll view's position, the scrollable content's height against the height on screen, and the top of the first card's title in screen points beside the bottom edge of the notch. The panel is opened, scrolled down with a wheel event through the scroll view's own handler, closed and opened again. The verdicts: the scroll has to move it off where it opened (`nothing to scroll` where the content fits, and then there is no verdict to give), the reopening has to put it back within a few points, and the title has to sit below the notch — pinning the content to offset zero, as an earlier version did, put it 38 pt above it. `while closed=no scroll view in the window` is the expanded content leaving the window when the panel closes, which is why nothing carries a scroll position across an opening in the first place;
- `settings window` and `settings`: the Settings window's level beside the panel's own (it must be above it, and never below `.floating`, which is 3; the panel draws at screen-saver level, 1000, so the pair normally reads `level=1001 panel level=1000`), the frame, whether it is non-activating and key, the frontmost application's bundle id after presenting it (it must not be Notchmeter's own), the panel's state (it must be compact) and whether the two frames intersect (they must not); `hook sheet`, the hook-install alert driven as a sheet against a scratch file (settings.json is never touched); then `settings closed`, the panel's state after the window closes, which must match the visibility preference again.

Flags:

| Flag | Effect |
|---|---|
| `--edge left` / `right` / `bottom` | run in that layout; the previous choice is restored on exit |
| `--compact-style rings` / `ringsAndNumbers` / `numbers` | run with that readout; restored on exit (every style is still measured) |
| `--visibility onHover` / `onClick` / `always` / `hideWhenIdle` | run with that visibility; restored on exit (with `always`, the Settings step checks that the panel closes for the window and reopens after it) |
| `--display builtIn` / `main` / `pointer` / `all` / `named:<name>` | run with that display choice; restored on exit; the `display:` line lists the screens chosen |
| `--idle-sim` | runs the Hide when idle clock 31 minutes ahead and prints the presence before and after |
| `--glance-sim` | opens a real glance through the presenter and fails the run if it does not close again |
| `--hover-sim` | a scripted pointer path through the live hover machine: a fast sweep that must not open, then a dwell that opens once, a 3 s rest that must not collapse, and a leave that collapses once. Fails the run if the panel loops. Needs *Open on hover*, so pair it with `--visibility onHover`; under the other two it says so and passes |
| `--hover-log` | prints each decision the real mouse produces meanwhile |
| `--stale-sim` | shows the "Accessibility permission belongs to an older copy" alert on a copy whose permission is in order, so the copy can be read and the panel seen to get out of its way. Runs on its own (not under `--smoke`), clears nothing whatever you answer, and prints the answer |
| `--lang zh-Hans` | pins the copy to one shipped language |
| `--e2e-oracle <path>` | writes the oracle file described below, and ends the run with a `snapshot` line |

## The oracle

```bash
build/Notchmeter.app/Contents/MacOS/Notchmeter --e2e-oracle /tmp/notchmeter.jsonl
NOTCHMETER_ORACLE=/tmp/notchmeter.jsonl build/Notchmeter.app/Contents/MacOS/Notchmeter
```

While the argument or the environment variable names a file, the app appends one JSON object per line to it for every observable state change, so a tester that drives the real mouse (or posts hook events, or changes a setting) can check the effect without a screenshot. The code is [Oracle.swift](../Sources/Notchmeter/Oracle.swift); the encoder is unit-tested in `OracleTests.swift`.

Every line carries `"t"` (ISO 8601 with milliseconds, UTC) and `"event"`; keys are sorted so lines can be compared as text. Rectangles are `{x, y, width, height}` in screen points with the origin at the bottom left, as AppKit reports them; a missing value is `null`.

| `event` | When | Fields |
|---|---|---|
| `launched` | the panel has been built | `version`, `edge`, `visibility`, `compactStyle`, `toolOrder` |
| `regions` | the compact or expanded hover region changed (launch, a reading, a style or order change, a screen change) | `compact`, `expanded` |
| `panel` | the panel opened or closed | `state` (`compact` / `expanded`), `cause` (`dwell`, `exit`, `clickOutside`, `click`, `swipe`, `hotkey`, `escape`, `space`, `lock`, `always`, `settings`, `menu`, `notification`, `launch`, `glance`, `fullScreen`) |
| `menu` | the Options menu opened or closed | `action` (`shown` / `dismissed`), `items` (titles, when shown) |
| `settings` | Settings was presented or closed | `action` (`shown` / `hidden`), `frame`, `level`, `nonActivating`, `frontmostBundleId`, `panelState` |
| `layout` | the edge preference changed | `edge` |
| `order` | the tool order changed | `toolOrder` |
| `compactStyle` | the readout style changed | `compactStyle` |
| `pref` | any other preference changed | `key`, `value` |
| `reading` | a tool's status changed (and once per tool at launch) | `tool`, `status` (`notInstalled`, `off`, `waiting`, `idle`, `needsAttention`, `ready`, `failed`, `offline`), and with a reading `plan`, `stale`, `windows` (`id`, `label`, `used` 0…1 or null, `resetsAt`, `pace`) |
| `notification` | a pace or advice alert was decided on, delivered, clicked, or withdrawn from Notification Center (a window reset or moved back to on track, or a session's wait ended) | `action` (`scheduled` / `sent` / `clicked` / `removed`), `title`, `stage` when scheduled (`advice` for an advice notification), `level` when sent, `tool` and `identifier` when clicked or removed |
| `hook` | a hook event arrived from Claude Code, Codex, Cursor, Gemini CLI or Copilot CLI | `name` (Claude Code's event vocabulary for all five; the other assistants' names are mapped onto it, so Gemini's `AfterAgent` and Copilot's `agentStop` both log as `Stop`), `needsInput`, `session`, `project`, and `tool` only when the event is not Claude Code's (`codex`, `cursor`, `antigravity`, `copilot`) |
| `advice` | the advice strip's lines changed | `titles` |
| `screens` | launch, and every `NSApplication.didChangeScreenParametersNotification` (a display plugged in or out, the lid, mirroring) | `screens`: per screen `name`, `frame`, `visibleFrame`, `safeAreaTop`, `notch`, `isMain`, `isPrimary` |
| `statusline` | a Claude Code status-line payload arrived | `context` (0…1 or null), `windows` (ids), `session`, `model` |
| `privacy` | the screen-capture probe changed its answer | `captured` |
| `hotkey` | a global shortcut fired | `id` |
| `clipboard` | a card or the panel was copied as an image | `kind`, `width`, `height` |
| `session` | the console session went inactive or active (fast user switching) | `inactive` |
| `resetRefresh` | a window's reset time passed and the tool was re-read for it | `tool` |
| `presenters` | the presenters were rebuilt (launch, a display change, a layout or display-choice change) | `screens` (names), `generation` (a counter, so a tester can tell a rebuild from a redraw) |
| `awake` | the keep-awake assertion was taken or released | `holding` |
| `open` | the app opened a vendor page in the browser (a card's Usage or Status link, an advice line's link) | `host` |
| `hookRepair` | the hook or status-line entry pointing at an old copy was rewritten at launch | `repaired` (the entries touched) |
| `snapshot` | the distributed notification `com.amirhackett.notchmeter.oracle.snapshot` was received | every preference, `visibleTools`, `costCard` (`carried`, `leads`, `gaps`), `presence`, `sessions`, `awaitingInput`, `signals` (each tool asking something of you, `<tool>:<state>`), `readings`, `advice`, `panelState`, `panelVisible`, `panelScreen`, `panelScroll` (`offset`, `insetTop`, `contentHeight`, `visibleHeight`, `scrollable`, `contentTopOnScreen`, `titleTopOnScreen`, `notchBottom`, `clearsNotch`; null while the panel is closed, and the notch fields null on the layouts with nothing over them), `regions`, `screens`, `captured`, `settingsVisible`, `settingsFrame` |

Ask for a snapshot from a shell:

```bash
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.amirhackett.notchmeter.oracle.snapshot"), object: nil, userInfo: nil, deliverImmediately: true)'
```

`panel` causes read as they sound: `dwell` and `exit` are the pointer, `clickOutside`, `space` and `lock` are the immediate closes, `always` is the Always open preference opening the panel, `settings` is the Settings window holding it closed, `menu` is a switch to Open on hover from the Options menu or Settings, `launch` is the first report, `glance` is the glance gesture, and `fullScreen` is a full-screen app taking the display.

What is never written: tokens, cookies or any credential; any path under the home directory (every string is scrubbed of it, so a path would appear as `~/…`, and no reading or advice carries one); transcript content; the text of a provider error. A `reading` line for a failed read says `"status":"failed"` and shows the cached windows, nothing more.

A typical tester's loop: launch with `--e2e-oracle`, wait for `launched` and the first `regions`, move the real pointer into `regions.compact` and rest, expect `{"event":"panel","state":"expanded","cause":"dwell"}`, move it away, expect `"cause":"exit"`; right-click inside the compact region, expect `menu shown` with the item titles; choose Settings…, expect `panel compact cause=settings` followed by `settings shown` with `frontmostBundleId` still the tester's own app; close the window, expect `settings hidden`.

## Reading a provider from the terminal

```bash
build/Notchmeter.app/Contents/MacOS/Notchmeter --probe --no-prompt
build/Notchmeter.app/Contents/MacOS/Notchmeter --probe --no-prompt --json
```

The first prints every provider's parsed reading, the cost summary (ranges, block, projects, models), the last hour's drain per window and the advice, and exits; `--no-prompt` keeps the Keychain dialog closed, so a locked item reports as needing attention instead. The second prints one JSON object, pretty-printed with sorted keys, schema `notchmeter.limits.v1` (`UsageReport.swift`; decoded by `PlatformTests`), and no token anywhere:

```json
{
  "schema": "notchmeter.limits.v1",
  "generatedAt": "2026-09-02T04:20:00.000Z",
  "exitCode": 10,
  "tools": [{ "tool": "claude", "name": "Claude", "status": "ready", "plan": "Max 5x", "fetchedAt": "…", "stale": false,
              "windows": [{ "id": "five_hour", "label": "Session", "usedFraction": 0.61, "resetsAt": "…", "periodDuration": 18000,
                            "pace": "behind", "projectedFraction": 3.05, "model": null, "note": null, "source": "vendorEndpoint",
                            "drainLastHour": { "from": 0.12, "to": 0.61, "perHour": 0.49 } }] }],
  "cost": { "currency": "USD", "today": 118.31, "yesterday": 548.76, "last30Days": 6600, "last90Days": 6600, "month": 1234.5, "lastHour": 31.2,
            "typicalHourly": 9.75, "burnMultiple": 3.2, "unpricedModels": [], "firstUse": "…", "sinceFirstUse": 6600,
            "week": { "start": "…", "cost": 42.73, "perPercentOfWeekly": 1.58 }, "block": { "start": "…", "end": "…", "cost": 3.2, "tokens": 120000, "tokensPerMinute": 1200 },
            "ranges": { "today": { "cost": 118.31, "tokens": 7400000, "cacheReadShare": 0.71, "byModel": [{ "name": "claude-fable-5-1", "cost": 118.31 }], "byProject": [{ "name": "notchmeter", "cost": 118.31 }] }, "…": {} } },
  "advice": [{ "id": "burn", "priority": "warn", "tool": "claude", "text": "This hour burned $31.20 — 3.2x your 30-day average." }],
  "sessions": [{ "id": "…", "tool": "claude", "project": "notchmeter", "state": "working", "stateSeconds": 130 }]
}
```

Every window carries a `source`: `vendorEndpoint`, `statusline`, `rateLimitHeaders`, `localSnapshot` (the newest figure the tool itself wrote to disk) or `localEstimate` (the budget window); `--history` adds the daily cost history. Both forms exit with a Claude-Code-Usage-Monitor-style code: `0` fine, `10` near a limit (any window at 80 % or behind pace), `11` a limit hit (any window at 100 %), `20` no session (readings, but nothing used), `30` no data (no reading at all). The same object is what the optional local API serves at `http://127.0.0.1:6737/v1/limits` (and `/v1/limits/<tool>`), from the running app's cached readings; what the running app writes every 30 seconds to `~/Library/Application Support/Notchmeter/report-v1.json` with its pid, for the `notchmeter` command-line tool (`notchmeter [tool] [--json] [--force]`, which asks the local API first, then reads that file while it is fresh and the pid is alive, then probes) and the status line's today and block figures; what `Notchmeter --mcp` serves as the `get_limits` tool over stdio; and what the Claude Code skill in `skills/notchmeter/SKILL.md` reads.

## Seeing what Auto measured

`CompactSide.auto` decides where the readouts sit from two numbers nobody can see: how far right the frontmost
app's menu titles reach, and how far left the status items reach. When it puts the strip somewhere surprising,
that is almost always one of those two numbers being wrong rather than the fitting rule misbehaving. `--menu-bar`
prints the second one's whole working — every menu bar extra any running app vends, in the order they sit across
the bar, and whether Auto counts it:

```bash
open -n -a Notchmeter --stdout /tmp/menubar.txt --args --menu-bar
```

Run it through `open`, not straight from the shell. A binary started by a shell is attributed to the terminal for
Accessibility, so it reports "not granted" and prints nothing while the app itself is trusted; `open` hands the
launch to Launch Services and the app answers for itself. `-n` is safe here: `--menu-bar`, `--smoke`, `--probe` and
the renderers are exempt from the single-instance guard below, since none of them reaches `NSApplication.run`.

```
unplaced x 0–0, y 982, 0 × 0      com.apple.controlcenter   ← and four more like it
unplaced x 7–31, y 981, 24 × 24   com.google.Chrome
drawn    x 1050–1090, y 4         com.amirhackett.notchmeter
drawn    x 1096–1153, y 8         app.mac4breakfast
…
15 extra(s), 9 drawn; status items start at 1050
```

An app may vend extras it is not showing — a Control Center module switched off, an item pushed into the overflow
a notch creates — and macOS reports those with no size, or at the screen's origin or its foot, rather than leaving
them out. `unplaced` is one of those. They are excluded because a single one of them reads as a status item at
x = 0, which makes the right-hand gap come out negative and pins the strip to the left of the notch for good; that
was a real bug, fixed in `802cf41`, and this flag is what found it.

Two things the output makes plain that are easy to miss. Notchmeter's own menu bar icon is a drawn extra like any
other, so with it on the app is its own right-hand boundary and costs Auto roughly its own width of room. And the
number is a floor, not an exact edge: an item whose owner publishes no frame is invisible here, so the real
leftmost item can sit further left than what is printed. `CompactFit.clearance` is the margin that covers it.

Because the icon is one of those extras, it has to exist before Auto takes its first reading — and it did not.
The launch measured the bar and created the status item two lines later, so Auto held a right-hand edge some
46 pt roomier than the real one, 1096 rather than 1050 on this machine. Creating an `NSStatusItem` posts none of
the workspace notifications that drop the cached reading, so that roomy figure stood until the first app switch,
and the strip opened in one arrangement and settled into another the first time the user clicked another app.
The launch now adds the icon first, and `applyMenuBarItem` tells the watcher whenever the setting is toggled.
Its pass looks again at 120, 300 and 700 ms, because macOS does not place a new item the instant it is created —
and, unlike the menu-title pass below, it will not settle on two readings merely because they agree. The reading
to be rid of here is a real and perfectly stable measurement of a bar the icon has not landed in yet, so two of
them agree happily; the pass discards every look whose inventory does not yet show this app's own icon, and only
then asks whether the answer has stopped moving.

An activation is measured twice, and only the settled reading is kept. `didActivateApplicationNotification`
arrives before the incoming app has drawn its menu titles, so the first look can answer with the outgoing app's
geometry, or with nothing; remembering that under the incoming app's name left the strip narrowed for an app whose
menus are short, with nothing to put it right until some other app happened to activate. The settle pass looks
again at 120, 300 and 700 ms, stops as soon as two readings agree, and re-fits if the answer changed. An app that
never answers leaves no entry, so it is measured again next time rather than treated as having no menus.
`AutoSettleTests` drives the whole pass with scripted readings and a millisecond schedule.

The `readouts:` line in `--smoke` shows what was made of it all — which of the two things Auto is keeping first,
the side, the style, whether the readouts were thinned to their outer figure, how many tools survived, both
edges, both gaps, and what each half of the strip asks of the gap it is drawn into — and it needs `open` for
the same reason. The last pair is the one to read when the strip looks smaller than the bar seems to warrant: a
half is measured as the readouts it will actually draw, so the two figures are not halves of one width, and the
half that ends the strip carries the "+2" while the other does not.

## One app at a time

A second copy of a menu bar app is not a harmless duplicate. Both copies put an icon in the bar, both watch the
mouse, and both draw a panel beside the same notch; the two panels open and collapse over each other, and what
that looks like is a stray black rectangle at the top of the screen that nothing will close. It is a hard thing to
recognise as "there are two of these running" — the second copy may not even have a menu bar icon to give it away.

`SingleInstance.swift` takes an exclusive `flock` on `~/Library/Application Support/Notchmeter/instance.lock` and
holds it open for the life of the process. A copy that finds the lock taken posts
`com.amirhackett.notchmeter.reopen` — so the running copy glances its panel and a double-click still does
something — and exits before it builds a window or a status item. The lock is held by the process, not written
into the file, so a crashed copy leaves nothing stale behind and there is no timeout to get wrong.

Anything inconclusive lets the launch through: the folder cannot be created, the file cannot be opened, the
filesystem does not carry `flock`. The guard exists to stop a duplicate, and refusing to start the only copy the
user has over a disk problem would be much the worse failure.

To check it by hand, with the app running:

```bash
/Applications/Notchmeter.app/Contents/MacOS/Notchmeter ; echo "exit=$?"
```

It should return at once with `exit=0`, and `pgrep -x Notchmeter` should still name one process. `open -n` is the
same test through Launch Services. `SingleInstanceTests` pins the exclusion itself on a lock file of its own, so
it says nothing about whichever copy happens to be running while the tests do.

## Platform matrix

None of the states below can be unit-tested; each is a manual check with the expected behaviour and the self-report that confirms it without a screenshot. `--smoke` prints every screen, the chrome and the accessibility flags; the oracle emits `screens` on every display change.

| State | Expected | Check |
|---|---|---|
| Display plugged in or out, lid opened or closed | the presenters rebuild on the chosen display; the hover region is re-armed; nothing is left on a screen that went away | oracle `screens`, then `regions`; `--smoke --display main` lists the chosen screen |
| Clamshell / external-only / mirrored (no notch reported) | the top layout is a pill under the menu bar, the menu bar icon is on by default, Settings and Quit are reachable | `--smoke` on such a screen passes; `display:` line names `EdgePanelController` |
| Full-screen app's Space | rings and panel visible when *Show over full-screen apps* is on, gone when off, in both layouts; a presenter whose window is not on the active Space never opens on a hover it cannot see | `window: fullScreenAuxiliary=` line; `HoverDriver.isOffScreen` |
| Stage Manager | the rings stay beside the notch (the window is stationary and joins every Space); a left or right pill keeps clear of the recent-apps strip, whose 152 pt width is a constant taken from screenshots, not an API (Stage Manager is off on the development Mac and its state is a system setting the app does not change) | `chrome:` line, `EdgePanelController.placement` test |
| Fast user switching | polling slows to the 15-minute ceiling rather than stopping while another user's session is at the console, so the drain log keeps its rows and a run-out can still fire; a full read when this one returns, and the footer says "another user is logged in" meanwhile. A session launched straight into the background gets no notification at all, so the flag is seeded from `kCGSSessionOnConsoleKey` at startup | `polling:` line `sessionInactive=`; oracle `session` |
| A display replaced by another with the same name | the remembered display choice keys on vendor, model, serial and unit numbers, so the twin of a monitor is not mistaken for it, and a rebuild is debounced 150 ms so a cascade of screen-parameter notifications builds once | oracle `presenters` with its `generation` |
| Menu bar auto-hide | the stand-in notch height on a notchless screen follows the bar's current height; nothing is cached | `chrome:` line, `notchRect` |
| Dock auto-hide | the bottom bar sits above the reveal strip and does not summon the Dock | `chrome:` line; `EdgePanelController.placement` test |
| Screen lock | polling paused, panel collapsed | footer "Paused while the screen is locked"; oracle `panel cause=lock` |
| System sleep / wake | polling paused; on wake, a delayed read after the network is back; no fault mark | footer, then readings without `failed` |
| Display sleep (no lock) | polling paused, panel collapsed | footer "Paused while the display sleeps" |
| Low Power Mode | half the cadence, footer note | `polling:` line, footer "low power mode" |
| Offline | cached readings stay without a problem mark; footer "Offline, retrying" | reading `status: offline` in the oracle |
| Increase Contrast | brighter tracks and card fills, secondary captions, no quiet dim | `--render-assets` produces `expanded-contrast.png`; read it against `expanded.png`, which is the same panel a second earlier. Every countdown in the pair agrees, because `DemoFixtures.readings` places each reset in the middle of the unit its countdown prints rather than on the boundary of it |
| Reduce Transparency | solid black surfaces, no glass | `accessibility` line |
| Reduce Motion (system) or Reduce animations (app) | every transition instant, no pulse | `reduce motion:` line |
| Screen shared or recorded, privacy on | rings keep their shape without digits; Cost card hidden; menu bar pin blank | oracle `privacy captured=true` |
| App-Translocated launch | the move-to-Applications offer; login item disabled with a note | `bundle … translocated=true` line |
| Login item requires approval | "Approve in System Settings" button in Settings | Settings › General |

**VoiceOver walk-through (manual).** With VoiceOver on: VO-M-M reaches the menu bar item (turn it on in Settings); its menu carries Open panel, Refresh now, Settings… and Quit. The global shortcut opens the panel and makes its window key, so VO-arrows and Tab walk the Cost card, the Advice strip, each meter (label, value and pace are spoken as words: "Session 19 percent used, close to pace"), the drain line, the footer's refresh button and the Options button. Each meter has two custom actions, *Flip used and left* and *Flip countdown and exact time*. Settings is a standard grouped form.

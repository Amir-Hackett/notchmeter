# Testing

Three layers, cheapest first: the unit tests pin every rule, `--smoke` checks the app on a real screen without a hand on the mouse, and the oracle lets an automated tester that can move the real mouse but cannot see the app's windows confirm what the app did.

## Unit tests

```bash
scripts/test.sh
```

Swift Testing through Command Line Tools alone (the script passes the framework paths). The suites are named after what they pin: the golden transcripts and the burn rate (`CostGoldenTests.swift`), the web-search fee, fast mode, projects, the week/month/90-day ranges, the daily history, the digests and pricing overrides (`CostBreakdownTests.swift`), the advice rules (`AdvisorTests.swift`, `ResetAlertTests.swift`), the hover state machine with click, swipe, Escape and the shortcut (`HoverIntentTests.swift`), the pace-crossing, reset and reminder notifications, the per-session state machine (`SessionTrackerTests.swift`), the drain log (`DrainLogTests.swift`), the status-line payload and installer (`StatuslineTests.swift`), the presence rule, the compact labels, the tool order, the localisation tables for six languages, the oracle encoder, the display choice, the edge placement, the machine-readable report and its exit codes (`PlatformTests.swift`), the Settings placement, the parsers for every provider, Copilot and the Codex extras included (`CopilotParsingTests.swift`), and since the round-2 gap fixes: the peak-hours window (`PeakHoursTests.swift`), the run-out interval and the session metering ratio (`RunOutTests.swift`), the budget as a window (`BudgetTests.swift`), the local API's refusals and the remote hook (`LocalAPITests.swift`), the command-line tool and the MCP server (`CommandLineToolTests.swift`), the Keychain prompt policy (`KeychainPolicyTests.swift`), display identity (`DisplayIdentityTests.swift`) and the tests' own discipline (`TestHygieneTests.swift`, which fails a test that leaves its expectations in a task nobody awaits). Tests that need `UserDefaults` use fixed suite names, `NotchmeterTests.*`, emptied before and after each test, so a run leaves nothing new under `~/Library/Preferences`.

## The self check

```bash
scripts/build.sh
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke
```

Runs the real app for 8 to 90 seconds, never prompts for the Keychain, never starts Sparkle, and exits 0 only when everything it checks holds. It prints:

- the bundle path and whether it is App-Translocated; every screen (frame, visible frame, notch, main, primary); menu bar and Dock auto-hide, Low Power Mode and the accessibility display flags; the display choice and which presenter each chosen screen got;
- the panel's window frame and whether it is visible, the window's level and full-screen behaviour; the compact and expanded hover regions; the hover mode, delay and gestures;
- `panel sizing`: the open panel as drawn against the window and the screen cap, with the content's natural height beside it (`scrolls` where the content is taller than the cap, which is what the panel's scroll view is for; `CLIPPED`, and a failed run, only where the drawn panel is larger than the room it has), and, for the top layout, that a click below the panel still reaches the window under it;
- `compact style rings|ringsAndNumbers|numbers`: the compact hover region measured for each style, and again with the reset countdown on, so a wider readout is seen to widen the region the hover machine uses;
- with `--idle-sim`, the Hide when idle rule with the clock 31 minutes ahead and the pure rule's answers; the glance rule on the pure hover machine every run, and with `--glance-sim` a real glance through the presenter (open half a second in, closed again once it has passed);
- each provider's reading (labels and percentages, never a token), the tool order, the polling schedule (fast user switching included), the presence level, the session count with its subagents and the keep-awake state, the cost summary (ranges, block, projects, models, the metering ratio and the cache-write share), the advice, the notification state with the Keychain prompt policy, the updater, the menu bar item, the local API, the screen-capture probe in use, the proxy, the hook and status-line install state with the auto-repair flag and the command-line tool's link, the main menu's key equivalents, and five lines of copy in the run's language;
- `settings window` and `settings`: the Settings window's level (3 is `.floating`), frame, whether it is non-activating and key, the frontmost application's bundle id after presenting it (it must not be Notchmeter's own), the panel's state (it must be compact) and whether the two frames intersect (they must not); `hook sheet`, the hook-install alert driven as a sheet against a scratch file (settings.json is never touched); then `settings closed`, the panel's state after the window closes, which must match the visibility preference again.

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
| `panel` | the panel opened or closed | `state` (`compact` / `expanded`), `cause` (`dwell`, `exit`, `clickOutside`, `click`, `swipe`, `hotkey`, `escape`, `space`, `lock`, `always`, `settings`, `menu`, `notification`, `launch`) |
| `menu` | the Options menu opened or closed | `action` (`shown` / `dismissed`), `items` (titles, when shown) |
| `settings` | Settings was presented or closed | `action` (`shown` / `hidden`), `frame`, `level`, `nonActivating`, `frontmostBundleId`, `panelState` |
| `layout` | the edge preference changed | `edge` |
| `order` | the tool order changed | `toolOrder` |
| `compactStyle` | the readout style changed | `compactStyle` |
| `pref` | any other preference changed | `key`, `value` |
| `reading` | a tool's status changed (and once per tool at launch) | `tool`, `status` (`notInstalled`, `off`, `waiting`, `idle`, `needsAttention`, `ready`, `failed`), and with a reading `plan`, `stale`, `windows` (`id`, `label`, `used` 0…1 or null, `resetsAt`, `pace`) |
| `notification` | a pace or advice alert was decided on, delivered, clicked, or withdrawn from Notification Center (a window reset or moved back to on track, or a session's wait ended) | `action` (`scheduled` / `sent` / `clicked` / `removed`), `title`, `stage` when scheduled (`advice` for an advice notification), `level` when sent, `tool` and `identifier` when clicked or removed |
| `hook` | a Claude Code hook event arrived | `name`, `needsInput`, `session`, `project` |
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
| `snapshot` | the distributed notification `com.amirhackett.notchmeter.oracle.snapshot` was received | every preference, `visibleTools`, `presence`, `sessions`, `awaitingInput`, `readings`, `advice`, `panelState`, `panelVisible`, `panelScreen`, `regions`, `screens`, `captured`, `settingsVisible`, `settingsFrame` |

Ask for a snapshot from a shell:

```bash
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.amirhackett.notchmeter.oracle.snapshot"), object: nil, userInfo: nil, deliverImmediately: true)'
```

`panel` causes read as they sound: `dwell` and `exit` are the pointer, `clickOutside`, `space` and `lock` are the immediate closes, `always` is the Always open preference opening the panel, `settings` is the Settings window holding it closed, `menu` is a switch to Open on hover from the Options menu or Settings, and `launch` is the first report.

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
  "sessions": [{ "id": "…", "project": "notchmeter", "state": "working", "stateSeconds": 130 }]
}
```

Every window carries a `source`: `vendorEndpoint`, `statusline`, `rateLimitHeaders`, `localSnapshot` (the newest figure the tool itself wrote to disk) or `localEstimate` (the budget window); `--history` adds the daily cost history. Both forms exit with a Claude-Code-Usage-Monitor-style code: `0` fine, `10` near a limit (any window at 80 % or behind pace), `11` a limit hit (any window at 100 %), `20` no session (readings, but nothing used), `30` no data (no reading at all). The same object is what the optional local API serves at `http://127.0.0.1:6737/v1/limits` (and `/v1/limits/<tool>`), from the running app's cached readings; what the running app writes every 30 seconds to `~/Library/Application Support/Notchmeter/report-v1.json` with its pid, for the `notchmeter` command-line tool (`notchmeter [tool] [--json] [--force]`, which reads that file while it is fresh and the pid is alive, then the local API, then probes) and the status line's today and block figures; what `Notchmeter --mcp` serves as the `get_limits` tool over stdio; and what the Claude Code skill in `skills/notchmeter/SKILL.md` reads.

## Platform matrix

None of the states below can be unit-tested; each is a manual check with the expected behaviour and the self-report that confirms it without a screenshot. `--smoke` prints every screen, the chrome and the accessibility flags; the oracle emits `screens` on every display change.

| State | Expected | Check |
|---|---|---|
| Display plugged in or out, lid opened or closed | the presenters rebuild on the chosen display; the hover region is re-armed; nothing is left on a screen that went away | oracle `screens`, then `regions`; `--smoke --display main` lists the chosen screen |
| Clamshell / external-only / mirrored (no notch reported) | the top layout is a pill under the menu bar, the menu bar icon is on by default, Settings and Quit are reachable | `--smoke` on such a screen passes; `display:` line names `EdgePanelController` |
| Full-screen app's Space | rings and panel visible when *Show over full-screen apps* is on, gone when off, in both layouts; a presenter whose window is not on the active Space never opens on a hover it cannot see | `window: fullScreenAuxiliary=` line; `HoverDriver.isOffScreen` |
| Stage Manager | the rings stay beside the notch (the window is stationary and joins every Space); a left or right pill keeps clear of the recent-apps strip, whose 152 pt width is a constant taken from screenshots, not an API (Stage Manager is off on the development Mac and its state is a system setting the app does not change) | `chrome:` line, `EdgePanelController.placement` test |
| Fast user switching | polling paused and the panel collapsed while another user's session is at the console; a full read when this one returns | `polling:` line `sessionInactive=`; oracle `session` |
| A display replaced by another with the same name | the remembered display choice keys on vendor, model, serial and unit numbers, so the twin of a monitor is not mistaken for it, and a rebuild is debounced 150 ms so a cascade of screen-parameter notifications builds once | oracle `presenters` with its `generation` |
| Menu bar auto-hide | the stand-in notch height on a notchless screen follows the bar's current height; nothing is cached | `chrome:` line, `notchRect` |
| Dock auto-hide | the bottom bar sits above the reveal strip and does not summon the Dock | `chrome:` line; `EdgePanelController.placement` test |
| Screen lock | polling paused, panel collapsed | footer "Paused while the screen is locked"; oracle `panel cause=lock` |
| System sleep / wake | polling paused; on wake, a delayed read after the network is back; no fault mark | footer, then readings without `failed` |
| Display sleep (no lock) | polling paused, panel collapsed | footer "Paused while the display sleeps" |
| Low Power Mode | half the cadence, footer note | `polling:` line, footer "low power mode" |
| Offline | cached readings stay without a problem mark; footer "Offline, retrying" | reading `status: offline` in the oracle |
| Increase Contrast | brighter tracks and card fills, secondary captions, no quiet dim | `--render-assets` produces `expanded-contrast.png` |
| Reduce Transparency | solid black surfaces, no glass | `accessibility` line |
| Reduce Motion (system) or Reduce animations (app) | every transition instant, no pulse | `reduce motion:` line |
| Screen shared or recorded, privacy on | rings keep their shape without digits; Cost card hidden; menu bar pin blank | oracle `privacy captured=true` |
| App-Translocated launch | the move-to-Applications offer; login item disabled with a note | `bundle … translocated=true` line |
| Login item requires approval | "Approve in System Settings" button in Settings | Settings › General |

**VoiceOver walk-through (manual).** With VoiceOver on: VO-M-M reaches the menu bar item (turn it on in Settings); its menu carries Open panel, Refresh now, Settings… and Quit. The global shortcut opens the panel and makes its window key, so VO-arrows and Tab walk the Cost card, the Advice strip, each meter (label, value and pace are spoken as words: "Session 19 percent used, close to pace"), the drain line, the footer's refresh button and the Options button. Each meter has two custom actions, *Flip used and left* and *Flip countdown and exact time*. Settings is a standard grouped form.

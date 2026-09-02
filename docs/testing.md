# Testing

Three layers, cheapest first: the unit tests pin every rule, `--smoke` checks the app on a real screen without a hand on the mouse, and the oracle lets an automated tester that can move the real mouse but cannot see the app's windows confirm what the app did.

## Unit tests

```bash
scripts/test.sh
```

Swift Testing through Command Line Tools alone (the script passes the framework paths). The suites are named after what they pin: the golden transcripts and the burn rate (`CostGoldenTests.swift`), the advice rules (`AdvisorTests.swift`), the hover state machine (`HoverIntentTests.swift`), the pace-crossing notifications, the presence rule, the compact labels, the tool order, the localisation tables, the oracle encoder, the Settings placement, and the parsers for every provider.

## The self check

```bash
scripts/build.sh
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke
```

Runs the real app for 8 to 90 seconds, never prompts for the Keychain, never starts Sparkle, and exits 0 only when everything it checks holds. It prints:

- the panel's window frame and whether it is visible; the compact and expanded hover regions;
- `panel sizing`: the open panel's content height against the window and the screen cap, and, for the top layout, that a click below the panel still reaches the window under it;
- `compact style rings|ringsAndNumbers|numbers`: the compact hover region measured for each style, so a wider readout is seen to widen the region the hover machine uses;
- each provider's reading (labels and percentages, never a token), the tool order, the polling schedule, the presence level, the cost summary, the advice, the notification and updater state, and five lines of copy in the run's language;
- `settings window` and `settings`: the Settings window's level (3 is `.floating`), frame, whether it is non-activating and key, the frontmost application's bundle id after presenting it (it must not be Notchmeter's own), the panel's state (it must be compact) and whether the two frames intersect (they must not); then `settings closed`, the panel's state after the window closes, which must match the visibility preference again.

Flags:

| Flag | Effect |
|---|---|
| `--edge left` / `right` / `bottom` | run in that layout; the previous choice is restored on exit |
| `--compact-style rings` / `ringsAndNumbers` / `numbers` | run with that readout; restored on exit (every style is still measured) |
| `--visibility onHover` / `always` | run with that visibility; restored on exit (with `always`, the Settings step checks that the panel closes for the window and reopens after it) |
| `--hover-sim` | a scripted pointer path through the live hover machine; fails the run if the panel loops |
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
| `panel` | the panel opened or closed | `state` (`compact` / `expanded`), `cause` (`dwell`, `exit`, `clickOutside`, `space`, `lock`, `always`, `settings`, `menu`, `launch`) |
| `menu` | the Options menu opened or closed | `action` (`shown` / `dismissed`), `items` (titles, when shown) |
| `settings` | Settings was presented or closed | `action` (`shown` / `hidden`), `frame`, `level`, `nonActivating`, `frontmostBundleId`, `panelState` |
| `layout` | the edge preference changed | `edge` |
| `order` | the tool order changed | `toolOrder` |
| `compactStyle` | the readout style changed | `compactStyle` |
| `pref` | any other preference changed | `key`, `value` |
| `reading` | a tool's status changed (and once per tool at launch) | `tool`, `status` (`notInstalled`, `off`, `waiting`, `idle`, `needsAttention`, `ready`, `failed`), and with a reading `plan`, `stale`, `windows` (`id`, `label`, `used` 0…1 or null, `resetsAt`, `pace`) |
| `notification` | a pace alert was decided on, then delivered | `action` (`scheduled` / `sent`), `title`, `stage` when scheduled |
| `hook` | a Claude Code hook event arrived | `name`, `needsInput` |
| `advice` | the advice strip's lines changed | `titles` |
| `snapshot` | the distributed notification `com.amirhackett.notchmeter.oracle.snapshot` was received | every preference, `visibleTools`, `presence`, `awaitingInput`, `readings`, `advice`, `panelState`, `panelVisible`, `regions`, `settingsVisible`, `settingsFrame` |

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
```

Prints every provider's parsed reading, the cost summary and the advice, and exits; `--no-prompt` keeps the Keychain dialog closed, so a locked item reports as needing attention instead.

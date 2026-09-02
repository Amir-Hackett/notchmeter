# Notchmeter

![Rings beside the notch open into the usage panel on hover](docs/media/demo.gif)

*Hover the rings beside the notch and the panel opens: cost, pace, projections and what to do next.*

**Your menu bar ran out of room three apps ago. This one doesn't take any.**

[![CI](https://github.com/Amir-Hackett/notchmeter/actions/workflows/ci.yml/badge.svg)](https://github.com/Amir-Hackett/notchmeter/actions/workflows/ci.yml)

Usage meters for AI coding tools, living in the MacBook notch — or on any screen edge you prefer. Small rings sit beside the notch all the time; hover and it opens into the full readout.

- **Claude Code** — the 5-hour session window, the weekly window, and the per-model weekly limits Anthropic publishes (Fable, Sonnet, Opus…), plus what your local Claude Code sessions would have cost at API list prices: today, yesterday, and the last 30 days, with a 30-day trend.
- **Codex** — the session, weekly or monthly rate-limit windows from the same backend Codex itself asks, with the snapshots Codex writes into session rollouts as a fallback when offline.
- **Cursor** — included plan usage and on-demand spend for the current billing cycle, read the way cursor.com's own dashboard reads it.
- **Antigravity / Gemini CLI** — the per-model quota Google meters for Gemini CLI and Antigravity (Gemini Pro, Gemini Flash, Gemini Flash Lite, and any Claude or GPT model the plan covers), from the same Code Assist endpoint Gemini CLI's `/stats` reads, with the Google login Gemini CLI keeps on this Mac.

Every meter shows a pace tick (where an even burn would be right now), a projection ("~67% left at reset" or "Runs out in 2h"), and the reset time as a countdown or an exact time.

The rings follow a calm rule ([`Presence.swift`](Sources/Notchmeter/Presence.swift)): small and dim while every window is under 40 % and on pace, full size once one passes 40 % or runs close to its pace, and slowly pulsing once one is behind pace, has run out, or Claude Code is waiting for you. Status never rests on colour alone: pace notes carry a symbol and the rings a cap, the status colours are Wong's colour-blind-safe set, every meter has a VoiceOver label, Reduce Motion is honoured, and on macOS 26 the edge pills are Liquid Glass.

Every other meter tells you how much. Notchmeter also tells you what to do about it: an **Advice** strip under the Cost card, and a notification when a window's pace crosses, both worded as an instruction rather than a percentage. See [Advice and notifications](#advice-and-notifications).

With the optional [Claude Code hook](docs/hooks.md), the notch refreshes the moment a turn ends and shows a small dot on the Claude ring while Claude Code waits for your permission or your answer.

Notchmeter never signs in anywhere and never stores a token. Each reading is borrowed from the tool that owns the account; switch accounts in that tool and the notch follows.

## Screenshots

| The open panel | Left edge | Settings |
|---|---|---|
| ![The open panel: the Cost card, the Advice strip, a pace meter per window with its projection, and the footer](docs/media/expanded.png) | ![The left-edge pill, one ring per tool](docs/media/edge-left.png) | ![The Settings window](docs/media/settings.png) |

The pictures are drawn by `Notchmeter --render-assets docs/media` from the real views over fixed readings (Claude on Max 5x a third of the way into a quiet session, Codex and Cursor on free plans), not from a live account, so they come out the same on every build and show nobody's usage.

## Build and install

Needs macOS 14+ and the Xcode Command Line Tools only (no Xcode). Everything is plain SwiftPM.

```bash
scripts/build.sh install
```

That builds `build/Notchmeter.app`, ad-hoc signs it, copies it to `/Applications` and launches it. Other forms:

```bash
scripts/build.sh          # just build the .app
scripts/build.sh run      # build and launch from build/
scripts/test.sh           # unit tests for the parsers, pace math and cost engine
swift run Notchmeter --probe            # print what each provider reads and the advice it adds up to, from the terminal
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke               # on-screen self check (no Keychain prompt)
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke --edge left   # same, trying another layout
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke --hover-sim   # scripted hover: one open, no flicker, one close
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke --lang zh-Hans   # same, with the copy pinned to Simplified Chinese
build/Notchmeter.app/Contents/MacOS/Notchmeter --hook                # Claude Code hook command, see docs/hooks.md
build/Notchmeter.app/Contents/MacOS/Notchmeter --render-assets docs/media   # the README's pictures, from fixed readings (no Keychain, no network)
```

A local build is ad-hoc signed and never checks for updates. Shipped builds are signed with Developer ID, notarised and updated through Sparkle by `scripts/release.sh`; [docs/release.md](docs/release.md) has the one-time setup and the per-release command.

## First launch

macOS asks once whether Notchmeter may read Claude Code's saved login from the Keychain. Choose **Always Allow**; plain Allow asks again on every read. Codex, Cursor and Antigravity need no permission. Rebuilding changes the ad-hoc signature, so the question comes back after each rebuild.

## Layout and settings

Right-click the panel (or use the **Options** button in its footer) for the menu; **Settings…** opens the full window.

| Setting | Choices |
|---|---|
| Position | Top, in the notch · Left edge · Right edge · Bottom, above the Dock |
| Show | Open on hover · Always open |
| Show total spend | on / off (the Cost card and the trend) |
| Show usage as | Used · Left |
| Reset times | Countdown ("Resets in 3h 40m") · Exact time ("Resets today at 10:50 PM") |
| Time format | Auto · 12-hour · 24-hour |
| Open at login | on / off |
| Notify when a window is on pace to run out | on / off, with a **Test notification** button |
| Assistants | switch each tool on or off |
| Claude Code hook | show the `settings.json` snippet with a Copy button, or merge it in after a backup ([docs/hooks.md](docs/hooks.md)) |

The top layout merges with the physical notch (compact rings beside it, the panel below). The edge layouts are Codenotch-style pills that open into the same panel; they keep clear of the Dock. The panel is never taller than the screen's usable height: past that (four tools, the cost card and advice on a small display) it scrolls, and it shows no scroller while it fits.

**Hover.** The panel opens once the pointer has rested on the rings for 250 ms, so passing the top of the screen does nothing, and closes 400 ms after the pointer has left the panel (with 8 pt of grace), at once on a click outside it, a Spaces switch or the screen lock, and never while set to Always open. The decision is a pure state machine ([`HoverIntent.swift`](Sources/Notchmeter/HoverIntent.swift)) fed with the pointer's position against the two visible shapes, measured from the notch and the content rather than from the window, and it ignores the pointer for up to 350 ms after each transition, so the panel's own open and close animation can never re-trigger it. `--smoke --hover-sim` drives that path with a scripted pointer and prints every decision.

## Languages

Notchmeter runs in English and Simplified Chinese (简体中文), in whichever of the two macOS picks for it from System Settings › General › Language & Region (system-wide, or just for Notchmeter under Applications). Product and tool names stay as they are; everything else, the panel, Settings, the Options menu, notifications and every provider message, comes from [`Sources/Notchmeter/Resources/<language>.lproj/Localizable.strings`](Sources/Notchmeter/Resources), a classic `.strings` table keyed by the English copy and read through `L("…")` ([`Localization.swift`](Sources/Notchmeter/Localization.swift)). `--lang zh-Hans` pins the copy for one run whatever the system language; `--smoke --lang zh-Hans` prints a line of it. To add a language, add its `.lproj` with the same keys, list it in `Localization.languages` and in `CFBundleLocalizations` in `scripts/Info.plist`; `scripts/test.sh` checks that every table carries every key the code uses, with the same format arguments, and nothing else.

## Advice and notifications

The rules are pure functions in [`Advisor.swift`](Sources/Notchmeter/Advisor.swift), run over every visible tool's live reading and the cost summary, and pinned by unit tests. The strip shows at most three lines, highest priority first, and is not there at all when there is nothing to say.

| Priority | When | Reads |
|---|---|---|
| Needs you | Claude Code's [hook](docs/hooks.md) reports a permission prompt or a question | *Claude Code is waiting for your input.* |
| Run-out | any window is behind pace and has a run-out time; if another tool still has half of its main window, it is named | *At this rate you hit the Claude weekly cap Thursday at 2:00 PM, 3d 4h before reset. Codex weekly is at 22%.* |
| Switch models | a per-model window (Fable, Sonnet, Opus…; Gemini Pro, Gemini Flash…) is 85 % used and another model, or the overall window, has 40 % left | *Opus weekly is 91%. Sonnet is 34%. Switch models, not tools.* |
| Burn | the last hour cost at least three times your usual active hour (see the Cost card) | *This hour burned $8.40 — 6x your 30-day usual.* |
| Room elsewhere | a tool's main window is on track or behind and another tool has half of its own left | *Codex has 78% of its weekly left.* |

A tool's *main window* is its longest tool-wide one: the weekly for Claude and Codex, the billing cycle for Cursor; Antigravity publishes only per-model windows, so it has none. A per-model window is named by its cadence ("Fable weekly", "Gemini Pro daily", or "Gemini Pro quota" while the vendor declares no window length). Times follow the Reset times and Time format settings.

**Notifications** fire at pace crossings, not percentage crossings, because a percentage alert arrives when it is too late to change anything. Per window and reset period, [`NotificationScheduler.swift`](Sources/Notchmeter/NotificationScheduler.swift) sends one notification when the pace first reaches *on track*, one when it first reaches *behind*, and one when the run-out time first comes within an hour; a state never repeats within a period, a calmer state is never announced, and nothing is sent during the first tenth of a window, when the projection is noise. The body is the same line the strip would show. What was sent is remembered across relaunches. The setting is on by default; macOS asks for permission the first time the app runs with it on, and `--smoke` and `--probe` never send anything.

## How it reads each tool

| Tool | Where the login comes from | Where the numbers come from |
|---|---|---|
| Claude Code | Keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`) | `GET https://api.anthropic.com/api/oauth/usage` |
| Claude Code cost | — | `~/.claude/projects/**/*.jsonl`, priced per model with the four token buckets (input, output, 5-minute and 1-hour cache writes, cache reads), times 1.1 when the response reports `inference_geo: "us"`; a line's own `costUSD` wins when present; a streamed message's repeated lines collapse by message id + request id to the one carrying the real output count |
| Codex | `~/.codex/auth.json` (token read, never refreshed or written) | `GET https://chatgpt.com/backend-api/wham/usage`, falling back to the newest `rate_limits` line in `~/.codex/sessions/**/*.jsonl` |
| Cursor | `cursorAuth/accessToken` in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | `GET https://cursor.com/api/usage-summary` (falls back to `/api/usage` on request-metered plans) |
| Antigravity | `~/.gemini/oauth_creds.json`, the Google login Gemini CLI caches (token read, never refreshed or written) | `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` for the project and tier, then `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` for the per-model buckets: the two reads Gemini CLI itself makes at every start |

Cost is an estimate at Anthropic's published API rates for the models in your transcripts (`Sources/Notchmeter/ModelPricing.swift`); a subscription does not bill this way, it is the API-equivalent value of the work. Once there are five active hours to compare against, the card also shows the last hour against your usual active hour ("Last hour $8.40 · 6x your usual"). Only transcripts touched in the last 30 days are read, and parsed results are cached in `~/Library/Caches/Notchmeter/` so relaunches are instant. How the estimate is built, every multiplier it applies, and where it is known to diverge from a bill, is written down in [docs/accuracy.md](docs/accuracy.md), and a golden-transcript test suite pins the numbers.

Antigravity and Gemini CLI meter against the same Google backend, and the login Gemini CLI caches is the only one on disk: the Antigravity app and its `agy` CLI keep theirs in the Keychain and publish quota only through a local server inside the running app, which Notchmeter does not attach to. So the Antigravity meter needs one Google sign-in through Gemini CLI (`gemini`, then *Login with Google*); an API-key or Vertex AI setup has no quota to read. The buckets are grouped the way Gemini CLI's own `/stats` groups them, every Gemini model of a tier sharing one pool, and Google declares no window length for them (its docs call them per-day request limits), so these meters carry no pace tick or projection until it does. Since June 2026 Google serves this endpoint only to Code Assist Standard and Enterprise accounts; a personal account gets a sentence saying so, not an HTTP code. Adding a tool means one `UsageProvider` actor in `Sources/Notchmeter` and one line in `ProviderRegistry`.

## Privacy and terms

Notchmeter is a read-only instrument. In plain terms:

**What it reads.**

- Claude Code's saved login: the Keychain item `Claude Code-credentials`, or `~/.claude/.credentials.json` when the Keychain has no such item. The access token, its expiry and the plan name are taken from it.
- Codex's saved login: the access token, account id and expiry in `~/.codex/auth.json`.
- Cursor's saved login: the `cursorAuth/accessToken` row of `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`. The database is copied to a private temporary file for the read and deleted straight after, so the editor's live database is never opened.
- Gemini CLI's saved Google login: the access token and its expiry in `~/.gemini/oauth_creds.json`.
- Local transcripts, for the cost card and the offline fallback: the `usage` lines of `~/.claude/projects/**/*.jsonl` (also `$CLAUDE_CONFIG_DIR` and `~/.config/claude`; only files touched in the last 30 days) and the newest `rate_limits` lines in `~/.codex/sessions/**/*.jsonl`.
- Modification times only, for the polling schedule: of files under the most recently changed `~/.claude/projects` folders, of `~/.codex/sessions/<today>` and `<yesterday>`, of Cursor's `state.vscdb`, and of `~/.gemini/oauth_creds.json` and the entries of `~/.gemini/tmp`, `~/.gemini/antigravity` and `~/.gemini/antigravity-cli/conversations`. Contents are not read for this.
- If you install the [Claude Code hook](docs/hooks.md), Claude Code hands `Notchmeter --hook` each event's JSON; the command keeps only the event name and whether Claude is waiting for you, and passes those two values to the running app.

**Where it sends things.** Each token goes to exactly one place: the usage endpoint of the vendor that issued it, over HTTPS, in the same read-only status request the vendor's own app or dashboard makes: `api.anthropic.com/api/oauth/usage`, `chatgpt.com/backend-api/wham/usage`, `cursor.com/api/usage-summary`, and for Google the two calls Gemini CLI makes at every start, `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` and `:retrieveUserQuota`. Every request identifies itself with a `User-Agent: Notchmeter/<version>` header; nothing is disguised. Nothing is sent anywhere else. There is no telemetry, no analytics, no crash reporting and no server of ours.

**What it keeps.** No token is copied anywhere lasting, logged, or printed; `--probe` and the unified log show parsed numbers only. What is persisted: your settings, the last good reading per tool and which pace notifications have been sent in this app's own preferences, and per-transcript totals in `~/Library/Caches/Notchmeter/` so relaunches are instant. That cache holds timestamps, model names, token counts, message ids and the inference-geography flag, never prompt or response text.

**What it never does.** It never signs in, never refreshes a token, never opens a login page, and never makes an inference request, so it consumes no model capacity and cannot change the usage it reports. Each reading is borrowed from a tool you are already signed in to; sign out of that tool and the reading goes with it.

**How often.** The base cadence is Claude every 3 minutes, Codex every 2 minutes, Cursor and Antigravity every 5 minutes, and the local cost scan every minute (it only re-reads files that changed). The schedule adapts, by the rules in [`PollingPolicy.swift`](Sources/Notchmeter/PollingPolicy.swift): nothing at all while the screen is locked or the Mac is asleep; half as often on battery; a quarter as often once a tool's files on disk have not changed for 30 minutes, which is checked once a minute with a few directory listings (Claude Code's three most recently changed project folders, Codex's rollouts for today and yesterday, the modification time of Cursor's state database, Gemini CLI's login file and its per-project and Antigravity folders); never more than 15 minutes apart while awake, and never faster than the base cadence. Unlocking or waking reads everything at once, a Claude Code hook event refreshes Claude at most once every 30 seconds, hovering the panel refreshes a tool at most once a minute, a rate-limit answer backs off for at least a minute, and other failures back off from 30 seconds up to 10 minutes. The panel footer always shows the real next read and why it is later than usual ("no agent activity", "on battery").

**Terms.** Each vendor's terms are written for its own apps and restrict automated access to its services in broad language, and reading an app's saved login from outside that app is a grey area under each of them. Notchmeter stays on the narrowest path there is: a login the vendor's own tool put on this Mac, used for one status read that tool itself makes, never stored, never passed on, never used for inference. Whether to run it under your account is your decision. If a vendor withdraws its usage endpoint, the meter reports the error and waits; it does not look for another way in. In particular it never probes Anthropic's inference endpoint for the rate-limit headers other meters read, because that is an inference call; the reasoning is in [docs/accuracy.md](docs/accuracy.md#why-there-is-no-header-fallback).

## Energy

Measured on 2026-09-01 on an Apple M5 Pro running macOS 26.6.2 on battery power: `build/Notchmeter.app` launched as `Notchmeter --no-prompt`, the panel compact and untouched, a Claude Code session active in the background (6,856 transcripts under `~/.claude/projects`, about 140,000 usage lines), no Keychain access so the Claude read failed fast and backed off, Codex not installed, Cursor signed in on a free plan. The first 45 seconds after launch (the initial reads and the first cost scan) were left out.

| Window | Method | Result |
|---|---|---|
| 60 s with no cost scan inside it | `ps -o cputime=` before and after, divided by wall time | 0.01 CPU-seconds / 61 s = **0.02 %** of one core |
| 180 s including one cached cost scan | same | 0.86 CPU-seconds / 182 s = **0.47 %** of one core |
| the same 180 s in 30 s samples | `top -l 7 -s 30 -stats pid,cpu,mem -pid <pid>` | 0.0, 0.3, 1.9, 0.0, 0.0, 0.5, 0.0 % of one core; 37 to 69 MB resident |

Between scans the app is idle: the minute tick (power source and a few directory listings) and the pill's drawing do not register at `ps`'s 10 ms resolution. The one recurring cost is the cost scan, about half a CPU-second per scan at this transcript volume, spent stat-ing every transcript and re-summing the cached entries. Its cadence follows the polling policy: every minute on mains power while a Claude session is active (so expect roughly 1 % of one core in that state), every two minutes on battery, every four minutes once no agent has been active for 30 minutes, and never while the screen is locked or the Mac is asleep. The same measurement before this version read 1.62 % over 60 s, because the 17 MB transcript cache was rewritten on every scan while a session was appending to a transcript; it is now written at most once every ten minutes. Summing the cached entries incrementally instead of per scan is the next reduction and is not done yet.

To reproduce (a second copy of the app appears beside the notch while it runs):

```bash
build/Notchmeter.app/Contents/MacOS/Notchmeter --no-prompt & PID=$!
sleep 45; ps -o cputime= -p $PID
top -l 7 -s 30 -stats pid,cpu,mem -pid $PID | grep "^ *$PID"     # 180 s of samples
ps -o cputime= -p $PID; kill $PID
```

The authoritative number is Energy Impact from `powermetrics`, which on Apple silicon accounts for idle wake-ups as well as CPU time. It needs `sudo` and was **not** run for the figures above; to get it:

```bash
sudo powermetrics --samplers tasks --show-process-energy -i 60000 -n 5 | grep -E '^Name|Notchmeter'
```

## Troubleshooting

```bash
/usr/bin/log show --last 10m --info --predicate 'subsystem == "com.amirhackett.notchmeter"' --style compact
```

- *Claude: needs your permission* — the Keychain prompt was denied or dismissed; toggle Claude off and on in Settings to ask again.
- *Claude: login has expired* — run `claude` in a terminal once; it refreshes its own token and the notch picks it up. Notchmeter never refreshes tokens itself. Until then the card keeps the last reading, marked with when it was taken.
- *Codex: login was refused / expired* — run Codex once; it signs back in and the notch picks it up.
- *Codex: Session — No data* — the plan publishes no 5-hour window (free plans get a monthly one).
- *Cursor: plan has nothing to meter* — free plans publish no included-usage limit; the ring appears once a paid plan does.
- *Antigravity: Sign in to Gemini CLI* — the meter uses the Google login Gemini CLI caches in `~/.gemini/oauth_creds.json`; run `gemini` once and choose Login with Google. An API-key or Vertex AI setup has no quota to read.
- *Antigravity: login has expired / was refused* — run Gemini CLI or Antigravity once; it signs back in and the notch picks it up.
- *Antigravity: Google stopped serving Gemini CLI quota to personal accounts* — since June 2026 the endpoint answers only Code Assist Standard and Enterprise accounts; nothing on this side can change that.
- *Cost card says "Pricing local transcripts"* — the first scan of a large `~/.claude/projects` takes a few seconds; later scans only read files that changed.
- *Footer says "Next update in 12m · no agent activity"* — nothing of the tool's has changed on disk for 30 minutes, so the meter polls a quarter as often; start a session (or install the hook) and it returns to the base cadence within a minute. "Paused while the screen is locked" clears on unlock.
- *The hook badge never appears* — see the checks at the end of [docs/hooks.md](docs/hooks.md).

## Documentation

- [docs/accuracy.md](docs/accuracy.md): every rule behind the cost estimate, the primary sources, where it is known to differ from a bill, and why there is no rate-limit-header probe.
- [docs/hooks.md](docs/hooks.md): the optional Claude Code hook, what it sends, and how to install and remove it.
- [docs/release.md](docs/release.md): the signed, notarised, Sparkle-updated release pipeline and its one-time setup.
- [docs/roadmap.md](docs/roadmap.md): what is shipped against the plan, what is pending or blocked, the fleet roll-up design sketch, monetisation, the domain check and the open questions.
- [docs/anthropic-inquiry.md](docs/anthropic-inquiry.md): a draft letter asking Anthropic whether the read-only usage request is acceptable.
- Launch: [Show HN](docs/launch/show-hn.md), [Product Hunt](docs/launch/product-hunt.md), [awesome lists and GitHub topics](docs/launch/awesome-lists.md).

## Contributing

Run `scripts/test.sh` before a pull request; CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs the same tests plus a release build that fails on any compiler warning under `Sources/`, and assembles the app. A cost-estimate disagreement is best reported as a golden-transcript fixture in `Tests/NotchmeterTests/CostGoldenTests.swift`; a new tool is one `UsageProvider` actor and one `ProviderRegistry` line.

## Credits

- The notch window is [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) 1.1.0 by Kai Azim (MIT), vendored in `Vendor/DynamicNotchKit` with its `@Entry`/`#Preview` macros replaced by plain code so it compiles without Xcode.
- Pace projection, reset copy, window naming and the cost rules follow [OpenUsage](https://github.com/robinebers/openusage) (MIT), which in turn ports ccusage's transcript semantics. Feature set modelled on Codenotch and OpenUsage, reimplemented from scratch.

## License

MIT, see [LICENSE](LICENSE). DynamicNotchKit keeps its own MIT licence in `Vendor/DynamicNotchKit/LICENSE`.

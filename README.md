# Notchmeter

Usage meters for AI coding tools, living in the MacBook notch — or on any screen edge you prefer. Small rings sit beside the notch all the time; hover and it opens into the full readout.

- **Claude Code** — the 5-hour session window, the weekly window, and the per-model weekly limits Anthropic publishes (Fable, Sonnet, Opus…), plus what your local Claude Code sessions would have cost at API list prices: today, yesterday, and the last 30 days, with a 30-day trend.
- **Codex** — the session, weekly or monthly rate-limit windows from the same backend Codex itself asks, with the snapshots Codex writes into session rollouts as a fallback when offline.
- **Cursor** — included plan usage and on-demand spend for the current billing cycle, read the way cursor.com's own dashboard reads it.

Every meter shows a pace tick (where an even burn would be right now), a projection ("~67% left at reset" or "Runs out in 2h"), and the reset time as a countdown or an exact time.

Notchmeter never signs in anywhere and never stores a token. Each reading is borrowed from the tool that owns the account; switch accounts in that tool and the notch follows.

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
swift run Notchmeter --probe            # print what each provider reads, from the terminal
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke               # on-screen self check (no Keychain prompt)
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke --edge left   # same, trying another layout
```

## First launch

macOS asks once whether Notchmeter may read Claude Code's saved login from the Keychain. Choose **Always Allow**; plain Allow asks again on every read. Codex and Cursor need no permission. Rebuilding changes the ad-hoc signature, so the question comes back after each rebuild.

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
| Assistants | switch each tool on or off |

The top layout merges with the physical notch (compact rings beside it, the panel below). The edge layouts are Codenotch-style pills that open into the same panel; they keep clear of the Dock.

## How it reads each tool

| Tool | Where the login comes from | Where the numbers come from |
|---|---|---|
| Claude Code | Keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`) | `GET https://api.anthropic.com/api/oauth/usage` |
| Claude Code cost | — | `~/.claude/projects/**/*.jsonl`, priced per model with the four token buckets (input, output, 5-minute and 1-hour cache writes, cache reads); a line's own `costUSD` wins when present; duplicates from streaming are dropped by message id + request id |
| Codex | `~/.codex/auth.json` (token read, never refreshed or written) | `GET https://chatgpt.com/backend-api/wham/usage`, falling back to the newest `rate_limits` line in `~/.codex/sessions/**/*.jsonl` |
| Cursor | `cursorAuth/accessToken` in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | `GET https://cursor.com/api/usage-summary` (falls back to `/api/usage` on request-metered plans) |

Cost is an estimate at Anthropic's published API rates for the models in your transcripts (`Sources/Notchmeter/ModelPricing.swift`); a subscription does not bill this way, it is the API-equivalent value of the work. Only transcripts touched in the last 30 days are read, and parsed results are cached in `~/Library/Caches/Notchmeter/` so relaunches are instant.

Antigravity is not supported (not installed here). Adding a tool means one `UsageProvider` actor in `Sources/Notchmeter` and one line in `ProviderRegistry`.

## Troubleshooting

```bash
/usr/bin/log show --last 10m --info --predicate 'subsystem == "com.amirhackett.notchmeter"' --style compact
```

- *Claude: needs your permission* — the Keychain prompt was denied or dismissed; toggle Claude off and on in Settings to ask again.
- *Claude: login has expired* — run Claude Code once; it refreshes its own token and the notch picks it up.
- *Codex: login was refused / expired* — run Codex once; it signs back in and the notch picks it up.
- *Codex: Session — No data* — the plan publishes no 5-hour window (free plans get a monthly one).
- *Cursor: plan has nothing to meter* — free plans publish no included-usage limit; the ring appears once a paid plan does.
- *Cost card says "Pricing local transcripts"* — the first scan of a large `~/.claude/projects` takes a few seconds; later scans only read files that changed.

## Credits

- The notch window is [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) 1.1.0 by Kai Azim (MIT), vendored in `Vendor/DynamicNotchKit` with its `@Entry`/`#Preview` macros replaced by plain code so it compiles without Xcode.
- Pace projection, reset copy, window naming and the cost rules follow [OpenUsage](https://github.com/robinebers/openusage) (MIT), which in turn ports ccusage's transcript semantics. Feature set modelled on Codenotch and OpenUsage, reimplemented from scratch.

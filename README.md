# Notchmeter

Usage rings for AI coding tools, living in the MacBook notch. Small rings sit beside the notch all the time; hover and it opens into the full readout.

- **Claude Code** — the 5-hour session window and the weekly windows (all models, Opus, Sonnet…), read from Anthropic's usage endpoint with the login Claude Code already holds.
- **Codex** — the primary and weekly rate-limit windows Codex itself records on disk after every turn.
- **Cursor** — included plan usage and on-demand spend for the current billing cycle, read the way cursor.com's own dashboard reads it.

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
scripts/test.sh           # unit tests for the parsers
swift run Notchmeter --probe            # print what each provider reads, from the terminal
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke   # 8-second on-screen self check
```

## First launch

macOS asks once whether Notchmeter may read Claude Code's saved login from the Keychain. Choose **Always Allow**; plain Allow asks again on every read. Codex and Cursor need no permission.

Right-click the notch for the menu: refresh now, open on hover vs. always open, open at login, settings, quit.

## How it reads each tool

| Tool | Where the login comes from | Where the numbers come from |
|---|---|---|
| Claude Code | Keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`) | `GET https://api.anthropic.com/api/oauth/usage` |
| Codex | presence of `~/.codex/auth.json` (never opened) | newest `rate_limits` line in `~/.codex/sessions/**/*.jsonl` |
| Cursor | `cursorAuth/accessToken` in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | `GET https://cursor.com/api/usage-summary` (falls back to `/api/usage` on request-metered plans) |

Antigravity is not supported (not installed here). Adding a tool means one `UsageProvider` actor in `Sources/Notchmeter` and one line in `ProviderRegistry`.

## Troubleshooting

```bash
/usr/bin/log show --last 10m --info --predicate 'subsystem == "com.amirhackett.notchmeter"' --style compact
```

- *Claude: needs your permission* — the Keychain prompt was denied or dismissed; toggle Claude off and on in Settings to ask again.
- *Claude: login has expired* — run Claude Code once; it refreshes its own token and the notch picks it up.
- *Codex: no sessions on this Mac yet* — Codex only writes rate limits after a conversation; run it once.
- *Cursor: plan has nothing to meter* — free plans publish no included-usage limit; the ring appears once a paid plan does.

Rebuilding changes the ad-hoc signature, so macOS asks the Keychain question again after each rebuild.

## Credits

The notch window is [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) 1.1.0 by Kai Azim (MIT), vendored in `Vendor/DynamicNotchKit` with its `@Entry`/`#Preview` macros replaced by plain code so it compiles without Xcode. Feature set modelled on Codenotch, reimplemented from scratch.

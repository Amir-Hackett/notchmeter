# Notchmeter

**Every figure on this panel is sourced, dated and tested — here is the document: [docs/accuracy.md](docs/accuracy.md).** Usage meters for Claude Code, Codex, Cursor, Antigravity / Gemini CLI and GitHub Copilot that say what to do about the number, not only what it is.

[![License: MIT](https://img.shields.io/github/license/Amir-Hackett/notchmeter)](LICENSE) [![CI](https://github.com/Amir-Hackett/notchmeter/actions/workflows/ci.yml/badge.svg)](https://github.com/Amir-Hackett/notchmeter/actions/workflows/ci.yml) [![Latest release](https://img.shields.io/github/v/release/Amir-Hackett/notchmeter)](https://github.com/Amir-Hackett/notchmeter/releases/latest) [![Downloads](https://img.shields.io/github/downloads/Amir-Hackett/notchmeter/total)](https://github.com/Amir-Hackett/notchmeter/releases)

![Rings beside the notch open into the usage panel on hover](docs/media/demo.gif)

*Hover the rings beside the notch and the panel opens: cost, pace, projections and what to do next.*

**Your menu bar ran out of room three apps ago. This one doesn't take any.** The rings live in the MacBook notch — or on any screen edge you prefer — small and dim while nothing needs you, and open into the full readout when you hover.

**Answer Claude Code from the notch.** When Claude Code stops for a permission, approve or deny it there; when it asks a multiple-choice question, pick the answer there; then jump back to the terminal window, tab or pane the session is running in. A request nobody answers falls back to the terminal's own prompt, as if the notch were not there, and each part has its own switch under Settings › Assistants › Sessions. What the hook sends for it, and how the channel fails open, is in [docs/hooks.md](docs/hooks.md).

**[notchmeter.com](https://www.notchmeter.com)** · [Download](https://github.com/Amir-Hackett/notchmeter/releases/latest/download/Notchmeter.dmg) · [Support the project](https://buy.stripe.com/8x2bIVbYF8wsgP2cvVao800)

## What it shows

- **Claude Code** — the 5-hour session window, the weekly window and the per-model weekly limits, plus what your local sessions would have cost at API list prices.
- **Codex** — the session, weekly or monthly rate-limit windows Codex itself reads.
- **Cursor** — included plan usage and on-demand spend for the billing cycle, the way cursor.com's dashboard reads it.
- **Antigravity / Gemini CLI** — the session and weekly quota Antigravity's panel shows, or Gemini CLI's per-model quota.
- **GitHub Copilot** — the month's AI-credit allowance, or a legacy seat's premium requests.

Every meter shows a pace tick (where an even burn would be right now), a projection ("~67% left at reset" or "Runs out in 2h") and the reset time. An **Advice** strip and pace notifications say what to do about it — "Opus weekly is 91%. Sonnet is 34%. Switch models, not tools." — and the **Usage Dashboard** (⌘U) lays the week's spend and limits out in one window. With the optional [hooks](docs/hooks.md), the notch refreshes the moment a turn ends, counts your running sessions, and marks an assistant that is waiting for you. Before any hook is installed, the Sessions card still lists the sessions running in your terminals, each marked as found without it.

Everything, with the screenshots and every setting: [docs/features.md](docs/features.md). Energy, measured under a heavy Claude Code job on an M5 Pro: 1.4 to 1.6 % of one core and a physical footprint of 63 MB; the method and the raw numbers are in [docs/energy.md](docs/energy.md).

## Install

- **Download** [`Notchmeter.dmg`](https://github.com/Amir-Hackett/notchmeter/releases/latest/download/Notchmeter.dmg) from the latest release and drag it to Applications. The DMG is Developer ID signed and notarised, and the app updates itself through Sparkle.
- **Homebrew**: `brew tap Amir-Hackett/tap && brew trust --cask Amir-Hackett/tap/notchmeter && brew install --cask notchmeter`. The middle step is Homebrew's, not this project's: it refuses to load a cask from a tap outside homebrew/cask until you say you trust it.

macOS 15 or later, Apple silicon or Intel. Notchmeter is free and stays free; if it earns its place in your notch, you can [support the project](https://buy.stripe.com/8x2bIVbYF8wsgP2cvVao800).

Pre-release builds, building from source (`scripts/build.sh`) and what the first launch asks for: [docs/install.md](docs/install.md). Something not showing up: [docs/troubleshooting.md](docs/troubleshooting.md).

## Privacy and terms

Notchmeter is a read-only instrument. It never signs in anywhere, never refreshes or stores a token, and never makes an inference request. Each reading is borrowed from the tool that owns the account — the login Claude Code, Codex, Cursor, Gemini CLI or Copilot already keeps on this Mac — and each token goes only to the vendor that issued it, over HTTPS, in the same read-only status request that vendor's own app or dashboard makes. There is no telemetry, no analytics, no crash reporting and no server of ours.

Every request names itself with a `User-Agent: Notchmeter/<version>` header, with two exceptions, because those two endpoints answer only the vendor's own client: the Copilot quota read and Antigravity's Code Assist calls are made under those clients' own identity. Each vendor's endpoint, what it is sent and how each request identifies itself is tabled in [docs/accuracy.md](docs/accuracy.md#who-each-request-says-it-is), and if a vendor asks us to stop, [that meter goes](docs/accuracy.md#if-a-vendor-asks-us-to-stop) in the next release.

The one request that is not a meter's is Sparkle's update check: once a day it fetches the release feed from GitHub, with no token, no usage figure and no system profile; Settings › Updates › *Check for updates automatically* turns it off ([docs/privacy.md](docs/privacy.md)).

**Terms.** Anthropic's are the most specific, so they are quoted rather than summarised. Claude Code's [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) page (read 2026-09-20): "Moreover, developers may not collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must complete through Anthropic's own flow." The [Consumer Terms of Service](https://www.anthropic.com/legal/consumer-terms), section 3, item 7, forbids using the Services "Except when you are accessing our Services via an Anthropic API Key or where we otherwise explicitly permit it, to access the Services through automated or non-human means, whether through a bot, script, or otherwise." Notchmeter offers no login, routes nothing through the token and keeps no credential; every request to Anthropic names itself, and the usage endpoint is asked at most every five minutes, and while a session's status line is fresh only on Refresh, at a reset, and at most every 30 minutes for figures the status line does not carry. That poll is still a script making a request, and the app does not pretend otherwise: the channel Anthropic documents is the [status line](docs/hooks.md#the-status-line), and with *Also poll Claude's usage endpoint* off (Settings › Assistants › Claude Code) Notchmeter makes no request to Anthropic whatever. Whether to run it under your account is your decision.

The whole of it — every file read, every host and path asked, what is kept on disk, how often, and the full quotes with the app's reading of them — is in [docs/privacy.md](docs/privacy.md). The two optional macOS permissions are in [docs/permissions.md](docs/permissions.md).

## Documentation

- [docs/features.md](docs/features.md): every meter, the screenshots, every setting, the command line and MCP server, the Claude Code plugin, the languages, and the advice and notification rules.
- [docs/install.md](docs/install.md): installing, testing a pre-release build, building from source, and the first launch.
- [docs/privacy.md](docs/privacy.md): what is read, where it is sent, what is kept, how often, and the vendors' terms.
- [docs/accuracy.md](docs/accuracy.md): every rule behind the cost estimate, the primary sources, where it is known to differ from a bill, and why there is no rate-limit-header probe.
- [docs/hooks.md](docs/hooks.md): the optional hooks for Claude Code, Codex, Cursor, Gemini CLI and GitHub Copilot CLI, what each sends and what each cannot report, how to install and remove them, and the status line.
- [docs/permissions.md](docs/permissions.md): Accessibility for *Readouts › Auto*, Automation for the jump to a terminal, and why local builds lose their grants.
- [docs/energy.md](docs/energy.md): CPU and memory, measured, with the commands to reproduce them.
- [docs/troubleshooting.md](docs/troubleshooting.md): what each message on a card means and what to do about it.
- [docs/testing.md](docs/testing.md): the unit tests, the `--smoke` self check and its flags, `--probe --json`, the platform matrix, and the `--e2e-oracle` event log an automated tester can read.
- [plugin/skills/notchmeter/SKILL.md](plugin/skills/notchmeter/SKILL.md): a Claude Code skill that reads `notchmeter --json` so Claude can check its own windows and the advice before long work.
- [docs/release.md](docs/release.md): the signed, notarised, Sparkle-updated release pipeline and its one-time setup; [docs/release-notes/](docs/release-notes) holds each version's notes, which the update alert shows.
- [CHANGELOG.md](CHANGELOG.md): every released version, newest first.
- [plugin/](plugin): the Claude Code plugin that packages the skill and the MCP server, listed by [.claude-plugin/marketplace.json](.claude-plugin/marketplace.json) ([Install as a Claude Code plugin](docs/features.md#install-as-a-claude-code-plugin)).
- [docs/roadmap.md](docs/roadmap.md): what is shipped against the plan, what is pending or blocked, the fleet roll-up design sketch, monetisation, the domain check and the open questions.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). A security issue goes to [SECURITY.md](SECURITY.md), not to a public issue; everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Credits

- The notch window is [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) 1.1.0 by Kai Azim (MIT), vendored in `Vendor/DynamicNotchKit` with its `@Entry`/`#Preview` macros replaced by plain code so it compiles without Xcode.
- Pace projection, reset copy, window naming and the cost rules follow [OpenUsage](https://github.com/robinebers/openusage) (MIT), which in turn ports ccusage's transcript semantics. Feature set modelled on Codenotch and OpenUsage, reimplemented from scratch.

## License

MIT, see [LICENSE](LICENSE). DynamicNotchKit keeps its own MIT licence in `Vendor/DynamicNotchKit/LICENSE`.

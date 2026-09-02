# Roadmap

Where Notchmeter stands against the plan it is built to, what is shipped, what is pending, what is blocked on a decision or an account, and the questions still open. Repository facts below were read on 2026-09-02; the plan's competitive figures are from 2026-09-01.

## Where the repository stands (2026-09-02)

| | |
|---|---|
| Visibility | private, 0 stars, 0 forks, created 2026-09-02, no topics |
| Version | 0.1.0 (`scripts/Info.plist`), no tag, no release |
| Code | 31 Swift files under `Sources/Notchmeter`, about 5,900 lines; `Vendor/DynamicNotchKit` (MIT) |
| Tests | 145 tests in 29 suites, `scripts/test.sh`, 0.1 s |
| CI | `.github/workflows/ci.yml` on macos-15 (gate) and macos-latest (allowed to fail): release build with a zero-warnings check on `Sources/`, tests, app assembly, artifact |
| Release pipeline | `scripts/release.sh` and `.github/workflows/release.yml`: universal binary, Developer ID, hardened runtime, notarisation, stapled DMG, EdDSA-signed Sparkle appcast, Homebrew cask file. Proven with `--dry-run`; **unsigned until the Developer ID, notary key and Sparkle key exist** |
| Licence | MIT at the root |
| Assets | `docs/media`: GIF, four PNGs, all drawn from fixture readings by `--render-assets` |

The plan's premise, that "best in the world" is reachable on craft, correctness and prescription rather than on features, is unchanged. Its reference-class forecast for a new notch meter launched into this field, P(more than 2,342 stars in 12 months) ≈ 12% and P(more than 500) ≈ 35%, resolves on 2027-09-01 and is the number the day-90 decision is scored against.

## The four wedges

### Wedge 1: prescriptive, not descriptive

| | Status | Where |
|---|---|---|
| Advice strip: run-out with a named alternative tool, switch-models, burn multiple, room elsewhere, "Claude Code is waiting for you" | shipped | `Advisor.swift`, `AdvisorTests.swift`; README "Advice and notifications" |
| Notifications at pace crossings, not percentage crossings; one per state per period; nothing in the first tenth of a window | shipped | `NotificationScheduler.swift`, `Notifier.swift` |
| Cross-provider routing ("Codex has 78% of its weekly left") | shipped | `Advisor.swift` |
| Burn rate against the user's own 30-day average active hour | shipped | `ClaudeCostScanner.swift`; accuracy doc "Burn rate" |
| "Waiting for you" badge from the Claude Code hook | shipped | `Hook.swift`, `docs/hooks.md` |
| Advice that names a time to come back ("reset in 40 min, wait rather than switch") | pending | small rule in `Advisor.swift` |
| A skill so Claude Code itself can read the windows and the advice before long work (`Notchmeter --probe --no-prompt`) | pending | `skills/notchmeter/SKILL.md`; also the door into the Composio list ([launch/awesome-lists.md](launch/awesome-lists.md)) |

### Wedge 2: correctness as a published, tested guarantee

| | Status | Where |
|---|---|---|
| `docs/accuracy.md`: files read, five token buckets, per-model rates, dedupe rule, every multiplier, known divergences, primary sources with dates | shipped | [accuracy.md](accuracy.md) |
| 1.1× residency multiplier on `inference_geo: "us"` | shipped | `ModelPricing.swift`, `ClaudeCostScanner.swift` |
| Real output count (last line of a streamed response), measured: 35% more output tokens than first-line dedupe on this machine | shipped | accuracy doc "The output_tokens placeholder" |
| Golden-transcript suite pinning eight fixtures to nine decimals | shipped | `CostGoldenTests.swift` |
| Rate-limit-header parser as a degradation path; **no** inference probe for headers, by decision | shipped | `ClaudeProvider.swift`; accuracy doc "Why there is no header fallback" |
| Claude Code statusline `rate_limits` as a sanctioned, local, zero-network source for the session and weekly windows while a session is running | pending | a statusline command beside `--hook`; would let the endpoint poll drop to zero while Claude Code is open and is the fallback if Anthropic says no ([anthropic-inquiry.md](anthropic-inquiry.md)) |
| Web search per-request fee, fast-mode rates | pending, disclosed | accuracy doc "Known divergences" 2 and 3 |
| Price-table freshness check (a test that fails when the published table moves) | pending | would need a fetch in CI, or a dated fixture and a reminder |

### Wedge 3: the notch surface, argued rather than assumed

| | Status | Where |
|---|---|---|
| The argument on the README's first screen: "Your menu bar ran out of room three apps ago. This one doesn't take any." | shipped | README |
| Edge layouts (left, right, bottom) as the hedge for notch-less Macs and the hardware risk | shipped | `EdgePanelController.swift` |
| Calm presence rule: quiet under 40%, legible at 80%, urgent at pace crossing; the Dynamic Island "minimal" state | shipped | `Presence.swift` |
| Colour-blind-safe status (Wong set) with a non-colour channel, `monospacedDigit`, Reduce Motion, VoiceOver labels, Liquid Glass on macOS 26 | shipped | `NotchViews.swift`, `EdgePanelController.swift` |
| Hover as a dwell-and-settle state machine with a scripted test (`--smoke --hover-sim`) | shipped | `HoverIntent.swift`, `HoverDriver.swift` |
| Measured energy figure on the README (ps/top) | shipped | README "Energy" |
| `powermetrics` Energy Impact figure | **blocked: needs sudo**; one command in the README's Energy section | run it once on the release build and replace the table's headline |
| Bullet bars instead of rings in the expanded panel (the plan's position-over-angle argument) | pending, decision | the panel's pace meters are horizontal bars with the pace tick already; the rings stay in the compact state, which is what the plan asked for. Closed unless a screenshot review says otherwise |
| Simplified Chinese | shipped | `Resources/zh-Hans.lproj` |

### Wedge 4: multi-machine / fleet roll-up

Nothing shipped; nothing should be until day 90 (see the plan below). The design sketch is in its own section, because it is the only part of this anyone will pay for and the privacy model has to be fixed before a line of it is written.

## The 90-day plan against the repository

The plan was written for 90 days. Most of the first 45 days' items landed in the first two, because they were code; what remains is accounts, decisions and other people.

**Days 1–7, shippable at all.** MIT licence: done. Public repository: **pending, one click, the user's decision.** README GIF: done (`docs/media/demo.gif`, rendered from fixtures). CI running `scripts/test.sh`: done. Colour accessibility and `monospacedDigit`: done. Swift 6 `Sendable` warnings: resolved, zero warnings under `Sources/` is now a CI gate.

**Days 8–21, trustworthy.** Developer ID, notarisation, Sparkle, appcast: pipeline done, **blocked on the Apple Developer Program enrolment (US$99/year), the Developer ID certificate, an App Store Connect API key and a Sparkle key**; [release.md](release.md) is the one-time setup, and the placeholder `SUPublicEDKey` in `scripts/Info.plist` keeps the updater off until then. Accuracy doc with the residency multiplier and the placeholder disclosure: done. Golden tests: done. Rate-limit-header fallback: parser done, probe refused by decision. Adaptive polling and the energy figure: done; `powermetrics` needs sudo.

**Days 22–45, the wedge.** Pace-crossing notifications with prescriptive copy: done. Cross-provider routing: done. Minimal presentation state: done. Liquid Glass: done (edge pills; the notch window is DynamicNotchKit's). VoiceOver: done. Antigravity/Gemini via `retrieveUserQuota`: done, and Google has since limited that endpoint to Code Assist Standard and Enterprise accounts, which the meter reports in a sentence. zh-Hans: done.

**Days 46–90, distribute and decide.** All pending, in this order, with the gates:

1. Public repository and topics ([launch/awesome-lists.md](launch/awesome-lists.md), "GitHub topics"). No gate.
2. Signed release v0.1.0 (blocked as above). Gate for everything below: nobody installs an ad-hoc-signed binary.
3. Send [anthropic-inquiry.md](anthropic-inquiry.md) in the first week of this window, not later.
4. Show HN ([launch/show-hn.md](launch/show-hn.md)). Gate: signed DMG, CI green.
5. Product Hunt the following week ([launch/product-hunt.md](launch/product-hunt.md)). Goal 100 upvotes, top 15.
6. Awesome lists: travisvn and jqueryscript at 10 stars; hesreallyhim on or after 2026-09-15; Composio when the skill ships.
7. Homebrew: the tap (`Amir-Hackett/homebrew-tap`, cask file ready in `packaging/homebrew`) immediately after the signed release; homebrew/cask at 225 stars and 30 days.
8. **Day 90 (2026-12-01): decide.** Read the star count against the 12%/35% forecast and choose between pushing into the fleet layer and letting this be an excellent personal tool. Both are fine; the undecided middle is not.

## Fleet roll-up: design sketch

The demand is documented (98% of FinOps teams manage AI spend, only 36% include agentic workloads in cost reporting; Anthropic's own figures put Claude Code at roughly $150–250 per developer per month), and both leading competitors have declined the layer, TrackNotch's maker explicitly on privacy grounds. The privacy model is therefore the product. Fixed before design starts:

**Privacy model.**

- **Opt-in, per machine, off by default.** A switch in Settings, a line in the panel footer while it is on ("Sharing daily totals with <label>"), and a "what was sent" list in Settings showing the last seven documents verbatim.
- **Per-machine daily aggregates only.** One JSON document per machine per day: the date; a machine id that is a random UUID minted at opt-in and resettable by the user; an optional label the user types; per tool, the peak used fraction of each window that day and its reset time, and the day's cost estimate split by model and by the five token buckets. Nothing else. No token, no account id, no email, no hostname, no project path, no transcript, no prompt, no per-request rows, no timestamps finer than the day.
- **No token ever leaves the Mac.** The roll-up client is a separate code path that never sees a credential; the providers hand it readings, never requests. A test asserts the outgoing document's keys against an allow-list.
- **The roll-up server is optional and self-hosted.** A single binary with a SQLite file, run by the org, or no server at all: the client can push the same document to a bucket the org owns. The client knows one URL and a per-machine key created at enrolment, and signs each document with it. A hosted version, if ever, is the same binary run by us, with the same document.
- **Retention is the org's.** The server keeps daily rows; the client keeps the last seven days for resend and display.

**What it shows the budget owner.** Spend by team and by day; who is on pace to hit a weekly cap and when (the same pace maths, over the fleet); model mix, since Opus share is the lever; tool mix; seats with no activity in 14 days. Real-time, per-prompt, per-project, remote control and blocking are deliberately absent; the moment it can see a prompt or stop a session it is a monitoring product, and the privacy line is what sells it.

**Pricing.** Per seat per month, sold to the person who owns the AI budget; free for self-hosted fleets of five or fewer machines, which is the developer who wants their laptop and desktop on one chart.

**Open design questions.** Machine-to-person mapping is the org's job (the label field), not the app's; Anthropic's Team/Enterprise admin dashboards and Cursor's admin analytics already show each vendor's own numbers, so the layer earns its keep only across vendors and on pace, and that needs saying on its landing page; whether Team/Enterprise Claude Code tokens answer the same usage endpoint is unverified.

## Monetisation

The recommendation, unchanged from the plan:

1. **The personal meter stays free and MIT.** ccusage (18k stars), OpenUsage (MIT) and Boring Notch (GPL) are free; a paid meter is a friction tax on the distribution the project needs, and 5,000 copies of a $4.99 utility is $25,000 gross, a side project's budget.
2. **The fleet layer is the paid product** (above). It is the only path where the numbers get interesting and the one the author's day job makes him good at.
3. **Setapp**, once the Developer ID and notarisation exist: usage-based share of subscription revenue, and since February 2026 one-time licences at 85/15. Low effort at that point, and it does not conflict with MIT.
4. **GitHub Sponsors**, 0% fee from a personal account. Coffee money; do not plan around it.

## Hardware risk: the notch may not last

Omdia's roadmap, corroborated by Gurman, has OLED MacBook Pros replacing the notch with a hole-punch in 2026–2027, with the Air following, and a hole-punch could carry a Mac Dynamic Island. First-order, the surface shrinks; second-order, ambient notch UI becomes an Apple-sanctioned pattern, and the 2021–2026 installed base of notched Macs does not vanish on the announcement day.

The hedge is shipped: the left, right and bottom edge pills open into the same panel, and every setting, test and asset is layout-agnostic. The rule for copy: the notch is the lead noun, never the only one; "notch or edge" wherever the surface is named, which the README, the Product Hunt description and the awesome-list entries already do.

## Domain

Queried on **2026-09-02 at 07:26 UTC** with `curl -L https://rdap.org/domain/<name>`:

| Domain | Route | Result |
|---|---|---|
| notchmeter.com | rdap.org 302 → `https://rdap.verisign.com/com/v1/domain/notchmeter.com` | **HTTP 404 Not Found**, `Content-Type: application/rdap+json`, empty body (queried directly at Verisign as well: same) |
| notchmeter.app | rdap.org 302 → `https://pubapi.registry.google/rdap/domain/notchmeter.app` | **HTTP 404**, body `{"errorCode":404,"title":"Not Found","description":["notchmeter.app not found"]}` |
| notchmeter.dev | rdap.org 302 → `https://pubapi.registry.google/rdap/domain/notchmeter.dev` | **HTTP 404**, body `{"errorCode":404,"title":"Not Found","description":["notchmeter.dev not found"]}` |

Controls run in the same minute: `openusage.app` and `anthropic.com` both returned HTTP 200 with a registration record, so the 404s are absence, not a broken query.

**Caveat:** an RDAP 404 means the registry holds no record for the name; it does not mean the name can be bought. Reserved names, premium-priced names, names in a redemption period and registry-blocked names all answer 404 too, and `.app` and `.dev` are Google registries with premium tiers. Availability and price are only confirmed at a registrar, at checkout. The plan's preference is `.app` (HTTPS-only by HSTS preload, which suits an app that never speaks plain HTTP); confirm `.com` at the same time and take both if both are ordinary-priced. Until then the repository URL is the website everywhere.

## Open questions

Carried from the plan, with what has changed:

- **Nobody outside this machine has run the app.** All design judgments are from the code and from fixture renders. The Show HN thread is the first external review; treat its first ten comments as the design review the plan could not do.
- **Anthropic's position** is unasked. The draft is written; sending it is the user's action. Until an answer exists, the README's Terms paragraph is the position, and the statusline path above is the fallback.
- **Claude Code's "4.2M weekly active developers"** is from an aggregator and unconfirmed against a primary source; the better-sourced figures are WAU doubling between 2026-01-01 and 2026-02-12 and a $2.5B run rate. None of them is the addressable market; OpenUsage's estimated 15,000–25,000 active Macs is.
- **The 15,000–25,000 OpenUsage install estimate** rests on two inferences about Sparkle download counts; two methods converged, it is still not a measured number.
- **Domain availability** is RDAP absence, not a registrar answer (above).
- **Chinese-market share of this audience** is an inference from CodeIsland's bilingual UI and Chinese developers' tool preferences; the zh-Hans localisation is shipped, so the question is now measurable from download and issue language once the app is public.
- **Not investigated:** an iOS or Watch companion (CodeIsland ships one; OpenUsage has an open request); undocumented rate limits on Anthropic's usage endpoint that would make 180 s risky for a reason other than the terms (the app backs off on 429, which is the only observable); whether Team/Enterprise Claude Code tokens answer the same endpoint; an Intel energy figure.
- **The `powermetrics` figure** needs sudo and a human at the keyboard; one command, in the README.
- **Bullet bars vs rings in the expanded panel** is closed unless a screenshot review reopens it; the panel already uses horizontal meters with the pace tick.

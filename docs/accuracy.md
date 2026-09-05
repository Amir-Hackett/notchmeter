# Accuracy

Every number Notchmeter shows is either a figure the vendor returned or an estimate built from a rule written down on this page. For each estimate this page states which files are read, which token buckets, which per-model prices and multipliers are applied, how duplicate lines are recognised, and exactly where the result is known to diverge from what the vendor bills. A golden-transcript test suite in the repository pins every rule, so a change in the numbers surfaces as a failing test rather than a surprise. Notchmeter does not show a number it cannot show its work for.

The Cost card carries every tool whose spend can be honestly derived, side by side; *Which tools report spend* below is the per-tool table, and the sections after it give each tool's rules in full. The Claude Code rules are those of Claude Code's own cost figure wherever Anthropic documents one. Primary sources, all read on 2026-09-01:

- [A] [Track cost and usage](https://code.claude.com/docs/en/agent-sdk/cost-tracking), Claude Agent SDK documentation.
- [B] [Manage costs effectively](https://code.claude.com/docs/en/costs), Claude Code documentation.
- [C] [Pricing](https://platform.claude.com/docs/en/about-claude/pricing), Claude Platform documentation.

The code is `Sources/Notchmeter/CostEngine.swift` (which tool is scanned, and the summary they add up to), `Sources/Notchmeter/ProviderCost.swift` (one tool's ranges, series, shares and source), `Sources/Notchmeter/CostCard.swift` (which tools the card carries, what each is worth in the range and the unit on show, and the donut's arcs), `Sources/Notchmeter/ClaudeCostScanner.swift` (Claude Code: reading, dedupe, digests, ranges, the daily history), `Sources/Notchmeter/ModelPricing.swift` (Anthropic prices, multipliers, overrides), `Sources/Notchmeter/CodexCostScanner.swift` and `Sources/Notchmeter/OpenAIPricing.swift` (Codex), and `Sources/Notchmeter/CursorProvider.swift` (Cursor's export). The tests are `Tests/NotchmeterTests/CostGoldenTests.swift`, `Tests/NotchmeterTests/CostBreakdownTests.swift`, `Tests/NotchmeterTests/CodexCostTests.swift`, `Tests/NotchmeterTests/CostEngineTests.swift`, `Tests/NotchmeterTests/CostCardTests.swift` and the `CostScanning` and `CursorRound*` suites in `Tests/NotchmeterTests/ProviderParsingTests.swift` and `Tests/NotchmeterTests/CursorParsingTests.swift`.

## Which tools report spend

The Cost card shows one row per tool whose spend can be derived from something that tool publishes: the tool, the source the figure came from, that tool's share of the range and its total. Each row carries its own ranges (today, yesterday, week, month, 30 and 90 days), its own daily series, its own per-model shares, its own freshness stamp and its own error. The figure in the middle of the donut is the rows added up, and the donut around it is one arc per row, in that tool's own colour and sized by that row's share of the range; with one tool reporting it is the single ring the card has always drawn. The rows and the arcs follow the assistant order set in Settings, the same order the panel's cards and the readouts beside the notch use. The three units apply across every tool at once: Cost is dollars, Tokens is tokens, and $/MTok is each tool's own dollars over its own tokens — never the range's tokens apportioned by cost, which would print the same blended rate on every row. Each tool's own card repeats its spend as a line of its own ("$118.31 today · $6,600 over 30 days · local transcripts"), from the same figures.

A tool whose spend cannot be derived from a real source has **no row at all**, and so no arc either. Not $0 — a zero says "this cost you nothing", which is a claim, and it would be a false one. Nothing on this card is ever inferred from a subscription price, a seat count or a request count. A tool that can report spend but spent nothing in the range on show is in the legend at its own $0 and out of the donut, because there is no arc to draw.

*In the Cost card* (Settings, beside *Cost card shows*) ticks which of the reporting tools the card carries; all of them are ticked to begin with, and a tool that cannot report spend is never offered. Leaving one out takes it out of the donut, the legend and the total together, so the card always describes one set of assistants; the tool's own card still shows its spend line. *Show total spend* hides the card and every spend line with it.

**The detail block is the leading tool's, not the total.** The figure in the ring, the donut and the legend are the whole card: every carried assistant added up. The lines under the legend — the hour and its burn multiple, the tokens and their cache-read share, the cache tiers, the folders, the Claude weekly window, the session block, "since first use", and the line saying what kind of number these are — describe the **first assistant in the card's order**, whichever one the user dragged to the top, and each names it ("Cursor last hour $2.10 · 1.4x its 30-day average"). A line the leader's source cannot answer is simply absent: Cursor's export is day resolution so a Cursor lead has no burn line, it carries no folder so it has no "Top:" line, and the 1-hour against 5-minute cache split, the 5-hour session block, "since first use" and the tokens-per-percent metering appear only when Claude Code itself leads, because they are distinctions only its transcripts record. Two lines stay totals and say so in code: the headline in the ring, and the month against a monthly budget, which is set against every carried assistant at once and has no per-tool share to print. Pinned by `CostCardTests`.

**A carried tool that reports nothing says why.** A tool that is visible in the panel, ticked under *In the Cost card* and able to report spend, but that produced no figure, gets one muted line under the legend naming the reason the app actually knows: *Also read Cursor's usage events* switched off, the tool's own read error where the read failed or went stale, "no sessions on this Mac yet" where the tool is set up but has written nothing local, and otherwise "no spend read yet". Silence there read as "this cost nothing", which is a claim; the line is the difference between no spend and no reading. Nothing is guessed — there is no fifth reason. Pinned by `CostCardTests`.

| Tool | Source | What it prices | What it does not | On the Cost card |
|---|---|---|---|---|
| **Claude Code** | `localTranscripts` — this Mac's transcripts, priced here at Anthropic's published rates | every request a transcript records: five token buckets, per model, per project, ×1.1 US residency, web search | contracted rates, cloud regional premiums, usage-credit rates, other Macs, claude.ai chat | dollars, an hour and a burn multiple |
| **Codex** | `localSessions` — this Mac's session rollouts, priced here at OpenAI's published rates | every turn a rollout records: fresh input, cached input, whole output, per model, per folder | what a ChatGPT plan already includes, a turn naming no model, a model with no published rate | dollars, an hour and a burn multiple |
| **Cursor** | `billingExport` — Cursor's own usage-events export (on by default, can be switched off) | nothing: every dollar is the one **Cursor itself** put on that event | anything Cursor left unpriced, and anything older than the 30 days the export returns | dollars, day resolution, no hour |
| **GitHub Copilot** | none | nothing | — | **no cost** |
| **Antigravity** | none | nothing | — | **no cost** |

**Why GitHub Copilot shows no cost.** A Copilot seat is a flat subscription — one monthly price whichever way the month goes — and nothing GitHub publishes prices a request. The endpoint the editor plugin reads returns a quota (`quota_snapshots.premium_interactions`: `entitlement`, `remaining`, `overage_count`), which is a count of requests, not money. Multiplying that count by the published overage rate would invent a bill for requests that were inside the allowance and cost nothing extra, so it is not done; the counts are shown as counts on the Copilot card and nowhere else. Organisation billing is the one place GitHub does return dollars (`usageItems[].netAmount` from `/orgs/{org}/settings/billing/usage/summary`, opt-in, org admins only). That figure is real and is shown, as GitHub's own, on the Copilot card — but it stays off the Cost card, because it is the whole organisation's month rather than this seat's, and it arrives as one month total with no per-day and no per-model detail, so it cannot honestly become a row beside the others.

**Why Antigravity shows no cost.** Antigravity meters quota, not money. The Code Assist endpoint returns per-model windows and the fraction of each that is used; it returns no price, and no token count that a published rate could be applied to. Gemini's API rates would not help either, because an Antigravity seat is not billed at API rates. There is nothing to derive a dollar figure from, so none is shown.

**Independence.** Each tool's scanner reads its own source, and the scanners run concurrently (`CostEngine.scan`). A Cursor export that is stale, refused or never fetched cannot delay or empty the Claude Code scan; a Mac with no Codex sessions simply has no Codex row; a tool switched off under Assistants is never scanned at all. Each row's timestamp is when *that* source was read, which is not when the app last drew the card, and a row whose read failed keeps its last figures and says what went wrong underneath. Pinned by `CostEngineTests`.

The sections from *What is read* to *The cache tier shift* are Claude Code's rules. Codex, Cursor, Copilot and Antigravity have their own sections further down.

## What is read

Claude Code keeps one JSONL transcript per session under `projects/` in its config directory. Notchmeter looks in `$CLAUDE_CONFIG_DIR`, `~/.config/claude` and `~/.claude`, and reads every `*.jsonl` under each `projects/` it finds, including the `subagents/*.jsonl` files written beside a session. Subagent requests are real API requests and are priced like any other; the `isSidechain` flag is not consulted. Two more kinds of root are read the same way: Claude Desktop's Cowork sessions in `~/Library/Application Support/Claude/local-agent-mode-sessions` (the same line format, in per-session folders; their project is reported as "Cowork"), and any folder the user adds under Settings › *Also read transcripts from* (a `projects` folder, or a flat folder of session folders, such as another Mac's logs synced in). The same roots feed the activity check that sets the polling cadence.

Only files whose modification time falls inside the 30-day window are opened. Within a file, a line is an entry when it contains `"usage":{` and parses with a `timestamp`, a `message.usage.input_tokens` and a `message.usage.output_tokens`; everything else (user turns, tool results, summaries, progress lines) is skipped. Each entry also keeps the line's `cwd` reduced to its last path component (else the project folder's name decoded from Claude Code's `-Users-me-Developer-notchmeter` encoding, whose last segment is the folder name; a folder with a hyphen in its name comes out as its last piece, which the line's `cwd` corrects), its `sessionId`, `usage.server_tool_use.web_search_requests` and `usage.speed`.

Per-file results are cached in `~/Library/Caches/Notchmeter/claude-usage-cache-v3.json`, keyed by path, size, modification time and the pricing fingerprint (the snapshot date plus any override); the version suffix is bumped whenever a parsing rule changes so entries parsed under an older rule are never reused. Each cached file carries a **digest**: its priced cost, five token counts, per-model cost and per-project cost in quarter-hour buckets. A scan folds every unchanged file from its digest and reads entries only from files touched inside the current 5-hour block, which is what the last-hour and block figures need at minute precision, so entries are kept beside the digest only while the file is that recent and are dropped, from the cache file and from memory, once it ages out (a month of transcripts held at entry level was most of the app's resident size, and none of it was read); everything longer (today, yesterday, month, 30 and 90 days) is built from the digests, and quarter hours keep every local day boundary exact because every time zone offset is a multiple of fifteen minutes. Deduplication (below) happens within a file before its digest is built; a streamed response never spans two files. The cache is written after the first full parse and then at most once every ten minutes, because rewriting a cache of this size on every scan while a session is appending to its transcript was the app's largest CPU cost (README, "Energy"); files parsed since the last write are parsed again on the next launch, which costs a few milliseconds. The cache holds timestamps, model ids, token counts, message and request ids, session ids, project folder names and the `inference_geo` and `speed` values, never any prompt or response text.

### The daily history

Claude Code deletes transcripts after its `cleanupPeriodDays`, and Notchmeter reads 30 days, so without more the 30-day figure would shrink as files go and nothing older than 30 days would ever be known. After each scan the app appends one JSON line per changed day to `~/Library/Caches/Notchmeter/daily-history-v1.jsonl` (day, tool, cost, the five token counts, per-model and per-project cost; never a path or a token). On read the newest line per day wins, and a day is taken from the history when the history's total is larger than what the transcripts now price to, because a deleted transcript can only lower the live figure, never the real one. The 90-day range, "Since <first day>" and the 90-day daily series come from this file merged with the live 30 days. The file is compacted to one line per day once it passes a few thousand lines.

## The token buckets

Each entry contributes five counts, taken from these fields of `message.usage`:

| Bucket | Field | Price |
|---|---|---|
| Input | `input_tokens` | base input rate |
| Output | `output_tokens` | output rate |
| 5-minute cache write | `cache_creation.ephemeral_5m_input_tokens`, else the flat `cache_creation_input_tokens` | 1.25 × base input |
| 1-hour cache write | `cache_creation.ephemeral_1h_input_tokens` | 2 × base input |
| Cache read | `cache_read_input_tokens` | 0.1 × base input (0.025 × on Fable 5.1 and Mythos 5.1) |

The cache multipliers are Anthropic's, from the prompt-caching table in [C]: a 5-minute cache write is *"1.25x base input price"*, a 1-hour cache write *"2x base input price"*, a cache read *"0.1x base input price (0.025x on Claude Fable 5.1 and Claude Mythos 5.1)"*, and *"These multipliers stack with other pricing modifiers, including the Batch API discount and data residency."* The two tiers matter on a subscription because, per [A], *"On a Claude subscription within your plan's included usage, you get the 1-hour TTL on your own turns, and on some of the helper requests Claude Code makes beside them, without setting this variable, and Claude Code drops those turns to the 5-minute TTL once you're drawing on usage credits."* When a transcript has only the flat `cache_creation_input_tokens` (older Claude Code versions), it is priced as a 5-minute write.

Thinking tokens need no bucket of their own: `output_tokens` already includes them and, per [B], *"Thinking tokens are billed as output tokens"*.

## Per-model rates

Dollars per million tokens, as coded in `ModelPricing.swift` from the table in [C] on 2026-09-01. Cache columns are derived from the base input rate with the multipliers above.

| Model id prefix | Input | Output | 5m write | 1h write | Cache read |
|---|---|---|---|---|---|
| `claude-fable-5-1`, `claude-mythos-5-1` | 10 | 50 | 12.50 | 20 | 0.25 |
| `claude-fable-5`, `claude-mythos-5` | 10 | 50 | 12.50 | 20 | 1.00 |
| `claude-opus-5`, `claude-opus-4-8`, `-4-7`, `-4-6`, `-4-5` | 5 | 25 | 6.25 | 10 | 0.50 |
| `claude-opus-4-1`, `claude-opus-4` | 15 | 75 | 18.75 | 30 | 1.50 |
| `claude-sonnet-5` | 2 | 10 | 2.50 | 4 | 0.20 |
| `claude-sonnet-4-6`, `-4-5`, `-4`, `claude-3-7-sonnet`, `claude-3-5-sonnet` | 3 | 15 | 3.75 | 6 | 0.30 |
| `claude-haiku-4-5` | 1 | 5 | 1.25 | 2 | 0.10 |
| `claude-3-5-haiku` | 0.80 | 4 | 1.00 | 1.60 | 0.08 |
| `claude-3-haiku` (no longer on the price page; kept for old transcripts) | 0.25 | 1.25 | 0.3125 | 0.50 | 0.025 |

Sonnet 5 is priced at $2/$10 because, per [C], *"The $2/$10 per million input/output token pricing for Claude Sonnet 5, announced at launch as introductory pricing through August 31, 2026, is now the standard price."*

**Fast mode.** A line whose `usage.speed` is `"fast"` on Opus 5 or Opus 4.8 is priced at $10/$50 per million, twice the standard rate, with the cache multipliers applied to the doubled input rate; every other model ignores the marker. The field is present on current transcripts (`"speed":"standard"` on the lines on this Mac).

**Overrides.** Two tables replace the built-in one, by normalised model prefix, longest prefix first: Claude Code's own `modelPricing` in `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`), so the estimate matches the figure Claude Code shows when a contracted table is in effect, and then Notchmeter's own `~/Library/Application Support/Notchmeter/pricing-overrides.json`, which wins on a clash. Both take `{"<model id>": {"input": 5, "output": 25, "cacheRead": 0.5, "cacheWrite": 6.25, "cacheWrite1h": 10}}` in dollars per million (snake_case and `_tokens` spellings are accepted; a missing cache rate derives from the input rate with the standard multipliers). An override changes the pricing fingerprint, so every cached digest is re-priced on the next scan. Pinned by `CostBreakdownTests`.

**Snapshot and freshness.** `Sources/Notchmeter/Resources/pricing-snapshot.json` is the same table as a document, dated; a unit test checks it against `ModelPricing.table` and `ModelPricing.snapshotDate`, and `.github/workflows/pricing.yml` fetches the pricing page weekly and diffs the per-model rows against the snapshot, so a price change fails a scheduled job rather than going unnoticed. The honest caveat: that job needs network access in CI and a page whose layout it can parse; when the page changes shape the job fails on a parse error, which is still a signal.

A model id is normalised before lookup: lower-cased, a Bedrock or Vertex prefix (`anthropic.`, `us.`, `eu.`) and a `@date` suffix are stripped, and the longest matching prefix wins, so `claude-opus-4-1-20250805` never matches `claude-opus-4`. An id that matches no prefix but names a known family (`fable`, `mythos`, `opus`, `sonnet`, `haiku`) is priced at that family's newest rate. That fallback is a guess made so a freshly released model prices roughly right until the table is updated; it is listed here so it is not mistaken for a fact.

## One entry per response

Claude Code writes a streamed response to the transcript as several lines, one per content block, each carrying the same `message.id`, the same `requestId` and the same `usage`. [A]: *"When Claude uses multiple tools in one turn, all messages in that turn share the same ID, so deduplicate by ID to avoid double-counting."*

Rule: lines are grouped by `message.id` + `requestId`; a line missing either is kept on its own. Within a group, the line whose `output_tokens` is largest is kept and the rest are dropped. Input and cache counts are identical across a group, so nothing else changes. The next section is why the largest, not the first.

## The output_tokens placeholder

[A] discloses that a line's output count is not what it looks like: *"Claude Code builds each assistant message from the usage the API reported when the response began, so the message's `output_tokens` is only the count the API had reported at `message_start`, before the response was generated. One API response can produce several assistant messages, and every one of them carries that same placeholder."* And: *"The API reports the real output count at the end of the response, and Claude Code adds it to the result message."* The result message is an SDK stream object, not a transcript line, so a transcript scanner cannot read it. What it can read is the last line Claude Code writes for a response after the stream has ended, which carries the same real count.

Measured on this machine on 2026-09-01, across the 3,501 transcripts touched in the previous 30 days: 31,115 response groups, 22,186 of them spanning several lines. In every one of those 22,186 the final line had the largest `output_tokens` and the earlier lines the placeholder, and in none did input or cache counts differ across the group. Keeping the first line of a group, which is what ccusage-derived tools do, would have counted 17,975,458 output tokens; keeping the last counts 24,339,282, 35% more.

What remains undercounted: a response that never finished (Claude Code interrupted, a crash, a network drop) has only placeholder lines, so its output tokens are counted at the `message_start` value, typically under ten, while its input and cache tokens are right. Such groups cannot be told apart from genuinely short replies, so no correction is attempted; on the machine above 4,969 groups had a best output count of ten or fewer, and some unknown share of those are cut-off responses.

## The residency multiplier

Anthropic bills US-only inference at a premium, and Claude Code models it. [C]: *"For Claude 4.6 and later models, specifying US-only inference through the `inference_geo` parameter incurs a 1.1x multiplier on all token pricing categories, including input tokens, output tokens, cache writes, and cache reads. Global routing (the default) uses standard pricing."* [A]: *"One billing rule the SDK does model is data residency pricing. When a response's `usage` reports `inference_geo: "us"`, the SDK multiplies the list price of that response's tokens by 1.1. Per-request fees such as web search aren't multiplied."* [B]: *"For a response from the Claude API billed at the 1.1× data residency rate, Claude Code multiplies the list price of that response's tokens by 1.1 in the session cost figure. … Before v2.1.239, Claude Code didn't apply the 1.1× to those responses, so the session cost figure was lower than the bill."*

Rule: when `message.usage.inference_geo` is exactly `"us"`, the line's five buckets are priced at list and the sum is multiplied by 1.1. Any other value (`"global"`, `"not_available"`, a missing field, or anything unrecognised) is priced at list. On a Claude subscription the field is written as `"not_available"`. Per [C], *"Earlier models do not support the `inference_geo` parameter and always use standard pricing"*, so a line for a model older than 4.6 never carries `"us"` and is never multiplied.

## Web search

Web search is a per-request fee, not a token rate. [C]: *"Web search is available on the Claude API for $10 per 1,000 searches, plus standard token costs for search-generated content."* Rule: `usage.server_tool_use.web_search_requests` × $0.01 is added to the line's token cost, after the residency multiplier, which per [A] never applies to per-request fees. Web fetches carry no fee. Pinned by `CostBreakdownTests.webSearchesArePricedPerRequestAndNeverMultiplied`.

## Lines with their own costUSD

A line may carry a `costUSD` (at the top level or inside `usage`); older Claude Code versions wrote it and the SDK still computes it. When present it is taken as the line's cost and no pricing is done, so the residency multiplier is never applied twice. Note [A]'s warning about the field: *"The `total_cost_usd` and `costUSD` fields are client-side estimates, not authoritative billing data. The SDK computes them locally from a price table bundled at build time, unless a `modelPricing` table is in effect."* Current Claude Code writes no `costUSD` into transcripts (none of roughly 140,000 usage lines on this machine had one), so in practice every line is priced here.

## Unknown and synthetic models

A line whose model is `<synthetic>` is a message Claude Code fabricated locally (an interrupted-turn notice, for instance); it contributes $0 and is not reported. A line whose model matches neither a prefix nor a family also contributes $0, and the model id is listed on the Cost card as "Unpriced: …" and in `--probe` output as `unpriced=[…]`, so a silent zero never hides a new model.

## The combined "All models" window

A plan that splits its allowance by model — Cursor Enterprise's "Cursor models" and "Other models", Anthropic's per-model weekly caps — can also show one derived window called **All models** (`CombinedWindow.swift`). It is the only window in the app that no vendor published, so it is tagged *inferred* on the card and captioned "Combined from the windows below", and it obeys rules that stop it claiming precision the source does not have:

- Only windows that publish a used fraction are combined. A window with no limit contributes nothing; it is never read as zero.
- Fewer than two model-scoped windows report and there is no combined window at all, so nothing synthetic appears where there is nothing to combine.
- Where the vendor already publishes the total those windows are shares of, **that figure is adopted exactly and never recomputed**. Cursor's "Included usage" *is* the plan total; adding "Cursor models" and "Other models" back together would round differently from Cursor's own arithmetic and disagree with the dashboard. A window counts as the total only when it is not scoped to a model, covers the same period and reset as every model window it would cover, and does not read below any of them — one that reads lower is not their parent, whatever else it is.
- With no such total, the figure is the **highest** of the model windows, never their mean. An average of a maxed-out model and an untouched one would show headroom that does not exist.
- The reset is the **soonest** among the windows covered, so the countdown never runs past the first cap to bite.
- No money is added up. The combined window carries no dollar figure: a share of a total and a dollar amount are not the same arithmetic, and summing shares across models would double-count the total's own dollars.

## When a vendor publishes two figures for one window

Cursor's usage summary answers the same question twice for its plan and team-pooled windows: `totalPercentUsed`, and the `used`/`limit` pair the note under the bar is written from. On most plans they agree to the cent. On Enterprise they need not — one account read `totalPercentUsed` 55 while `used` and `limit` were both $20, the whole allowance gone, with the two model splits beside it reading 47 % and 100 %.

**The window is as spent as its furthest-along figure says** (`CursorProvider.share`, pinned by `CursorParsing`). The account's own billing export is what settles it: Cursor marks a usage event `On-Demand` only once the included allowance is spent, and that account had 47 On-Demand events worth $116 in the very billing cycle the 55 % was reported for, and $2,306 in the cycle before it. Included was gone. A bar at 55 % said half an allowance remained while every third-party request was already being charged for.

Neither field can be shown to be the wrong one from inside a single reading, so the choice rests on which way it is safer to be wrong, and the two failures are not symmetric. Under-reporting a spent window hides a meter that is actively charging money — the exact thing this app exists to catch. Over-reporting one warns early.

Two things about Cursor's Enterprise shape remain **unknown and are not guessed at**:

- What `totalPercentUsed` is a percentage *of*. It is the figure cursor.com's own dashboard shows, so a user reconciling against the dashboard will see the meter disagree with it; that is accepted here in exchange for not under-reporting a spent cap.
- What the model splits are percentages *of*. `autoPercentUsed` 47 and `apiPercentUsed` 100 sum to 147, so they are not two shares of one total, and "Included usage" is not their parent. The billing export agrees from the other side: on the day of that reading, requests to Cursor's own models were still billed as Included while a third-party model's request went On-Demand — separate meters, not slices. The caption now says exactly that much and no more — *"Metered apart from the included total"* — where it used to say *"Share of the plan's included usage"*, which answered this question with a guess that the arithmetic rules out. What each figure is a percentage of stays unestablished, and nothing infers it.

The dollars are printed under the bar exactly as the summary gave them, so where the two figures disagree the disagreement stays visible on the card instead of being folded away into one number.

## When a reset is not a fixed instant

A window's reset is treated as a period, not a timestamp. Claude's windows arrive carrying a moment that moves on every read: three windows of one reading were observed a millisecond apart, and one window's reset wandered inside a two-second band across twenty minutes while its figure never moved — the signature of a moment recomputed from a remaining duration rather than quoted from a calendar. Compared exactly, the same period reads as a new one on every read.

So every comparison of two resets goes through `ResetPeriod.same`, which draws the line at ten minutes — the tolerance `NotificationScheduler` already used for a Codex snapshot whose reset is measured from when it was written. No real reset is ever that close to the one before it, because the shortest window the app meters is five hours. Exact comparison had four consequences, all silent: the drain log wrote a row for every window on every read however still the figure was (a few KB a day became a few hundred), `RunOutInterval` discarded every consecutive pair of rows as spanning a reset so no run-out estimate could form, `CombinedWindow` could not recognise a tool-wide window as the parent of its own model windows, and a watched reset was dropped and re-watched on each read. Pinned by `DrainLogRules`.

## Subscription and API billing

Claude Code's own figure is an API-price estimate and Anthropic says so. [B]: *"The Session block in `/usage` shows API token usage and is intended for API users. Claude Max and Pro subscribers have usage included in their subscription, so the session cost figure isn't relevant for billing purposes."* And: *"Claude Code computes the dollar figure locally from token counts at list price, unless a `modelPricing` table is in effect."*

What the Cost card means on each kind of account:

- **Pro, Max, Team, Enterprise seat.** Nothing here is a bill. The figure is the API-equivalent value of the work your sessions did, useful for pace, for comparing days and for judging what a plan is worth. Usage credits drawn past the plan limit are billed by Anthropic at its own rates; the card does not know which lines were inside the allowance and which drew credits.
- **API key or Console.** The figure is an estimate at list price. [B]: *"By default, Claude Code computes every cost figure it shows developers at list price, so if your organization pays contracted rates, the figures in `/usage`, the status line, and OpenTelemetry don't match your bill."* Notchmeter reads Claude Code's `modelPricing` table and its own overrides file (above), so contracted rates are modelled exactly when one of those carries them and not otherwise. The authoritative number is the Usage page in the Claude Console.
- **Bedrock, Vertex, Foundry.** Priced at Anthropic list. Partner platforms have their own price lists; per [C], *"Regional and multi-region endpoints include a 10% premium over global endpoints"* on Bedrock and Google Cloud, which is not modelled.

## Known divergences

Things a bill can contain that this estimate does not, in the order they are likely to matter:

1. **Interrupted responses** are output-undercounted, as described above.
2. **Contracted rates** (unless Claude Code's `modelPricing` or an override supplies them), **regional cloud premiums** and **usage-credit rates** as above.
3. **Price changes.** The table is a snapshot of [C] on 2026-09-01. Prices move; the golden tests will not notice a price change, only a change in how the code applies them. The weekly pricing workflow is what notices.
4. **Other machines and claude.ai.** Only transcripts on this Mac, plus the folders you add and Cowork's, are read; claude.ai chat is never priced.
5. **Currency.** Every figure is computed in US dollars; *Show costs in* converts with a rate the user types and a symbol from the locale. The rate is never fetched, so a converted figure is only as current as the rate.

Modelled since 2026-09-02, and so no longer divergences: the web-search fee and fast mode (above).

Token counts themselves are never estimated: every count comes from the API's own `usage` object as Claude Code recorded it, so tokenizer differences between models do not enter.

## Ranges, projects and the block

- **Today, Yesterday, 30 days, 90 days, Month** are calendar-day ranges in the local time zone, built from the digests and the daily history. Month is the calendar month to date.
- **Week** starts where the live Claude weekly window started (`seven_day.resets_at` minus seven days, from the last reading; the calendar week when there is none), built from the quarter-hour digests so the boundary is exact. "$1.58 per 1% of weekly" is the week's cost divided by the weekly window's used percentage from the same reading.
- **The block** is the current 5-hour window, aligned to `five_hour.resets_at` so the Cost card and the Session meter describe the same period, priced from entries; "tokens per minute" is the block's tokens over the minutes since its first entry.
- **By model** ranks the range's models by cost, the fifth and beyond folded into Other; **by project** does the same by folder name. The sparkline's tooltip names each day's top model.

## Burn rate

The Cost card's "Claude last hour $8.40 · 6x its 30-day average" line, which is the card's leading tool's own hour, and the Advice strip's "Claude Code burned $8.40 this hour — 6x its 30-day average." from three times up, are built from the same entries:

- **Last hour** is the priced sum of entries whose timestamp is within the past 60 minutes.
- **Typical hourly** is the mean priced cost of an active hour across the 30-day window: the window's total divided by its number of active hours, an active hour being any clock hour (UTC-aligned) with at least one entry. Hours you were not using Claude Code do not pull the average down. It was a median until 2026-09-02; agent work is bursty, most active hours cost cents and a few cost tens of dollars, so the median sat near zero and an ordinary hour read as "83x your usual". The mean is the figure the multiple is named after, and a burst is now measured against the whole month.
- **Burn multiple** is last hour ÷ typical hourly, shown with one decimal below ten ("2.3x") and none from ten up ("18x"). It is not shown until five active hours exist and the average is above zero, so a fresh install or an all-unpriced history never shows "∞x".

Each tool computes all three from its own entries and is named in its own line, so a hot hour says which tool was hot. Only a source whose entries carry a time of day can answer at all: Claude Code's transcripts and Codex's rollouts do, and Cursor's export is day-resolution, so Cursor reports no hour and never appears in a burn line. Where no single tool is over the line but every tool together is, one line is said for the total instead ("Every tool together burned $12.60 this hour — 3.4x your 30-day average"), and only when more than one tool is spending.

## Peak hours

Anthropic applies tighter session limits on weekdays between 05:00 and 11:00 Pacific. That window is reporting, not documentation: The Register described it on 2026-03-26 from Anthropic's announcement, and Anthropic's support article on usage limits does not publish the hours. So it is a preference (Settings › Advanced › Peak hours, on for Claude only by default, editable, off for every other vendor because none has announced one), not a constant the meter vouches for. What it changes: inside the window the session projection assumes the peak rate observed in the drain log; the advice names the next off-peak start for a long job ("Off-peak in 1h 20m: start the long job then"); and the run-out interval below keeps peak and off-peak rates apart when it has enough of each. Pinned by `PeakHoursTests`.

## The run-out interval

The even-burn projection and the last-hour drain both answer with one time. The interval answers with two, from the drain log: every hour of the last seven days in which the window moved gives a rate (used fraction per hour, from the log's rows, reset boundaries excluded); the 20th and 80th percentiles of those rates give the latest and the earliest run-out for what is left, and the card and the notification say "Runs out between 2:10 PM and 4:40 PM" when the two are more than an hour apart, or one time when they are not. Fewer than four rates give no interval, a run-out past the reset gives none, and with peak hours on and at least four rates on each side the estimate uses only the rates that match the current side of the boundary. It is a description of your own recent hours, not a model of the vendor's metering. Pinned by `RunOutTests`.

## Session metering

Anthropic meters the session window in something other than tokens, and the ratio moves: the same work costs a different share of the window on different days. Notchmeter measures the ratio it can see: the current 5-hour block's tokens (from the transcripts, aligned to `five_hour.resets_at`) divided by the session window's used percentage from the same reading, "1.1M tokens per 1% of session", recorded once a day in the daily-history file (`sessionTokensPerPercent`) and compared with the median of the last 30 days' values (at least five are needed). When today's figure is half the median or less, that is, the session is metering at least twice as heavily as usual, the Cost card says so and the Advice strip carries "The session is metering about 2.1x heavier than your norm"; the *When the cache tier or the metering shifts* notification fires for it once a day. A ratio under 2 % of the window used is not recorded, because the division is too noisy there.

## The cache tier shift

Per [A], a subscription gets the 1-hour cache TTL inside the plan's included usage and drops to the 5-minute tier once it draws on usage credits, and the 5-minute tier re-caches the prompt more often, which costs more per turn. The transcripts show which tier each write used (`ephemeral_1h_input_tokens` against `ephemeral_5m_input_tokens`), so the share of today's cache writes on the 1-hour tier is compared with the same share over the last 30 days; when today is at least 25 points lower and today has at least 100,000 cache-write tokens to judge by, the Cost card notes the shift and the Advice strip says "Cache writes today are 12% 1-hour against a 30-day norm of 64%". It is an observation of the tier, not of the credits: the transcripts do not say why the tier changed.

## The budget

A budget is one number over every tool, so the spend it is measured against is the total across the rows, not Claude Code's alone. Where more than one tool is spending, the advice names whichever is most of it — "At this rate the month costs $310 against a $200 budget. Claude Code is $240 of it." — because that is where a cut would come from.

A monthly or weekly budget (Settings › Usage display, in the currency shown) is treated as one more window: the month's spend over the budget is the used fraction, the calendar month (or the week from its start) is the period, the same pace tick applies, and the on-track, behind and run-out notifications fire for it with the month as their once-per-period memory. Its `source` is `localEstimate`, because both sides of the fraction are this Mac's arithmetic. The extra-usage notice ("Extra usage rose $4.20 in 1h while your plan has 87% left") reads the vendor's own extra-usage figure from the usage endpoint and says it once a month, louder while the plan still has room.

## Codex sessions

Codex writes one JSONL rollout per session under `$CODEX_HOME/sessions` (`~/.codex/sessions`, in dated folders). Every line is a `RolloutLine`: a `timestamp`, a `type` and a `payload`. Four types are read and the rest of the file — the conversation itself — is never parsed. The shapes below were read from the codex-rs source on 2026-09-02, at [`codex-rs/protocol/src/protocol.rs`](https://raw.githubusercontent.com/openai/codex/main/codex-rs/protocol/src/protocol.rs), [`codex-rs/history/src/rollout_payload.rs`](https://raw.githubusercontent.com/openai/codex/main/codex-rs/history/src/rollout_payload.rs) and [`codex-rs/history/src/lib.rs`](https://raw.githubusercontent.com/openai/codex/main/codex-rs/history/src/lib.rs):

| Line `type` | What is taken | Rust type |
|---|---|---|
| `turn_context` | `payload.model` (the model the turn ran on) and `payload.cwd` reduced to its last path component (the project) | `TurnContextItem` |
| `session_meta` | `payload.cwd`, as the project until a `turn_context` names one | `SessionMetaLine` |
| `token_usage_record` | `payload.usage` (the turn's own usage) and `payload.response_id` | `TokenUsageRecord` |
| `event_msg` with `payload.type == "token_count"` | `payload.info.last_token_usage` | `TokenCountEvent` → `TokenUsageInfo` |

A `TokenUsage` carries `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens` and `total_tokens`. Two of those relationships decide the arithmetic, and both are the source's own:

- **`input_tokens` includes the cached tokens.** codex-rs computes `non_cached_input()` as `input_tokens - cached_input()`. So the billed fresh input is `input_tokens − cached_input_tokens`, and the cached part is priced at the cached rate. Counting `input_tokens` whole would charge the cached tokens twice.
- **`reasoning_output_tokens` is inside `output_tokens`.** codex-rs prints `output={output_tokens} (reasoning {reasoning_output_tokens})` and its `blended_total()` is `non_cached_input + output_tokens`, with reasoning never added on top. So output is taken whole and reasoning is not added again.
- **`cache_write_input_tokens` is carried into the cache-write bucket.** Whether writing the cache costs anything depends on the model, and the rule is under *Cache writes* below.

`token_usage_record` is the per-response record and is what a current build writes. Where a file has any, the `token_count` events in the same file are ignored, because they describe the same turns; a file that has only events (an older build) is priced from each event's `last_token_usage`, which is the turn that just finished, so the events sum to the session rather than to a running total counted repeatedly. Resuming a thread replays the turns it inherited under the same `response_id`, so one entry per response id is kept and the first wins.

**The rates.** OpenAI list prices per million tokens, read on **2026-09-02** from [developers.openai.com/api/docs/pricing](https://developers.openai.com/api/docs/pricing) (to which platform.openai.com/docs/pricing now redirects), from the per-model page under `developers.openai.com/api/docs/models/<id>` for the Codex ids that page does not list, and from the [prompt-caching guide](https://developers.openai.com/api/docs/guides/prompt-caching) for the cache-write rule. These are the **standard** tier: Batch, Flex, Priority and Fast mode are separate published tables, and a rollout does not record which one a turn ran on. `OpenAIPricing.fingerprint` is the snapshot date *and* a digest of the rows themselves, and it is part of the cache key, so day records priced under other rates are never reused — including after a rate is corrected on the same day the snapshot was taken.

| Model | Input | Cached input | Cache write | Output | >272K tier |
|---|---|---|---|---|---|
| gpt-5.6-sol | $4.00 | $0.40 | $5.00 | $20.00 | yes |
| gpt-5.6-terra | $2.00 | $0.20 | $2.50 | $12.00 | yes |
| gpt-5.6-luna | $0.20 | $0.02 | $0.25 | $1.20 | yes |
| gpt-5.6-cyber | $12.50 | $1.25 | $15.625 | $75.00 | yes |
| gpt-5.5-cyber | $12.50 | $1.25 | not billed | $75.00 | — |
| gpt-5.5 | $5.00 | $0.50 | not billed | $30.00 | yes |
| gpt-5.5-pro | $30.00 | — | not billed | $180.00 | yes |
| gpt-5.4 | $2.50 | $0.25 | not billed | $15.00 | yes |
| gpt-5.4-mini | $0.75 | $0.075 | not billed | $4.50 | — |
| gpt-5.4-nano | $0.20 | $0.02 | not billed | $1.25 | — |
| gpt-5.4-pro | $30.00 | — | not billed | $180.00 | yes |
| gpt-5.3-codex | $1.75 | $0.175 | not billed | $14.00 | — |
| gpt-5.2, gpt-5.2-codex | $1.75 | $0.175 | not billed | $14.00 | — |
| gpt-5.2-pro | $21.00 | — | not billed | $168.00 | — |
| gpt-5.1, gpt-5.1-codex | $1.25 | $0.125 | not billed | $10.00 | — |
| gpt-5.1-codex-mini | $0.25 | $0.025 | not billed | $2.00 | — |
| gpt-5, gpt-5-codex | $1.25 | $0.125 | not billed | $10.00 | — |
| gpt-5-mini | $0.25 | $0.025 | not billed | $2.00 | — |
| gpt-5-nano | $0.05 | $0.005 | not billed | $0.40 | — |
| gpt-5-pro | $15.00 | — | not billed | $120.00 | — |
| gpt-4.1 | $2.00 | $0.50 | not billed | $8.00 | — |
| gpt-4.1-mini | $0.40 | $0.10 | not billed | $1.60 | — |
| gpt-4.1-nano | $0.10 | $0.025 | not billed | $0.40 | — |
| o3 | $2.00 | $0.50 | not billed | $8.00 | — |
| o3-pro | $20.00 | — | not billed | $80.00 | — |
| o3-mini | $1.10 | $0.55 | not billed | $4.40 | — |
| o4-mini | $1.10 | $0.275 | not billed | $4.40 | — |

**How an id finds its row.** By **exact match on the id**, never by prefix. A `provider/model` id is reduced to the part after the slash and the id is lower-cased first, and a trailing date snapshot is stripped (`gpt-5-mini-2025-08-07` → `gpt-5-mini`) because the page lists a dated id and the id it snapshots at the same price. Nothing else is rewritten, so an id the table does not hold cannot land on a shorter row that happens to be a prefix of it: `gpt-5.6-nova` is not priced as `gpt-5.6`, and `gpt-5.4-cyber` is not priced as `gpt-5.4`. Until 2026-09-02 the lookup was a prefix scan in table order and did exactly that, which is why `unlistedIdsAreNamedRatherThanCollapsed` now pins every id in the table resolving to its own row and a set of unlisted family members resolving to none. Where the page prices no cached rate (the `pro` tiers, which do not serve the prompt cache) the input rate is used for cached tokens too, so a cached count that should never arrive cannot come out cheaper than it was. Each `-codex` id carries the row **its own model page** publishes; the pricing table lists only `gpt-5.3-codex`, and nothing is inferred from the numbered model a Codex variant is built on.

**Cache writes.** The prompt-caching guide states them per family: "For GPT-5.6 and later, cache writes cost 1.25× the standard, uncached input-token rate", and "No additional cache-write charge" for "GPT-5.5 and GPT-5.5 Pro" and "Other earlier models". So the write bucket is billed on the four gpt-5.6 rows and at nothing on every other row, and each of those four published write rates is that rule's own arithmetic ($4.00 → $5.00, $2.00 → $2.50, $0.20 → $0.25, $12.50 → $15.625), which is the cross-check `cacheWritesAreBilledOnlyFromGPT56AndAt125xInput` pins.

**The long-context tier.** Above 272,000 input tokens on a model that publishes the tier, the whole request is priced at 2x every input bucket and 1.5x output. Seven rows publish their long-context rates in full (sol, terra, luna, gpt-5.5, gpt-5.5-pro, gpt-5.4, gpt-5.4-pro) and those two multipliers reproduce all seven exactly, which is what `theLongContextTierMatchesThePublishedRows` pins. gpt-5.6-cyber is the one id where the tier comes from prose rather than a row: its own model page states the >272K rule while the pricing table leaves its long-context columns empty, and the rule is applied. **gpt-5.5-cyber has neither** — no long-context row and no model page left to read — so a turn of it over 272K is priced at its published short rates, and would be under-reported if OpenAI in fact bills it the tier. No other row carries a threshold at all, so no other model can pick up a surcharge nothing published for it.

**What is not priced.** Four gaps, all visible rather than filled in:

- A turn whose rollout never named a model is counted in tokens and priced at nothing, and the card says so ("1 Codex turn(s) name no model and are not priced") rather than showing a confident $0.
- A model id the table does not hold contributes nothing and is named under "Unpriced: …". `gpt-5.4-cyber` is the live example — OpenAI publishes it with a dash in every column, so there is no rate to apply — and it is the fixture `anUnpricedModelCostsNothingAndIsNamed` uses.
- Only the standard tier is priced. A turn that ran under Batch, Flex, Priority or Fast mode is priced at the standard rate, because the rollout does not say which tier it used; Fast mode is roughly twice standard (`gpt-5.3-codex` is $3.50 / $28.00 there), so such a turn is under-reported rather than over.
- A write to the prompt cache on a row that publishes no write rate costs nothing here, which is what the caching guide says of every family before GPT-5.6.

**What this figure is not.** It is the API-equivalent value of the work the sessions did, at list price. A ChatGPT Plus, Pro or Business plan includes Codex usage in the subscription, so on those plans nothing here is a bill and the figure is a measure of pace and of what the plan is worth. On an API key it is an estimate at list price; contracted rates, Batch and Flex discounts and any credit are not modelled.

**With no sessions.** This Mac has no Codex sessions at all, so the whole path is exercised by unit tests over synthetic rollouts written in the shape above (`CodexCostTests`), and a Mac with no `sessions` folder produces no Codex row — not $0. The first live run against real rollouts is a user's.

Day totals are appended to the same daily-history file Claude Code uses, under the `codex` tool key, so a day survives Codex deleting its rollouts. As there, a day is taken from the history when the history's total is larger than what the rollouts now price to.

## Cursor's usage events

With *Also read Cursor's usage events* on (on by default; it can be switched off in Settings), a second read of cursor.com on the same session cookie (`POST /api/dashboard/get-filtered-usage-events`, the request the dashboard's usage page makes) returns the last 30 days of usage events with the cost Cursor itself assigns to each. **Nothing is priced here.** Every dollar on the Cursor row is the one Cursor put on that event, which is why the row's source reads "billing export" rather than an estimate, and why a request or a model Cursor left unpriced stays unpriced instead of being valued at somebody else's rates.

Events are folded by local day into the daily-history file under the `cursor` tool key — cost, tokens, and cost and tokens per model where the event names one — and read back as a full row on the Cost card: today, yesterday, the week, the month, 30 and 90 days, the daily trend under the Cursor card, and the per-model shares in the range's breakdown.

Two limits are worth stating. The export is **day resolution**: an event carries a day, not an hour that can be trusted for a last-hour figure, so Cursor reports no hour and takes no part in the burn line. And the export reaches back **30 days**; the 90-day range and anything older is whatever the daily-history file has accumulated since Notchmeter was installed, and is short until it has been running that long.

The fetch happens on the Cursor provider's own polling loop, and the Cost card reads only the file it writes, so a slow, refused or expired Cursor read never delays a cost scan: the row keeps its last figures, its timestamp stays at the last successful read, and the failure is printed under the row. The endpoint is undocumented, its shape was taken from the dashboard's own traffic and pinned in `CursorParsingTests`, and this Mac's free plan returns no events, so the first live run with a paid plan is a user's.

## GitHub Copilot and Antigravity: no cost at all

Both are absent from the Cost card, and the reasons are in *Which tools report spend* above: Copilot is a flat seat whose API publishes a request quota rather than a price, and its one real dollar figure is an org-wide monthly total with no per-day or per-model detail, shown on the Copilot card as GitHub's own; Antigravity publishes quota fractions and no money or token count at all. Neither has a number that could be turned into a daily series without inventing it, so neither has a row. `CostEngineTests` pins that `ToolID.reportsCost` is true for exactly Claude Code, Codex and Cursor, so a future tool cannot quietly acquire a made-up figure.

## The golden tests

`Tests/NotchmeterTests/CostGoldenTests.swift` feeds transcript excerpts, written inline as JSONL, through the same `parseFile → dedupe → summarize` path the app uses, with a fixed `now`, and pins each total to nine decimal places:

| Fixture | Rule under test | Pinned total |
|---|---|---|
| Line carrying `costUSD: 0.42` with `inference_geo: "us"` | own cost wins, no multiplier | $0.42 |
| Sonnet 5 line with 5m and 1h cache tiers | five buckets at list | $0.0275 |
| Opus 4.6 line with `inference_geo: "us"` | ×1.1 on every bucket | $0.14575 |
| Three lines of one Fable 5.1 response (output 3, 3, 1090) | keep the real output count | $0.1095 (not $0.05515) |
| `<synthetic>` line | $0, not listed | $0 |
| `claude-nimbus-1` line | $0, listed as unpriced | $0 |
| Sonnet 5 line 53 days old | outside the window | $0 |
| All of the above in one transcript | sum, last hour, unpriced set | $0.70275 total, $0.67525 in the last hour |

The same file unit-tests the residency multiplier, the dedupe choice, the average active hour (including the bursty month a median gets wrong) and the burn multiple's five-hour and non-zero guards, and the `CostScanning` suite in `ProviderParsingTests.swift` covers cache-tier parsing, model-id normalisation and day bucketing. These totals are pinned and do not move: adding the other tools to the Cost card changed none of them.

`CodexCostTests` does the same for Codex over synthetic rollouts — $0.0329 for a 10,000-input/8,000-cached/2,000-output `gpt-5.3-codex` turn, $0.011375 for the `gpt-5.1-codex` fallback, a replayed `response_id` counted once, an event-only rollout, a cache write priced at nothing, an unknown model at $0 and named, and a turn with no model at $0 with a reason. `CostEngineTests` pins that the top figures are the rows added up, that a tool with nothing to say leaves the others alone, and that a failed vendor read keeps its own timestamp and error without touching another tool's scan. Run them with `scripts/test.sh`.

## Reproducing a number

From the terminal, without the app running and without a Keychain prompt:

```bash
swift run Notchmeter --probe --no-prompt
```

The last lines are the cost summary, the totals first and then one clause per tool that reported spend: `cost: today $… yesterday $… 30d $… last hour $… (Nx the 30-day average $… per active hour) … claude today $… 30d $… (localTranscripts) codex today $… 30d $… (localSessions) unpriced=[…]`. A tool with no clause reported nothing, which is not the same as reporting zero. To check a single transcript by hand, list its priced lines and apply the rules above:

```bash
jq -c 'select(.message.usage) | [.timestamp, .message.id, .requestId, .message.model, .message.usage]' \
  ~/.claude/projects/<project>/<session>.jsonl
```

Group by the id and request id columns, keep the line with the largest `output_tokens` in each group, price the five buckets from the table, multiply by 1.1 where `inference_geo` is `"us"`, and sum. Claude Code's `/usage` Session block will not match this figure and is not meant to: it covers one session since its last `/clear`, while the card covers every transcript on the Mac for the day.

## Why there is no header fallback

Anthropic attaches rate-limit headers to some responses for OAuth accounts: `anthropic-ratelimit-unified-5h-utilization` and `-7d-utilization` (a 0–1 fraction of the window), `-5h-reset` and `-7d-reset` (epoch seconds), plus `-overage-utilization` and `-representative-claim`. They describe the same Session and Weekly windows the usage endpoint reports, so they look like a way to keep the meter alive if the usage endpoint ever changes.

Checked on 2026-09-01 against [OpenUsage issue #1098](https://github.com/robinebers/openusage/issues/1098), which records the requests and their responses verbatim:

- `GET https://api.anthropic.com/api/oauth/usage` (with `anthropic-beta: oauth-2025-04-20`) does **not** carry the headers. Its answer is the JSON body Notchmeter already parses.
- `POST https://api.anthropic.com/v1/messages/count_tokens` does **not** carry them either.
- The headers arrive only on `POST https://api.anthropic.com/v1/messages`, the inference endpoint. The probe recorded there sends a Haiku request with `max_tokens: 0`, and the issue measures it at roughly eight input tokens of Haiku per call.

So the only request that yields the headers is an inference request made with Claude Code's OAuth token. That is exactly the call Notchmeter promises never to make: it consumes model capacity, it would appear in Anthropic's records as third-party inference with a Claude Code credential, which the [Claude Code legal page](https://code.claude.com/docs/en/legal-and-compliance) restricts and Anthropic began enforcing server-side in 2026, and it would move the very Session number the meter reports. Eight tokens per poll is small, but the meter's standing rests on being read-only, and there is no read-only request that returns the headers.

OpenUsage itself does not read them: its `ClaudeUsageClient.swift` fetches the usage endpoint and the profile endpoint only, its `ClaudeUsageMapper.swift` maps the JSON body, and the fallback it ships for tokens without the `user:profile` scope is its local transcript scanner for spend, not a header probe (both files read from `main` on 2026-09-01).

What Notchmeter does instead, in `ClaudeProvider.swift`:

- Every response from the usage endpoint is checked for the unified headers (`rateLimitWindows(from:)`, unit-tested in `ProviderParsingTests.swift`). If the JSON body is missing or unreadable but the headers are present, the Session and Weekly windows are built from the headers and the meters carry the note "From rate-limit headers"; per-model weekly limits and extra usage are unavailable in that mode. Today this path never fires, because the endpoint does not send the headers; it is there so that a change on Anthropic's side degrades to coarser numbers rather than to an error.
- If the usage endpoint answers with an error and no headers, the meter reports the error and waits. It does not probe `/v1/messages`.

Should Anthropic publish a read-only endpoint that returns the headers, or add them to the usage endpoint's response, the parser is already in place.

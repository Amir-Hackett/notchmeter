# Accuracy

Every number Notchmeter shows is either a figure the vendor returned or an estimate built from a rule written down on this page. For each estimate this page states which files are read, which token buckets, which per-model prices and multipliers are applied, how duplicate lines are recognised, and exactly where the result is known to diverge from what the vendor bills. A golden-transcript test suite in the repository pins every rule, so a change in the numbers surfaces as a failing test rather than a surprise. Notchmeter does not show a number it cannot show its work for.

The rules below are those of Claude Code's own cost figure wherever Anthropic documents one. Primary sources, all read on 2026-09-01:

- [A] [Track cost and usage](https://code.claude.com/docs/en/agent-sdk/cost-tracking), Claude Agent SDK documentation.
- [B] [Manage costs effectively](https://code.claude.com/docs/en/costs), Claude Code documentation.
- [C] [Pricing](https://platform.claude.com/docs/en/about-claude/pricing), Claude Platform documentation.

The code is `Sources/Notchmeter/ClaudeCostScanner.swift` (reading, dedupe, summing) and `Sources/Notchmeter/ModelPricing.swift` (prices and multipliers). The tests are `Tests/NotchmeterTests/CostGoldenTests.swift` and the `CostScanning` suite in `Tests/NotchmeterTests/ProviderParsingTests.swift`.

## What is read

Claude Code keeps one JSONL transcript per session under `projects/` in its config directory. Notchmeter looks in `$CLAUDE_CONFIG_DIR`, `~/.config/claude` and `~/.claude`, and reads every `*.jsonl` under each `projects/` it finds, including the `subagents/*.jsonl` files written beside a session. Subagent requests are real API requests and are priced like any other; the `isSidechain` flag is not consulted.

Only files whose modification time falls inside the 30-day window are opened. Within a file, a line is an entry when it contains `"usage":{` and parses with a `timestamp`, a `message.usage.input_tokens` and a `message.usage.output_tokens`; everything else (user turns, tool results, summaries, progress lines) is skipped. Per-file results are cached in `~/Library/Caches/Notchmeter/claude-usage-cache-v2.json`, keyed by path, size and modification time; the `-v2` suffix is bumped whenever a parsing rule changes so entries parsed under an older rule are never reused. The cache holds timestamps, model ids, token counts, message and request ids and the `inference_geo` value, never any prompt or response text.

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

## Lines with their own costUSD

A line may carry a `costUSD` (at the top level or inside `usage`); older Claude Code versions wrote it and the SDK still computes it. When present it is taken as the line's cost and no pricing is done, so the residency multiplier is never applied twice. Note [A]'s warning about the field: *"The `total_cost_usd` and `costUSD` fields are client-side estimates, not authoritative billing data. The SDK computes them locally from a price table bundled at build time, unless a `modelPricing` table is in effect."* Current Claude Code writes no `costUSD` into transcripts (none of roughly 140,000 usage lines on this machine had one), so in practice every line is priced here.

## Unknown and synthetic models

A line whose model is `<synthetic>` is a message Claude Code fabricated locally (an interrupted-turn notice, for instance); it contributes $0 and is not reported. A line whose model matches neither a prefix nor a family also contributes $0, and the model id is listed on the Cost card as "Unpriced: …" and in `--probe` output as `unpriced=[…]`, so a silent zero never hides a new model.

## Subscription and API billing

Claude Code's own figure is an API-price estimate and Anthropic says so. [B]: *"The Session block in `/usage` shows API token usage and is intended for API users. Claude Max and Pro subscribers have usage included in their subscription, so the session cost figure isn't relevant for billing purposes."* And: *"Claude Code computes the dollar figure locally from token counts at list price, unless a `modelPricing` table is in effect."*

What the Cost card means on each kind of account:

- **Pro, Max, Team, Enterprise seat.** Nothing here is a bill. The figure is the API-equivalent value of the work your sessions did, useful for pace, for comparing days and for judging what a plan is worth. Usage credits drawn past the plan limit are billed by Anthropic at its own rates; the card does not know which lines were inside the allowance and which drew credits.
- **API key or Console.** The figure is an estimate at list price. [B]: *"By default, Claude Code computes every cost figure it shows developers at list price, so if your organization pays contracted rates, the figures in `/usage`, the status line, and OpenTelemetry don't match your bill."* Notchmeter has no `modelPricing` equivalent, so contracted rates are not modelled either. The authoritative number is the Usage page in the Claude Console.
- **Bedrock, Vertex, Foundry.** Priced at Anthropic list. Partner platforms have their own price lists; per [C], *"Regional and multi-region endpoints include a 10% premium over global endpoints"* on Bedrock and Google Cloud, which is not modelled.

## Known divergences

Things a bill can contain that this estimate does not, in the order they are likely to matter:

1. **Interrupted responses** are output-undercounted, as described above.
2. **Web search** is a per-request fee. [C]: *"Web search is available on the Claude API for $10 per 1,000 searches, plus standard token costs for search-generated content."* The count is present as `usage.server_tool_use.web_search_requests` and is not priced.
3. **Fast mode** (`speed: "fast"`) bills Opus 5 and Opus 4.8 at $10/$50 per million instead of $5/$25 per [C]; lines are priced at the standard rate regardless of `speed`.
4. **Contracted rates**, **regional cloud premiums** and **usage-credit rates** as above.
5. **Price changes.** The table is a snapshot of [C] on 2026-09-01. Prices move; the golden tests will not notice a price change, only a change in how the code applies them.
6. **Other machines and claude.ai.** Only transcripts on this Mac are read.

Token counts themselves are never estimated: every count comes from the API's own `usage` object as Claude Code recorded it, so tokenizer differences between models do not enter.

## Burn rate

The Cost card's "Last hour $8.40 · 6x your usual" line is built from the same entries:

- **Last hour** is the priced sum of entries whose timestamp is within the past 60 minutes.
- **Typical hourly** is the median priced cost of an active hour across the 30-day window, an active hour being any clock hour (UTC-aligned) with at least one entry. Hours you were not using Claude Code do not pull the median down.
- **Burn multiple** is last hour ÷ typical hourly. It is not shown until five active hours exist and the median is above zero, so a fresh install or an all-unpriced history never shows "∞x".

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

The same file unit-tests the residency multiplier, the dedupe choice, the median and the burn multiple's five-hour and non-zero guards, and the `CostScanning` suite in `ProviderParsingTests.swift` covers cache-tier parsing, model-id normalisation and day bucketing. Run them with `scripts/test.sh`.

## Reproducing a number

From the terminal, without the app running and without a Keychain prompt:

```bash
swift run Notchmeter --probe --no-prompt
```

The last lines are the cost summary: `cost: today $… yesterday $… 30d $… last hour $… (Nx the usual $… per active hour) unpriced=[…]`. To check a single transcript by hand, list its priced lines and apply the rules above:

```bash
jq -c 'select(.message.usage) | [.timestamp, .message.id, .requestId, .message.model, .message.usage]' \
  ~/.claude/projects/<project>/<session>.jsonl
```

Group by the id and request id columns, keep the line with the largest `output_tokens` in each group, price the five buckets from the table, multiply by 1.1 where `inference_geo` is `"us"`, and sum. Claude Code's `/usage` Session block will not match this figure and is not meant to: it covers one session since its last `/clear`, while the card covers every transcript on the Mac for the day.

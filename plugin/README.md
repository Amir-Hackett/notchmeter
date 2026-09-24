# Notchmeter for Claude Code

This folder is the whole Claude Code plugin: the manifest in [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) and one skill, [`skills/notchmeter/SKILL.md`](skills/notchmeter/SKILL.md). The rest of the repository is the macOS app the plugin talks to.

## What it does

- **The `notchmeter` skill.** Before long work, or when you ask how much quota is left, Claude runs `notchmeter --json` and reads back the usage windows of Claude Code (session, weekly and per-model), Codex, Cursor, Antigravity / Gemini CLI and GitHub Copilot, the local Claude Code cost estimate, and Notchmeter's advice ("switch models, not tools", "wait for the reset at 4:10 PM").
- **The `get_limits` MCP tool.** The plugin starts `notchmeter --mcp`, a stdio MCP server with one tool that answers with the same JSON object.

## Requirements

- macOS 15 or later, with [Notchmeter](https://www.notchmeter.com) installed (the DMG from [GitHub Releases](https://github.com/Amir-Hackett/notchmeter/releases/latest), or Homebrew: `brew tap Amir-Hackett/tap && brew trust --cask Amir-Hackett/tap/notchmeter && brew install --cask notchmeter`).
- The `notchmeter` command on your PATH: Settings › General › *Install command line tool…* links it into `~/.local/bin` or `/usr/local/bin`, and the Homebrew cask links it too. Without it the MCP server does not start (Claude Code says so in `/mcp`); the skill falls back to the app's own executable.

## Install

In Claude Code:

```text
/plugin marketplace add Amir-Hackett/notchmeter
/plugin install notchmeter@notchmeter
```

The plugin installs no hook and no status line, and writes nothing into `~/.claude/settings.json`.

## What it reads and sends

With the app running, the command answers from the app's cached report and sends nothing. Only when the app is not running, or on `notchmeter --force`, does it read afresh: it uses the logins your AI tools already saved on this Mac to make one read-only request to each tool's own usage endpoint (never an inference request), and prices Claude Code's local transcripts from their usage lines. No token is printed, stored or sent anywhere else, and there is no telemetry. The full account is in the [privacy policy](https://www.notchmeter.com/privacy.html).

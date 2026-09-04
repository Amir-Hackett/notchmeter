# Security policy

Notchmeter reads the saved logins of five vendors' tools and sends each token to exactly one place, the usage endpoint of the vendor that issued it (README, "Privacy and terms"). Anything that widens that is a security issue, whether or not it is exploitable today.

## Supported version

The latest release on the Releases page, and `main`. Older releases are not patched; update instead.

## Reporting

Report privately, not as a public issue:

- **GitHub private vulnerability reporting**, once it is enabled for the repository: Security › Report a vulnerability. This is the preferred route.
- Otherwise, email the author at the address on the GitHub profile (github.com/Amir-Hackett), with "Notchmeter security" in the subject.

Include what you found, the version (`Settings › Version`, or `--smoke`'s first line), and how to reproduce it. A fix or a response comes within seven days; a fix for a token-exposure class of issue ships as a point release with the finding credited unless you ask otherwise.

## What counts

- **Token exposure.** A token, cookie or credential appearing anywhere but the vendor request it belongs to: the unified log, `--probe` output, the oracle file, the report file, a crash, a screenshot, an image copied to the clipboard, the drain log, the daily-totals file, the diagnostics text.
- **Network destinations beyond the listed ones.** Any request to a host other than the five vendors' endpoints named in the README (and GitHub Releases for the signed build's update check). A proxy the user set in Settings is theirs; a proxy the app chose is not.
- **The local API.** Anything that lets a web page, another user on the Mac, or a remote host read the report or post a hook without the user having turned the API on and, for web origins, allowed that origin (LocalAPI.swift refuses foreign `Host` and unlisted `Origin` headers).
- **Writes outside the app's own folders.** The app writes `~/Library/Caches/Notchmeter`, `~/Library/Application Support/Notchmeter`, its own preferences domain, `~/Library/Sounds` (only when the user imports a sound), the symlink the user asks for under `~/.local/bin` or `/usr/local/bin`, and, only on the user's button press or the launch-time repair of its own stale or out-of-date entry, the assistants' hook files, each after a backup: `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`), Codex's `hooks.json` (`$CODEX_HOME`, `~/.config/codex` or `~/.codex`; never `config.toml`), `~/.cursor/hooks.json`, `~/.gemini/settings.json` (or under `$GEMINI_CLI_HOME`; refused, not rewritten, when it is not strict JSON) and `~/.copilot/hooks/notchmeter.json` (or under `$COPILOT_HOME`), the last being the one file Notchmeter owns outright. Anything else is a bug.
- **The hook and status-line commands** doing more than they say, for every assistant's hook (Claude Code, Codex, Cursor, Gemini CLI, GitHub Copilot CLI; docs/hooks.md lists every field forwarded and, per assistant, every field that is never read), or a ring asserting a wait, a finish or a limit that no documented event of that assistant proves.

Out of scope: the vendors' own services and terms; a Mac already compromised at the user level (the tokens are readable there by design, that is where the tools keep them); denial of service against the loopback API by a local process.

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
- **Writes outside the app's own folders.** The app writes `~/Library/Caches/Notchmeter`, `~/Library/Application Support/Notchmeter`, its own preferences domain, `~/Library/Sounds` (only when the user imports a sound), the symlink the user asks for under `~/.local/bin` or `/usr/local/bin`, and, only on the user's button press or the launch-time repair of its own stale entry, `~/.claude/settings.json` after a backup. Anything else is a bug.
- **The hook and status-line commands** doing more than they say (docs/hooks.md lists every field forwarded).

Out of scope: the vendors' own services and terms; a Mac already compromised at the user level (the tokens are readable there by design, that is where the tools keep them); denial of service against the loopback API by a local process.

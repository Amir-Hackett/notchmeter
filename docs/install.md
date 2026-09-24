# Installing and building

The [README](../README.md) has the two install routes; this page adds testing a pre-release build, building from source and what the first launch asks for.

## Install


- **Download** [`Notchmeter.dmg`](https://github.com/Amir-Hackett/notchmeter/releases/latest/download/Notchmeter.dmg) from the latest release and drag it to Applications. The DMG is Developer ID signed and notarised, and the app updates itself through Sparkle.
- **Homebrew**, from the tap ([`packaging/homebrew/notchmeter.rb`](../packaging/homebrew/notchmeter.rb)): `brew tap Amir-Hackett/tap && brew trust --cask Amir-Hackett/tap/notchmeter && brew install --cask notchmeter`. The middle step is Homebrew's, not this project's: it refuses to load a cask from a tap outside homebrew/cask until you say you trust it, and it prints that same command when you skip it.

macOS 14 or later, Apple silicon or Intel.

Notchmeter is free and stays free. If it earns its place in your notch, you can [support the project](https://buy.stripe.com/8x2bIVbYF8wsgP2cvVao800) — optional, any amount, and the same link sits under Settings › General.

### Testing a pre-release build

An unsigned or ad-hoc-signed build (the CI artifact, a `--dry-run` DMG, any local build) is refused by Gatekeeper on any Mac but the one that built it. On macOS 15 and later, right-click › Open no longer bypasses that. Two routes: open it once, let it be refused, then allow it under System Settings › Privacy & Security › *Open Anyway*; or remove the quarantine attribute before the first launch:

```bash
xattr -d com.apple.quarantine /Applications/Notchmeter.app
```

A quarantined copy launched from Downloads or straight from the DMG also runs App-Translocated, from a random read-only path where Open at login and updates cannot work; the app notices and offers to move itself to Applications.

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
swift run Notchmeter --probe --no-prompt --json   # the same as one versioned JSON object (schema notchmeter.limits.v1) with an exit code, see docs/testing.md
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke               # on-screen self check (no Keychain prompt)
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke --edge left   # same, trying another layout
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke --visibility onHover --hover-sim   # scripted hover: a sweep that opens nothing, then one open, no flicker, one close
build/Notchmeter.app/Contents/MacOS/Notchmeter --smoke --lang zh-Hans   # same, with the copy pinned to Simplified Chinese
build/Notchmeter.app/Contents/MacOS/Notchmeter --hook                # Claude Code hook command, see docs/hooks.md
build/Notchmeter.app/Contents/MacOS/Notchmeter --hook --tool codex   # Codex hook command, same document
build/Notchmeter.app/Contents/MacOS/Notchmeter --hook --tool cursor  # Cursor hook command
build/Notchmeter.app/Contents/MacOS/Notchmeter --hook --tool antigravity              # Gemini CLI hook command (lights the Antigravity ring)
build/Notchmeter.app/Contents/MacOS/Notchmeter --hook --tool copilot --event <name>  # Copilot CLI hook command (one entry per event)
build/Notchmeter.app/Contents/MacOS/Notchmeter --statusline          # Claude Code status-line command, see docs/hooks.md
build/Notchmeter.app/Contents/MacOS/Notchmeter --render-assets docs/media   # the README's pictures, from fixed readings (no Keychain, no network)
build/Notchmeter.app/Contents/MacOS/Notchmeter --render-gallery build/gallery   # the launch gallery frames (one GIF, seven PNGs) and thumbnail
build/Notchmeter.app/Contents/MacOS/Notchmeter --render-dashboard build/dashboard   # the Usage Dashboard, light and dark, week, 30 and 90 days
```

An ad-hoc-signed local build never checks for updates (one signed with the local identity from `scripts/signing-identity.sh` does start the updater). Ad-hoc signing has a cost worth knowing: macOS ties
the Accessibility grant, and the Keychain grant for Claude Code's login, to the identity a binary carries, and an
ad-hoc signature has none — its hash changes with every build, so each reinstall reads as a new application and
both grants are dropped. `scripts/signing-identity.sh` creates a local self-signed certificate that fixes this;
[docs/permissions.md](permissions.md) has the two commands and how to remove it. Shipped builds are signed with Developer ID, notarised and updated through Sparkle by `scripts/release.sh`; [docs/release.md](release.md) has the one-time setup and the per-release command.

## First launch

Notchmeter reads Claude Code's saved login without a Keychain dialog: it asks the Keychain with prompts disabled, then reads the item the way `/usr/bin/security find-generic-password -w` does (macOS lets that tool read what the same user's Claude Code wrote), then `$CLAUDE_CONFIG_DIR/.credentials.json` and `~/.claude/.credentials.json`, then `CLAUDE_CODE_OAUTH_TOKEN` (from the environment, or from `launchctl getenv` when the app was not started from a shell). The Keychain dialog appears only when every silent route fails and you ask for it: *Ask for Keychain access* in Settings, the Claude card's refresh or ⌘R may prompt while *Ask for Keychain access* (Settings › Advanced › Privacy) is *Only on refresh*, and never with it set to *Never*, so a rebuild, which changes the ad-hoc signature, cannot bring back a loop of dialogs. When it does ask, choose **Always Allow**. Codex, Cursor, Antigravity and Copilot need no permission. On the first launch Settings opens once with an offer to add the [Claude Code hook](hooks.md); it is a button, never automatic. Notification permission is not asked at launch: the first alert asks provisionally (it lands quietly in Notification Center) and the Notifications toggle or Test button asks properly.

# Permissions

Two optional features ask for a permission each: *Readouts › Auto* for Accessibility, and a click on a session row
for Automation of that session's terminal. A copy that has never had Auto picked and never had a row clicked is
never asked anything, at launch or otherwise.

## Accessibility, only for *Readouts › Auto*

*Readouts › Auto* (Settings › Appearance › Panel, or the Options menu) shifts the readouts clear of the frontmost app's menu
titles: both sides of the notch while the titles end short of the left-hand readouts, right of the notch while a
menu-heavy app (Chrome, Xcode) would run into them.

- **What it reads.** The geometry of the frontmost app's menu bar and of the titles in it: `kAXPositionAttribute`
  and `kAXSizeAttribute`, so where they sit and how wide they are. Nothing else — never a title, a value, a
  description, the contents of a menu, nor any element outside the menu bar — and it never writes an attribute or
  performs an action anywhere. The code is [`MenuBarExtent.swift`](../Sources/Notchmeter/MenuBarExtent.swift).
- **When it reads.** When an app comes to the front. The answer is remembered per app, so returning to an app
  already seen measures nothing, and there is no timer.
- **When it asks.** When you pick Auto, once per pick, and once more per signed copy on a launch that finds Auto
  already chosen and the permission never granted — so a rebuild or an update asks again once, not on every launch.
  A launch that finds a grant that has stopped applying offers the repair described below instead of the prompt, on
  the same terms. Nothing is measured while a fixed side is chosen, and a copy that has never picked Auto is never
  asked.
- **Without it.** Auto stays centred on the notch with every readout — where it sits whenever the menu bar leaves
  room — whether the permission was never granted or is revoked later. Settings says so and offers a button to
  System Settings › Privacy & Security › Accessibility.
- **When the switch is on and Auto still does not work.** The grant belongs to the copy it was given to, and macOS
  leaves the entry behind when that copy is replaced (see below). Notchmeter records the signature the grant was
  last seen under (`accessibilityGrantedTo`), so it can tell that apart from a permission that was never given: it
  offers to clear the entry and restart instead of sending you to a switch that already looks right. Settings shows
  *Repair the Accessibility permission…* in place of the usual button while that is the case. From 0.5.0 the same
  repair is offered when the entry stops applying to the very copy it was granted to (seen on a Developer ID build
  whose certificate had not changed), and when the switch was turned off by hand, since Notchmeter cannot tell those
  two apart; the alert for that case says so, and names turning the switch back on as the first thing to try. At
  launch the alert is offered once per signed copy, on the same terms as the prompt: *Not Now* is remembered, and
  the Repair button offers it again whenever you want it.
- **Seeing what it read.** `--menu-bar` prints every menu bar extra and which of them Auto counts
  ([docs/testing.md](testing.md#seeing-what-auto-measured)). It reads nothing the feature does not already read.

No other part of Notchmeter uses the Accessibility API. It never asks for Screen Recording, the microphone, the
camera, Full Disk Access, Contacts, Calendars or Location; the screen-share check is a yes/no from the window
server that needs no permission. The one other permission it can ask for is Automation, below.

## Automation, only for the jump to a terminal

A click on a row of the panel's Sessions card (*Settings › Assistants › Sessions › Jump to the terminal on click*,
on by default) brings that session's terminal tab or pane forward. For iTerm2, Terminal and Ghostty that is one
Apple event each, and macOS gates Apple events per target app ([docs/hooks.md](hooks.md#jumping-to-the-terminal)
has the full ladder).

- **What it sends.** One instruction to the terminal named by the session's own hook: select the tab or session
  whose id or tty matches, and come to the front. It reads nothing back but whether the script ran; the tab is
  matched by the `unique id` or `tty` the hook already knew, never by a title. The code is
  [`TerminalJump.swift`](../Sources/Notchmeter/TerminalJump.swift).
- **When it asks.** The first time a jump drives each of the three, macOS shows its own *"Notchmeter" wants access
  to control "iTerm2"* dialog and keeps the answer under System Settings › Privacy & Security › Automation. Nothing
  is asked at launch, when the setting is turned on, or when Settings is opened: Settings reads where the grant
  stands (`AEDeterminePermissionToAutomateTarget`, without prompting) and shows *Granted*, *Denied*, *Not asked
  yet* or *Not running* per app, with a button to the Automation pane.
- **Without it.** A denied or never-granted app is raised as an app rather than to the exact tab, and the log says
  so. Warp (a URL), kitty and WezTerm (their own command-line tools over their own sockets) and tmux need no
  permission at all; VS Code, Cursor and any terminal the ladder does not know are raised as apps and never asked.
- **The entitlement.** The release build claims `com.apple.security.automation.apple-events`, a hardened-runtime
  exception and not a restricted entitlement, so no provisioning profile has to grant it and
  `scripts/release.sh`'s claimed-versus-granted check leaves the `com.apple.security.*` namespace out for exactly
  this reason; `NSAppleEventsUsageDescription` in `scripts/Info.plist` is the sentence the dialog shows.

## Why the grants keep disappearing

macOS ties an Accessibility grant — and the Keychain grant for Claude Code's login — to the identity a binary is
signed with. An ad-hoc signature (`codesign --sign -`) has no identity: its code hash changes with every build, so
every reinstall looks like a different application and both grants are dropped. That is why Auto could be chosen,
approved, and still report `accessibility not granted` after the next install.

Worse than dropping them: macOS does not withdraw the entry. The switch in Privacy & Security › Accessibility
stays on for a copy that is gone, the new copy is refused, and the system's own prompt leads straight back to that
switch — so the permission looks granted and behaves as if it is not. Only clearing the entry (`tccutil reset
Accessibility com.amirhackett.notchmeter`, or the − button in the pane) and granting it again gets out of it.
`scripts/build.sh install` compares the signature of the copy it replaces with the one it installs and clears the
entry itself when they differ — which is every swap between a Developer ID build and a local one — and the app
offers the same from the alert described above when it finds itself in that state.

`scripts/signing-identity.sh` creates a local self-signed certificate, "Notchmeter Local", in the login keychain.
Signing with it gives the app a stable identity, so the grants survive a rebuild.

It takes two steps, because the second one needs the login password and cannot be done unattended:

```
scripts/signing-identity.sh              # creates the certificate
scripts/signing-identity.sh --authorise  # lets codesign use its key without a dialog
```

Until the second has run, `scripts/build.sh` signs ad hoc and says so. It never waits on the dialog: the attempt
is time-boxed, and a timed-out signature is cleaned up before the fallback.

Remove the identity with:

```
security delete-identity -c "Notchmeter Local" ~/Library/Keychains/login.keychain-db
```

This is a local convenience, not a substitute for a Developer ID. A build handed to anyone else still needs one,
for notarisation and to clear Gatekeeper.

# Permissions

Notchmeter asks macOS for nothing at launch. One optional setting asks for one permission.

## Accessibility, only for *Readouts › Auto*

*Readouts › Auto* (Settings › Panel, or the Options menu) shifts the readouts clear of the frontmost app's menu
titles: both sides of the notch while the titles end short of the left-hand readouts, right of the notch while a
menu-heavy app (Chrome, Xcode) would run into them.

- **What it reads.** The geometry of the frontmost app's menu bar and of the titles in it: `kAXPositionAttribute`
  and `kAXSizeAttribute`, so where they sit and how wide they are. Nothing else — never a title, a value, a
  description, the contents of a menu, nor any element outside the menu bar — and it never writes an attribute or
  performs an action anywhere. The code is [`MenuBarExtent.swift`](../Sources/Notchmeter/MenuBarExtent.swift).
- **When it reads.** When an app comes to the front. The answer is remembered per app, so returning to an app
  already seen measures nothing, and there is no timer.
- **When it asks.** Only when you pick Auto, once per pick. Nothing is asked at launch, and nothing is measured
  while a fixed side is chosen.
- **Without it.** Auto degrades silently to the side you had chosen before it, whether the permission was never
  granted or is revoked later. Settings says so and offers a button to
  System Settings › Privacy & Security › Accessibility.

No other part of Notchmeter uses the Accessibility API. It never asks for Screen Recording, the microphone, the
camera, Full Disk Access, Contacts, Calendars, Location or Automation; the screen-share check is a yes/no from the
window server that needs no permission.

## Why the grants keep disappearing

macOS ties an Accessibility grant — and the Keychain grant for Claude Code's login — to the identity a binary is
signed with. An ad-hoc signature (`codesign --sign -`) has no identity: its code hash changes with every build, so
every reinstall looks like a different application and both grants are dropped. That is why Auto could be chosen,
approved, and still report `accessibility not granted` after the next install.

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

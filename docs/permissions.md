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

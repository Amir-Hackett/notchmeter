#!/bin/bash
# Runs the unit tests. Command Line Tools ship Swift Testing without the Foundation cross-import
# module, so the framework path is passed explicitly and cross-import overlays are disabled.
# Xcode keeps the same frameworks under its macOS platform; a toolchain with neither layout is
# left to resolve Testing on its own.
# Tests that need UserDefaults use fixed suite names (NotchmeterTests.*) emptied before and after,
# so a run leaves nothing new under ~/Library/Preferences (docs/testing.md).
#
# --no-parallel: several suites touch AppKit (NSScreen, the panel geometry, the asset renderer), and Swift
# Testing otherwise starts every test at once. On a machine with no Window Server session, which is every CI
# runner, two of them racing the first connection abort the whole process inside CoreGraphics rather than
# failing a test:
#
#     Assertion failed: (CGAtomicGet(&is_initialized)), function CGSConnectionByID, file CGSConnection.mm
#
# It took the first run of the release workflow down on 2026-09-05 and a pull request an hour later, having
# passed a dozen times in between, which is the shape of a race and the reason not to leave it: a release that
# publishes on a coin flip is worse than a slow one. Serially the suite takes a few minutes rather than ninety
# seconds, and the answer is the same every time.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER="$(xcode-select -p)"
for FW in "$DEVELOPER/Library/Developer/Frameworks" "$DEVELOPER/Platforms/MacOSX.platform/Developer/Library/Frameworks"; do
  if [ -d "$FW/Testing.framework" ]; then
    exec swift test --no-parallel \
      -Xswiftc -F"$FW" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
      -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW" "$@"
  fi
done
exec swift test --no-parallel "$@"

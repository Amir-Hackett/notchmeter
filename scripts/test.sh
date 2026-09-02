#!/bin/bash
# Runs the unit tests. Command Line Tools ship Swift Testing without the Foundation cross-import
# module, so the framework path is passed explicitly and cross-import overlays are disabled.
# Xcode keeps the same frameworks under its macOS platform; a toolchain with neither layout is
# left to resolve Testing on its own.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER="$(xcode-select -p)"
for FW in "$DEVELOPER/Library/Developer/Frameworks" "$DEVELOPER/Platforms/MacOSX.platform/Developer/Library/Frameworks"; do
  if [ -d "$FW/Testing.framework" ]; then
    exec swift test \
      -Xswiftc -F"$FW" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
      -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW" "$@"
  fi
done
exec swift test "$@"

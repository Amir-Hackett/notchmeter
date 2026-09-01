#!/bin/bash
# Runs the unit tests. Command Line Tools ship Swift Testing without the Foundation cross-import
# module, so the framework path is passed explicitly and cross-import overlays are disabled.
set -euo pipefail
cd "$(dirname "$0")/.."
FW="$(xcode-select -p)/Library/Developer/Frameworks"
[ -d "$FW/Testing.framework" ] || FW="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
exec swift test \
  -Xswiftc -F"$FW" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW" "$@"

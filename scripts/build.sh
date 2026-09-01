#!/bin/bash
# Builds Notchmeter.app with SwiftPM alone (no Xcode needed) and ad-hoc signs it.
#   scripts/build.sh          build -> build/Notchmeter.app
#   scripts/build.sh run      build, then launch it
#   scripts/build.sh install  build, copy to /Applications, launch
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Notchmeter.app

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Notchmeter"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notchmeter"
cp scripts/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ ! -f build/AppIcon.icns ]; then
  if swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns; then
    :
  else
    echo "icon generation failed; continuing without an icon"
  fi
fi
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "built $APP"

case "${1:-}" in
  run)
    open "$APP"
    ;;
  install)
    pkill -x Notchmeter 2>/dev/null || true
    rm -rf /Applications/Notchmeter.app
    cp -R "$APP" /Applications/
    open /Applications/Notchmeter.app
    echo "installed /Applications/Notchmeter.app"
    ;;
esac

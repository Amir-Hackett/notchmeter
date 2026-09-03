#!/bin/bash
# Builds Notchmeter.app with SwiftPM alone (no Xcode needed) and ad-hoc signs it.
#   scripts/build.sh          build -> build/Notchmeter.app
#   scripts/build.sh run      build, then launch it
#   scripts/build.sh install  build, copy to /Applications, launch
#   ARCHS="arm64 x86_64" scripts/build.sh   one slice per architecture, lipo'd into a universal binary (scripts/release.sh)
# --disable-keychain: the Sparkle artifact is public, but without it SwiftPM first asks the login Keychain for GitHub
# credentials, and a shell with nobody to answer that dialog hangs before the download starts.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Notchmeter.app
SWIFT_BUILD=(swift build -c release --disable-keychain)

mkdir -p build
if [ -n "${ARCHS:-}" ]; then
  SLICES=()
  for ARCH in $ARCHS; do
    "${SWIFT_BUILD[@]}" --triple "$ARCH-apple-macosx"
    SLICES+=("$("${SWIFT_BUILD[@]}" --triple "$ARCH-apple-macosx" --show-bin-path)/Notchmeter")
  done
  lipo -create "${SLICES[@]}" -output build/Notchmeter-universal
  BIN=build/Notchmeter-universal
  BIN_DIR="$(dirname "${SLICES[0]}")"
else
  "${SWIFT_BUILD[@]}"
  BIN_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"
  BIN="$BIN_DIR/Notchmeter"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Notchmeter"
cp scripts/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# The Localizable.strings tables live in the resource bundle SwiftPM builds; Localization.swift looks for it in
# Contents/Resources, since SwiftPM's own accessor only knows the directory beside the executable and the build path.
cp -R "$BIN_DIR/Notchmeter_Notchmeter.bundle" "$APP/Contents/Resources/"

# The executable links @rpath/Sparkle.framework; the bundle carries the framework SwiftPM placed beside the binary and
# points the executable at Contents/Frameworks.
cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Notchmeter"

if [ ! -f build/AppIcon.icns ]; then
  if swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns; then
    :
  else
    echo "icon generation failed; continuing without an icon"
  fi
fi
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with the local identity when it is usable, else ad hoc. macOS ties the Accessibility and Keychain grants
# to the signing identity, so an ad-hoc build loses both on every install; a stable identity keeps them. The
# attempt is time-boxed because an identity whose key still asks permission would otherwise hang the build
# forever waiting on a dialog — see scripts/signing-identity.sh.
IDENTITY="Notchmeter Local"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1 \
   && perl -e 'alarm 20; exec @ARGV' codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP" >/dev/null 2>&1; then
    echo "signed with $IDENTITY"
else
    # A timed-out codesign leaves a .cstemp behind, and the next signature refuses to write over it.
    find "$APP" -name '*.cstemp' -delete 2>/dev/null || true
    codesign --force --sign - "$APP"
    if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
        echo "signed ad hoc: $IDENTITY exists but its key still asks permission."
        echo "  Run once, then rebuild:  scripts/signing-identity.sh --authorise"
    else
        echo "signed ad hoc (no $IDENTITY identity; see scripts/signing-identity.sh)"
    fi
fi
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

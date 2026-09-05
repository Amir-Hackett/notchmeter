#!/bin/bash
# Builds Notchmeter the way it ships: a universal (arm64 + x86_64) Notchmeter.app signed with Developer ID and the
# hardened runtime, notarised and stapled; a signed, notarised DMG around it; and a Sparkle appcast signed with the
# EdDSA key, checked against the public key the app carries. Everything lands in dist/. docs/release.md has the setup.
#
#   scripts/release.sh             the real thing; needs the environment below
#   scripts/release.sh --dry-run   the same steps with an ad-hoc signature, no notarisation and a throwaway appcast
#                                  key, so the pipeline can be proved on a Mac without an Apple Developer account.
#                                  The hardened runtime is left off there: its library validation wants the app and
#                                  Sparkle.framework to share a Team ID, which ad-hoc signatures do not carry.
#   --channel beta                 marks the appcast item <sparkle:channel>beta</sparkle:channel>, so only copies with
#                                  "Beta updates" on in Settings are offered it (Updater.swift, allowedChannels).
#
# The app is signed with scripts/Notchmeter.entitlements (the time-sensitive notifications entitlement); the matching
# capability must be enabled on the App ID in the developer account or the signature is refused (docs/release.md).
#
# Environment:
#   DEVELOPER_ID_APP     "Developer ID Application: Your Name (TEAMID)", as `security find-identity -v -p codesigning` lists it
#   NOTARY_PROFILE       the profile saved by `xcrun notarytool store-credentials <name>`
#   NOTARY_KEYCHAIN      the keychain holding that profile when it is not in the default search list (CI)
#   SPARKLE_KEY_PATH     the private EdDSA key file exported by `generate_keys -x`; or
#   SPARKLE_PRIVATE_KEY  that file's contents (a CI secret), handed to Sparkle on stdin and never written to disk; or
#                        neither, and generate_appcast reads the key `generate_keys` stored in the login Keychain
#   VERSION              the tag without its v (CI); must equal CFBundleShortVersionString in scripts/Info.plist
#   BUILD_NUMBER         CFBundleVersion, which Sparkle compares; default `git rev-list --count HEAD`, so it only grows
#   PREVIOUS_APPCAST     the appcast.xml published last time, so its items survive into the new feed
#   RELEASE_NOTES        an HTML fragment to embed as this version's release notes
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
CHANNEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --channel) shift; CHANNEL="${1:-}"; [ -n "$CHANNEL" ] || { echo "usage: scripts/release.sh [--dry-run] [--channel beta]" >&2; exit 2; } ;;
    *) echo "usage: scripts/release.sh [--dry-run] [--channel beta]" >&2; exit 2 ;;
  esac
  shift
done

REPO_URL=https://github.com/Amir-Hackett/notchmeter
APP=build/Notchmeter.app
DIST=dist
DMG="$DIST/Notchmeter.dmg"
APPCAST="$DIST/appcast.xml"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
PLACEHOLDER_KEY=REPLACE_WITH_SPARKLE_PUBLIC_KEY
ENTITLEMENTS=scripts/Notchmeter.entitlements

fail() { echo "release: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)"
VERSION="${VERSION:-$PLIST_VERSION}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' scripts/Info.plist)"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' scripts/Info.plist)"
DOWNLOAD_URL="$REPO_URL/releases/download/v$VERSION/Notchmeter.dmg"
[ "$VERSION" = "$PLIST_VERSION" ] || fail "VERSION $VERSION is not CFBundleShortVersionString $PLIST_VERSION in scripts/Info.plist; bump the plist first"

if [ "$DRY_RUN" = 1 ]; then
  IDENTITY="-"
  TIMESTAMP=()
  RUNTIME=()
  # generate_appcast signs an update only when the app inside carries the public half of the signing key, so the dry
  # run stamps a throwaway pair the way a real release carries the real one; the private half never touches disk.
  SPARKLE_PRIVATE_KEY="$(head -c 32 /dev/urandom | base64)"
  PUBLIC_KEY="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | swift scripts/appcast-check.swift public-key)"
else
  [ -n "${DEVELOPER_ID_APP:-}" ] || fail "DEVELOPER_ID_APP is not set; see docs/release.md"
  [ -n "${NOTARY_PROFILE:-}" ] || fail "NOTARY_PROFILE is not set; see docs/release.md"
  security find-identity -v -p codesigning | grep -Fq "$DEVELOPER_ID_APP" || fail "no codesigning identity named \"$DEVELOPER_ID_APP\" in the keychain"
  [ "$PUBLIC_KEY" != "$PLACEHOLDER_KEY" ] || fail "scripts/Info.plist still carries the SUPublicEDKey placeholder, so the updater would never start; see docs/release.md"
  IDENTITY="$DEVELOPER_ID_APP"
  TIMESTAMP=(--timestamp)
  RUNTIME=(--options runtime)
fi
NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE:-}" --wait)
if [ -n "${NOTARY_KEYCHAIN:-}" ]; then NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN"); fi

sign() { codesign --force --sign "$IDENTITY" ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} "$@"; }
sign_code() { sign ${RUNTIME[@]+"${RUNTIME[@]}"} "$@"; }
notarize() {
  local output id
  output="$(xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" 2>&1)" || { echo "$output"; fail "notarytool could not submit $1"; }
  echo "$output"
  if ! grep -q 'status: Accepted' <<<"$output"; then
    id="$(sed -n 's/^ *id: //p' <<<"$output" | head -n 1)"
    fail "notarisation of $1 was not accepted; see: xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE"
  fi
}

step "Building Notchmeter $VERSION (build $BUILD_NUMBER) for arm64 and x86_64"
ARCHS="arm64 x86_64" scripts/build.sh
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" -c "Set :SUPublicEDKey $PUBLIC_KEY" "$APP/Contents/Info.plist"
lipo -info "$APP/Contents/MacOS/Notchmeter"

step "Signing with \"$IDENTITY\", inside out"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
sign_code "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
sign_code --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
sign_code "$FRAMEWORK/Versions/B/Autoupdate"
sign_code "$FRAMEWORK/Versions/B/Updater.app"
sign_code "$FRAMEWORK"
# The app itself carries the entitlements; an ad-hoc dry run signs without them (they need a provisioning identity).
if [ "$DRY_RUN" = 1 ]; then sign_code "$APP"; else sign_code --entitlements "$ENTITLEMENTS" "$APP"; fi
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$DRY_RUN" = 0 ]; then
  step "Notarising the app"
  ditto -c -k --keepParent "$APP" build/Notchmeter-notarise.zip
  notarize build/Notchmeter-notarise.zip
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

step "Building $DMG"
mkdir -p "$DIST"
rm -f "$DMG"
STAGE=build/dmg
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Notchmeter -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov -quiet "$DMG"
sign "$DMG"
if [ "$DRY_RUN" = 0 ]; then
  step "Notarising the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi
hdiutil verify -quiet "$DMG"

step "Generating $APPCAST"
if [ -n "${PREVIOUS_APPCAST:-}" ] && [ -f "$PREVIOUS_APPCAST" ]; then
  cp "$PREVIOUS_APPCAST" "$APPCAST"
else
  rm -f "$APPCAST"
fi
if [ -n "${RELEASE_NOTES:-}" ]; then cp "$RELEASE_NOTES" "$DIST/Notchmeter.html"; else rm -f "$DIST/Notchmeter.html"; fi
KEY_ARGS=()
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  KEY_ARGS=(--ed-key-file -)
elif [ -n "${SPARKLE_KEY_PATH:-}" ]; then
  KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_PATH")
fi
CHANNEL_ARGS=()
if [ -n "$CHANNEL" ]; then CHANNEL_ARGS=(--channel "$CHANNEL"); fi
printf '%s' "${SPARKLE_PRIVATE_KEY:-}" | "$SPARKLE_BIN/generate_appcast" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} ${CHANNEL_ARGS[@]+"${CHANNEL_ARGS[@]}"} \
  --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
  --link "$REPO_URL" \
  --full-release-notes-url "$REPO_URL/releases/tag/v$VERSION" \
  -o "$APPCAST" "$DIST"
if [ -n "$CHANNEL" ]; then
  grep -q "<sparkle:channel>$CHANNEL</sparkle:channel>" "$APPCAST" || fail "generate_appcast did not write the $CHANNEL channel into $APPCAST"
fi

step "Checking the appcast against the public key the app ships"
swift scripts/appcast-check.swift verify "$DMG" "$APPCAST" "$PUBLIC_KEY" "$DOWNLOAD_URL"

SHA256="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
step "Release $VERSION is ready in $DIST/"
if [ "$DRY_RUN" = 1 ]; then
  cat <<CHECKLIST
  $DMG       DRY RUN: ad-hoc signed, not notarised; Gatekeeper will refuse it on another Mac
  $APPCAST   DRY RUN: signed with a throwaway key; do not publish it
  sha256 $SHA256
To ship for real: docs/release.md, then DEVELOPER_ID_APP=... NOTARY_PROFILE=... scripts/release.sh
CHECKLIST
else
  cat <<CHECKLIST
  $DMG       universal, Developer ID, hardened runtime, notarised, stapled
  $APPCAST   signed; verified against SUPublicEDKey
  sha256 $SHA256
Publish, one of these and never both (two publishers on one tag is how a notarised DMG gets replaced):
  a. Signing secrets set in GitHub (docs/release.md, step 5):
       git tag v$VERSION && git push origin v$VERSION
     release.yml rebuilds from the tag, signs, notarises and creates the release with its DMG and appcast.
     This build was the rehearsal; do not run gh release create as well.
  b. No secrets in GitHub:
       gh release create v$VERSION $DMG $APPCAST --title "Notchmeter $VERSION" --generate-notes
     That creates the tag too. The workflow it fires finds a published release and refuses to touch it.
Then:
  1. curl -fsSL $FEED_URL | grep '<sparkle:version>'   # $BUILD_NUMBER, when this build was made from the commit you tagged
  2. packaging/homebrew/notchmeter.rb: version "$VERSION", sha256 "$SHA256" (path a: the sha256 in the job summary)
  3. On a Mac that never saw this build: open the DMG, drag, launch; Options menu shows "Check for Updates…"
CHECKLIST
fi

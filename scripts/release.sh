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
# The app is signed with scripts/Notchmeter.entitlements (the time-sensitive notifications entitlement) only when
# PROVISION_PROFILE points at a Developer ID profile that grants it, which is embedded in the bundle at the same
# time. Without that the app is signed with no entitlements. Never one without the other: docs/release.md, "2".
#
# Environment:
#   DEVELOPER_ID_APP     "Developer ID Application: Your Name (TEAMID)", as `security find-identity -v -p codesigning` lists it
#   NOTARY_PROFILE       the profile saved by `xcrun notarytool store-credentials <name>`
#   NOTARY_KEYCHAIN      the keychain holding that profile when it is not in the default search list (CI)
#   SPARKLE_KEY_PATH     the private EdDSA key file exported by `generate_keys -x`; or
#   SPARKLE_PRIVATE_KEY  that file's contents (a CI secret), handed to Sparkle on stdin and never written to disk; or
#                        neither, and generate_appcast reads the key `generate_keys` stored in the login Keychain
#   VERSION              the tag without its v (CI); must equal CFBundleShortVersionString in scripts/Info.plist
#   BUILD_NUMBER         CFBundleVersion, which Sparkle compares; default `git rev-list --count HEAD` of the tree built
#                        from, and checked against PREVIOUS_APPCAST so that it only ever grows
#   PREVIOUS_APPCAST     the appcast.xml published last time, so its items survive into the new feed
#   RELEASE_NOTES        an HTML fragment to embed as this version's release notes
#   PROVISION_PROFILE    optional; a Developer ID .provisionprofile granting the entitlements above, embedded in the
#                        bundle and signed against. Unset, the app claims no entitlements and still launches
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

fail() { echo "release: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)"
VERSION="${VERSION:-$PLIST_VERSION}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
COMMIT="$(git rev-parse HEAD)"
# Sparkle offers a build only when its number is above the installed one, and a commit count can go backwards: after a
# history rewrite, or when the last release was built from a tree past its tag (0.1.0 shipped as 89 from a tag that
# counts 86). So the number is checked against the feed that is already published before anything is built.
if [ -n "${PREVIOUS_APPCAST:-}" ] && [ -f "$PREVIOUS_APPCAST" ]; then
  HIGHEST="$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$PREVIOUS_APPCAST" | grep -o '[0-9][0-9]*' | sort -n | tail -n 1 || true)"
  if [ -n "$HIGHEST" ] && [ "$BUILD_NUMBER" -le "$HIGHEST" ]; then
    fail "BUILD_NUMBER $BUILD_NUMBER is not above the $HIGHEST already published in $PREVIOUS_APPCAST, so Sparkle would never offer this build; build from a later commit, or set BUILD_NUMBER explicitly"
  fi
fi
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

# A restricted entitlement (anything under com.apple.*) is only usable outside the App Store when a Developer ID
# provisioning profile granting it sits in the bundle. With PROVISION_PROFILE pointing at one the app is signed
# with scripts/Notchmeter.entitlements and the notices break through a Focus; without it the app is signed with no
# entitlements at all and they arrive at the ordinary level. Never the entitlements without the profile: that is
# what v0.2.0 shipped, and macOS refused to launch it on every Mac (AMFI -413, "No matching profile found").
ENTITLEMENTS=scripts/Notchmeter.entitlements
SIGN_ARGS=()
if [ -n "${PROVISION_PROFILE:-}" ]; then
  [ -f "$PROVISION_PROFILE" ] || fail "PROVISION_PROFILE $PROVISION_PROFILE does not exist"
  step "Embedding the provisioning profile"
  cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
  SIGN_ARGS=(--entitlements "$ENTITLEMENTS")
fi

step "Signing with \"$IDENTITY\", inside out"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
sign_code "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
sign_code --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
sign_code "$FRAMEWORK/Versions/B/Autoupdate"
sign_code "$FRAMEWORK/Versions/B/Updater.app"
sign_code "$FRAMEWORK"
sign_code "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Two checks that would have caught v0.2.0, which passed codesign, notarisation, spctl, its checksum, its appcast
# signature and lipo, and could not start on any Mac.
#
# The first is static: every restricted entitlement the signed app claims has to be granted by the profile in the
# bundle. No profile, or a profile that does not name the key, and macOS refuses the app at launch.
#
# "Restricted" is the Apple namespace minus com.apple.security.*, and that exception is the point: the hardened
# runtime exceptions (com.apple.security.cs.*) and the sandbox keys are claimed freely by a Developer ID app and
# never appear in a profile, so treating them as restricted would fail a release that is perfectly sound.
# Everything else under com.apple.*, com.apple.developer.* above all, needs a profile to name it.
step "Checking every entitlement claimed is one the profile grants"
CLAIMED="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null \
  | sed -n 's/.*<key>\(com\.apple\.[^<]*\)<\/key>.*/\1/p' | grep -v '^com\.apple\.security\.' || true)"
if [ -n "$CLAIMED" ]; then
  PROFILE_IN_APP="$APP/Contents/embedded.provisionprofile"
  [ -e "$PROFILE_IN_APP" ] || fail "the app claims${CLAIMED:+ }$(echo "$CLAIMED" | tr '\n' ' ')with no embedded.provisionprofile to grant it; macOS will refuse to launch it (AMFI -413)"
  GRANTED="$(security cms -D -i "$PROFILE_IN_APP" 2>/dev/null || true)"
  while read -r key; do
    [ -n "$key" ] || continue
    printf '%s' "$GRANTED" | grep -qF "<key>$key</key>" \
      || fail "the app claims $key and embedded.provisionprofile does not grant it; macOS will refuse to launch it (AMFI -413)"
  done <<< "$CLAIMED"
fi

# The second actually starts it. AMFI decides at exec, before any of the app's own code runs, and a refusal is a
# SIGKILL: that is the one outcome this fails on. Anything else, including the app finding no window server on a
# runner and dying its own way, is not this check's business.
step "Checking the signed app can be started at all"
# `--cli --help` prints two lines and calls exit(0) (CommandLineTool.run): no run loop, no window server, no
# network, nothing read from the vendors. It is the shortest path that still goes through exec, which is the only
# part being tested.
#
# macOS has no `timeout`, and polling `kill -0` cannot stand in for one: a finished background child stays a
# zombie until its parent reaps it, and `kill -0` on a zombie succeeds. A poll would therefore run its whole
# budget on a process that exited instantly and never read the exit code — a gate that always passes. So: wait
# for the child properly, with a watchdog beside it that kills it if it is still going after a minute. The
# watchdog leaves a file behind when it fires, because its own kill also shows up as 137 and only AMFI's may fail
# the build.
TIMED_OUT="build/.launch-timed-out"
rm -f "$TIMED_OUT"
"$APP/Contents/MacOS/Notchmeter" --cli --help > /dev/null 2>&1 &
LAUNCH_PID=$!
( sleep 60; kill -0 "$LAUNCH_PID" 2>/dev/null && : > "$TIMED_OUT" && kill -9 "$LAUNCH_PID" 2>/dev/null ) &
WATCHDOG=$!
set +e
wait "$LAUNCH_PID"
LAUNCH=$?
set -e
kill "$WATCHDOG" 2>/dev/null || true
# 137 is 128 + 9: killed. Nothing in the app kills itself, and AMFI decides before the app's first instruction
# runs, so with the watchdog ruled out this is the shape of a rejected entitlement seen from outside.
if [ "$LAUNCH" -eq 137 ] && [ ! -e "$TIMED_OUT" ]; then
  fail "the signed app was killed at exec (SIGKILL); macOS refuses to run it. Check Console for amfid, and see docs/release.md"
fi
rm -f "$TIMED_OUT"

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
elif [ -n "$CHANNEL" ]; then
  cat <<CHECKLIST
  $DMG       universal, Developer ID, hardened runtime, notarised, stapled; channel $CHANNEL
  $APPCAST   signed; verified against SUPublicEDKey; carries the $CHANNEL item and the previous feed
  sha256 $SHA256
Publish by hand (the workflow ignores a tag with a hyphen in it):
  1. gh release create v$VERSION $DMG --prerelease --target $COMMIT --title "Notchmeter $VERSION"
  2. gh release upload <stable-tag> $APPCAST --clobber   # the release releases/latest resolves to; the feed is its appcast
  3. curl -fsSL $FEED_URL | grep -F '<sparkle:version>$BUILD_NUMBER</sparkle:version>'   # expect exactly this build
CHECKLIST
else
  cat <<CHECKLIST
  $DMG       universal, Developer ID, hardened runtime, notarised, stapled
  $APPCAST   signed; verified against SUPublicEDKey
  sha256 $SHA256
Publish, one of these and never both (the workflow refuses, or stands down, when a DMG is already on the release,
so a second publisher fails rather than replaces; still, pick one):
  a. Signing secrets set in GitHub (docs/release.md, step 5):
       git tag v$VERSION $COMMIT && git push origin v$VERSION
     release.yml rebuilds from the tag, signs, notarises and creates the release with its DMG and appcast.
     This build was the rehearsal; do not run gh release create as well.
  b. No secrets in GitHub:
       gh release create v$VERSION $DMG $APPCAST --target $COMMIT --title "Notchmeter $VERSION" --generate-notes
     That creates the tag too, on the commit this was built from (without --target a new tag lands on the default
     branch, which may have moved). The workflow it fires builds, finds a published release and stands down.
Then:
  1. curl -fsSL $FEED_URL | grep -F '<sparkle:version>$BUILD_NUMBER</sparkle:version>'   # expect exactly this build
  2. packaging/homebrew/notchmeter.rb: version "$VERSION", sha256 "$SHA256" (path a: the sha256 in the job summary)
  3. On a Mac that never saw this build: open the DMG, drag, launch; Options menu shows "Check for Updates…"
CHECKLIST
fi

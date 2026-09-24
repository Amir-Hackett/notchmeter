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
#   PREVIOUS_APPCAST     the appcast.xml published last time, so its items survive into the new feed; the DMGs its
#                        items point at are also downloaded and diffed against this build, so a copy running one of
#                        them is offered a delta of about a megabyte rather than the whole DMG ("Delta updates" below)
#   RELEASE_NOTES        this version's release notes, embedded in the appcast item: a .md file (Sparkle 2.9 renders
#                        Markdown on macOS 12 and later; docs/release-notes/<version>.md is where the tag workflow
#                        looks), or .html / .txt. Unset, the item carries only the link to the GitHub release
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
#
# One combination cannot be tested this way and must not be failed for it. A dry run signs ad hoc; an ad-hoc
# signature carries no Team ID; a profile grants its entitlements to exactly one team. So an ad-hoc build claiming
# a restricted entitlement is refused by AMFI no matter how sound the release path is, and the SIGKILL means the
# signature is ad hoc, not that the entitlement is wrong. Failing there would make `--dry-run` impossible to pass
# with PROVISION_PROFILE set, in the exact words the v0.2.0 disaster printed - which is how a gate teaches people
# to ignore it. The static check above is the one that carries in a dry run; this one runs for real when signed.
if [ "$DRY_RUN" = 1 ] && [ -n "$CLAIMED" ]; then
  step "Not starting the app: an ad-hoc signature can never carry $(echo "$CLAIMED" | tr '\n' ' ')"
  echo "  A dry run signs ad hoc, so AMFI would refuse this build whatever the profile says. That is a fact about"
  echo "  the ad-hoc signature, not about the release. The entitlement check above is the one that counts here;"
  echo "  the launch check runs on the real signature, in CI and in scripts/release.sh without --dry-run."
else
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
fi

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
# generate_appcast takes the release notes from a file beside the archive with the archive's basename: Notchmeter.html,
# .txt, .md or .markdown, the first it finds winning. Every one of them is removed first, so a file left in dist/ by
# an earlier run can never become this version's notes, and the one copied keeps RELEASE_NOTES's own suffix, which
# is what decides the sparkle:format the item carries (markdown, plain-text, or none for HTML).
rm -f "$DIST"/Notchmeter.html "$DIST"/Notchmeter.txt "$DIST"/Notchmeter.md "$DIST"/Notchmeter.markdown
# Deltas from an earlier run too: dist/*.delta is what gets uploaded, and only this run's may be ("Delta updates").
rm -f "$DIST"/*.delta
NOTES_FORMAT=""
if [ -n "${RELEASE_NOTES:-}" ]; then
  [ -f "$RELEASE_NOTES" ] || fail "RELEASE_NOTES $RELEASE_NOTES does not exist"
  [ -s "$RELEASE_NOTES" ] || fail "RELEASE_NOTES $RELEASE_NOTES is empty; write the notes or unset it"
  case "$RELEASE_NOTES" in
    *.md|*.markdown) NOTES_FORMAT=markdown; cp "$RELEASE_NOTES" "$DIST/Notchmeter.md" ;;
    *.txt) NOTES_FORMAT=plain-text; cp "$RELEASE_NOTES" "$DIST/Notchmeter.txt" ;;
    *.html|*.htm) NOTES_FORMAT=html; cp "$RELEASE_NOTES" "$DIST/Notchmeter.html" ;;
    *) fail "RELEASE_NOTES $RELEASE_NOTES must end in .md, .txt or .html so Sparkle knows how to render it" ;;
  esac
fi
KEY_ARGS=()
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  KEY_ARGS=(--ed-key-file -)
elif [ -n "${SPARKLE_KEY_PATH:-}" ]; then
  KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_PATH")
fi
CHANNEL_ARGS=()
if [ -n "$CHANNEL" ]; then CHANNEL_ARGS=(--channel "$CHANNEL"); fi
# --embed-release-notes puts the notes file into the new item as <description>, with sparkle:format="markdown" or
# "plain-text" for a .md or .txt file. Without it generate_appcast embeds only a bare HTML fragment and turns a .md
# into a <sparkle:releaseNotesLink> relative to the feed, a URL nothing publishes, so the update alert would show an
# error where the notes should be. Items carried over from PREVIOUS_APPCAST are never touched either way.
printf '%s' "${SPARKLE_PRIVATE_KEY:-}" | "$SPARKLE_BIN/generate_appcast" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} ${CHANNEL_ARGS[@]+"${CHANNEL_ARGS[@]}"} \
  --embed-release-notes \
  --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
  --link "$REPO_URL" \
  --full-release-notes-url "$REPO_URL/releases/tag/v$VERSION" \
  -o "$APPCAST" "$DIST"
if [ -n "$CHANNEL" ]; then
  grep -q "<sparkle:channel>$CHANNEL</sparkle:channel>" "$APPCAST" || fail "generate_appcast did not write the $CHANNEL channel into $APPCAST"
fi
# The check is on this build's item alone, cut out of the feed by its sparkle:version, because an older item's notes
# would satisfy a grep over the whole file and prove nothing about the one just written.
ITEM="$(awk -v marker="<sparkle:version>$BUILD_NUMBER</sparkle:version>" 'BEGIN { RS = "</item>" } index($0, marker) { print; exit }' "$APPCAST")"
[ -n "$ITEM" ] || fail "no <item> with <sparkle:version>$BUILD_NUMBER</sparkle:version> in $APPCAST"
case "$NOTES_FORMAT" in
  markdown|plain-text)
    grep -q "<description[^>]*sparkle:format=\"$NOTES_FORMAT\"" <<<"$ITEM" \
      || fail "generate_appcast did not embed $RELEASE_NOTES as a $NOTES_FORMAT <description> in build $BUILD_NUMBER's item" ;;
  html)
    grep -q "<description" <<<"$ITEM" || fail "generate_appcast did not embed $RELEASE_NOTES as a <description> in build $BUILD_NUMBER's item" ;;
  "")
    grep -q "<description" <<<"$ITEM" && fail "build $BUILD_NUMBER's item carries a <description> although RELEASE_NOTES is unset; a stray notes file in $DIST?" ;;
esac


# Delta updates. A delta is the difference between one build and another, about a megabyte where the DMG is eleven;
# Sparkle takes it when the installed copy is the build it was made from, and falls back to the full DMG when it is
# not or the delta fails to apply, so a missing or unusable delta costs a download and nothing else.
#
# generate_appcast makes them only from older archives lying in the directory it reads, and it cannot be handed those
# in dist/: every archive whose version is already in the feed gets its item rewritten, enclosure URL (the one
# --download-url-prefix names, this release's tag, where the older DMG is not) and release notes (there is no notes file
# for it, so the description is dropped) included. So the deltas are made in a directory of their own, from this DMG
# and the older ones, with --versions naming this build alone so no older archive grows an item, and that run's
# <sparkle:deltas> is copied into this build's item in the real feed. Its URLs are relative to this build's enclosure,
# so the deltas are uploaded to this release beside the DMG.
#
# The older builds are the ones PREVIOUS_APPCAST offers, the DMGs its items point at: exactly what installed copies were
# given, whichever tag each came from, each checked against the signature and length its item carries before it is
# diffed. A dry run cannot use them, since they carry the real public key and a delta is signed for the copy it
# applies to; it makes a stand-in instead, this same build stamped one lower and signed with the throwaway key, which
# proves every step between generate_appcast and the upload list. (generate_appcast warns there of a "mismatch code
# signing identity": two ad-hoc signatures never match each other, where two Developer ID ones from the same team do.)
# Trouble fetching or diffing fails a dry run, which
# exists to prove this path, and only warns on a real one, which has spent its notarisation by now and ships a
# correct feed without deltas rather than none at all.
MAX_DELTAS=3
DELTA_DIR=build/deltas
DELTAS=()
rm -rf "$DELTA_DIR"
mkdir -p "$DELTA_DIR/archives"
delta_trouble() {
  [ "$DRY_RUN" = 0 ] || fail "$*"
  echo "release: warning: $*; this release ships without delta updates" >&2
  [ -z "${GITHUB_ACTIONS:-}" ] || echo "::warning::$*; this release ships without delta updates"
}
step "Making delta updates from up to $MAX_DELTAS earlier builds"
if [ "$DRY_RUN" = 1 ]; then
  PREVIOUS_APP="$DELTA_DIR/stand-in/Notchmeter.app"
  mkdir -p "$(dirname "$PREVIOUS_APP")"
  ditto "$APP" "$PREVIOUS_APP"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD_NUMBER - 1))" "$PREVIOUS_APP/Contents/Info.plist"
  sign_code "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}" "$PREVIOUS_APP"
  # A zip rather than a DMG: generate_appcast reads either, and the stand-in only has to be an older archive.
  ditto -c -k --keepParent "$PREVIOUS_APP" "$DELTA_DIR/archives/Notchmeter-stand-in.zip"
elif [ -n "${PREVIOUS_APPCAST:-}" ] && [ -f "$PREVIOUS_APPCAST" ]; then
  # Newest first, as the feed lists them; delta enclosures end in .delta, so only the full archives match.
  PREVIOUS_URLS="$(grep -o '<enclosure url="[^"]*\.dmg"' "$PREVIOUS_APPCAST" | sed 's/^<enclosure url="//; s/"$//' \
    | grep -vxF "$DOWNLOAD_URL" | head -n "$MAX_DELTAS" || true)"
  for url in $PREVIOUS_URLS; do
    archive="$DELTA_DIR/archives/Notchmeter-$(basename "$(dirname "$url")").dmg"
    if ! curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 -o "$archive" "$url"; then
      rm -f "$archive"; echo "release: could not download $url; no delta from it" >&2; continue
    fi
    if ! swift scripts/appcast-check.swift verify "$archive" "$PREVIOUS_APPCAST" "$PUBLIC_KEY" "$url" > /dev/null; then
      rm -f "$archive"; echo "release: $url does not match its item in $PREVIOUS_APPCAST; no delta from it" >&2
    fi
  done
fi
if ls "$DELTA_DIR"/archives/* > /dev/null 2>&1; then
  cp "$DMG" "$DELTA_DIR/archives/Notchmeter.dmg"
  if printf '%s' "${SPARKLE_PRIVATE_KEY:-}" | "$SPARKLE_BIN/generate_appcast" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} \
       --versions "$BUILD_NUMBER" --maximum-deltas "$MAX_DELTAS" \
       --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
       -o "$DELTA_DIR/appcast.xml" "$DELTA_DIR/archives" \
     && NAMES="$(swift scripts/appcast-check.swift add-deltas "$DELTA_DIR/appcast.xml" "$APPCAST" "$BUILD_NUMBER")"; then
    for name in $NAMES; do
      cp "$DELTA_DIR/archives/$name" "$DIST/$name"
      DELTAS+=("$DIST/$name")
    done
    [ "${#DELTAS[@]}" -gt 0 ] || delta_trouble "generate_appcast made no delta smaller than the DMG"
  else
    delta_trouble "generate_appcast could not make the delta updates"
  fi
else
  echo "No earlier build to diff against (no PREVIOUS_APPCAST, or none of its DMGs could be fetched and checked)"
fi

step "Checking the appcast against the public key the app ships"
swift scripts/appcast-check.swift verify "$DMG" "$APPCAST" "$PUBLIC_KEY" "$DOWNLOAD_URL" ${NOTES_FORMAT:+--notes "$NOTES_FORMAT"} --deltas "${#DELTAS[@]}"
DELTA_ASSETS="${DELTAS[*]+ ${DELTAS[*]}}"

SHA256="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
step "Release $VERSION is ready in $DIST/"
if [ "$DRY_RUN" = 1 ]; then
  cat <<CHECKLIST
  $DMG       DRY RUN: ad-hoc signed, not notarised; Gatekeeper will refuse it on another Mac
  $APPCAST   DRY RUN: signed with a throwaway key; do not publish it
  deltas${DELTA_ASSETS:- none}   DRY RUN: made from a stand-in; do not publish them
  sha256 $SHA256
To ship for real: docs/release.md, then DEVELOPER_ID_APP=... NOTARY_PROFILE=... scripts/release.sh
CHECKLIST
elif [ -n "$CHANNEL" ]; then
  cat <<CHECKLIST
  $DMG       universal, Developer ID, hardened runtime, notarised, stapled; channel $CHANNEL
  $APPCAST   signed; verified against SUPublicEDKey; carries the $CHANNEL item and the previous feed
  deltas${DELTA_ASSETS:- none}   the feed points at them on v$VERSION, beside the DMG
  sha256 $SHA256
Publish by hand (the workflow ignores a tag with a hyphen in it):
  1. gh release create v$VERSION $DMG$DELTA_ASSETS --prerelease --target $COMMIT --title "Notchmeter $VERSION"
  2. gh release upload <stable-tag> $APPCAST --clobber   # the release releases/latest resolves to; the feed is its appcast
  3. curl -fsSL $FEED_URL | grep -F '<sparkle:version>$BUILD_NUMBER</sparkle:version>'   # expect exactly this build
CHECKLIST
else
  cat <<CHECKLIST
  $DMG       universal, Developer ID, hardened runtime, notarised, stapled
  $APPCAST   signed; verified against SUPublicEDKey
  deltas${DELTA_ASSETS:- none}   the feed points at them on v$VERSION, beside the DMG
  sha256 $SHA256
Publish, one of these and never both (the workflow refuses, or stands down, when a DMG is already on the release,
so a second publisher fails rather than replaces; still, pick one):
  a. Signing secrets set in GitHub (docs/release.md, step 5):
       git tag v$VERSION $COMMIT && git push origin v$VERSION
     release.yml rebuilds from the tag, signs, notarises and creates the release with its DMG, deltas and appcast.
     This build was the rehearsal; do not run gh release create as well.
  b. No secrets in GitHub:
       gh release create v$VERSION $DMG$DELTA_ASSETS $APPCAST --target $COMMIT --title "Notchmeter $VERSION" --generate-notes
     That creates the tag too, on the commit this was built from (without --target a new tag lands on the default
     branch, which may have moved). The workflow it fires builds, finds a published release and stands down.
Then:
  1. curl -fsSL $FEED_URL | grep -F '<sparkle:version>$BUILD_NUMBER</sparkle:version>'   # expect exactly this build
  2. packaging/homebrew/notchmeter.rb: version "$VERSION", sha256 "$SHA256" (path a: the sha256 in the job summary)
  3. On a Mac that never saw this build: open the DMG, drag, launch; Options menu shows "Check for Updates…"
CHECKLIST
fi

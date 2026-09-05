# Releasing Notchmeter

A local `scripts/build.sh` build is ad-hoc signed, or signed with the local identity from `scripts/signing-identity.sh`
when that exists: it runs on the Mac that built it, Gatekeeper refuses it anywhere else, and with the ad-hoc signature
the in-app updater stays off. A release is different in four ways, and `scripts/release.sh` does all four:

1. **Universal binary** (arm64 + x86_64), one SwiftPM slice per architecture, joined with `lipo`.
2. **Developer ID signature with the hardened runtime**, applied inside out: Sparkle's XPC services and helpers, then
   the framework, then the app. Then the app is **notarised** with `notarytool` and the ticket **stapled**.
3. **A DMG** (`dist/Notchmeter.dmg`, volume "Notchmeter", with an Applications shortcut), itself signed, notarised and
   stapled.
4. **A Sparkle appcast** (`dist/appcast.xml`) signed with the EdDSA key and checked, before anything is published,
   against the `SUPublicEDKey` the app carries.

Both files are hosted as GitHub Release assets. The app's feed is
`https://github.com/Amir-Hackett/notchmeter/releases/latest/download/appcast.xml`, which GitHub resolves to the
`appcast.xml` of the newest non-prerelease release, so every release uploads the whole feed and each item inside it
points at that version's own `Notchmeter.dmg`.

Nothing here needs Xcode; the Command Line Tools carry `codesign`, `notarytool`, `stapler`, `hdiutil` and `lipo`.

## Try it now: the dry run

```bash
scripts/release.sh --dry-run
```

This runs every step with an ad-hoc signature, no hardened runtime (its library validation needs a Team ID, which an
ad-hoc signature lacks), no notarisation, and a throwaway appcast key stamped into the app the way the real key will
be. It leaves a mountable `dist/Notchmeter.dmg` and a signed `dist/appcast.xml` that verifies against that throwaway
key, so the pipeline is proved on a Mac with no Apple Developer account; it produces nothing you can ship.

## Testing an unsigned build

The CI artifact and a `--dry-run` DMG are ad-hoc signed; a `scripts/build.sh` build is ad-hoc signed too, or signed with the local self-signed identity from `scripts/signing-identity.sh`, which another Mac trusts no more. Gatekeeper refuses all of them on any Mac but the one that built it. On macOS 15 (Sequoia) and later, right-click › Open no longer bypasses that. The two routes that work: launch it once and let it be refused, then System Settings › Privacy & Security › *Open Anyway*; or clear the quarantine attribute first, `xattr -d com.apple.quarantine /Applications/Notchmeter.app` (`brew install --cask --no-quarantine` does the same for the tap). A quarantined copy launched from Downloads or the DMG runs App-Translocated, from a random read-only path; the app detects that and offers to move itself to /Applications, and `--smoke` prints the bundle path and whether it is translocated. The README carries the same two paragraphs for users. The notarised release needs none of this.

## One-time setup

### 1. Apple Developer Program

Enrol at <https://developer.apple.com/programs/enroll/> (US$99 a year). Notarisation and Developer ID certificates
need a paid membership; nothing below works without it. Note the ten-character Team ID shown at
<https://developer.apple.com/account> under Membership details.

### 2. Developer ID Application certificate

Without Xcode the certificate comes from the website:

1. Keychain Access → Certificate Assistant → *Request a Certificate From a Certificate Authority…*, saved to disk with
   your email and name and no CA address.
2. <https://developer.apple.com/account/resources/certificates/add> → *Developer ID Application* → upload the request →
   download the `.cer` → double-click it into the login keychain.
3. Check it: `security find-identity -v -p codesigning` lists `Developer ID Application: Your Name (TEAMID)`. That
   whole string is `DEVELOPER_ID_APP`.

If `codesign` later says *unable to build chain to self-signed root*, install Apple's *Developer ID - G2* intermediate
from <https://www.apple.com/certificateauthority/>.

**The time-sensitive notifications capability, and why the release does not claim it.** `scripts/Notchmeter.entitlements`
asks for `com.apple.developer.usernotifications.time-sensitive`, which would let the *waiting for you* and *limit hit*
notifications break through a Focus. The release no longer signs with it, and the file is kept only for the day it can
be used.

This paragraph used to say that without the capability on the App ID, macOS would deliver those notifications at the
ordinary level and log the missing entitlement once. That is wrong, and v0.2.0 shipped on the strength of it. An
entitlement in the `com.apple.*` namespace is **restricted**: an app claiming one outside the App Store must carry a
provisioning profile granting it, at `Contents/embedded.provisionprofile`. Nothing in this pipeline makes one. macOS
refused to launch the app on every Mac, with `amfid` logging `No matching profile found` (`AppleMobileFileIntegrityError`
`-413`), and `codesign --verify`, notarisation and `spctl` all passed it, because none of them check this.

**To claim it, in order.** The pipeline supports it; what is missing is the profile.

1. <https://developer.apple.com/account/resources/identifiers/list> → `com.amirhackett.notchmeter` (register it as an
   explicit App ID if only a wildcard exists) → tick *Time Sensitive Notifications* → Save.
2. <https://developer.apple.com/account/resources/profiles/add> → under Distribution, **Developer ID** → that App ID →
   your Developer ID Application certificate → download the `.provisionprofile`.
3. `base64 -i ~/Downloads/Notchmeter.provisionprofile | gh secret set PROVISION_PROFILE_BASE64 --repo Amir-Hackett/notchmeter`
4. Tag as usual. With that secret set, `release.yml` writes the profile to a file, `release.sh` copies it into the
   bundle as `Contents/embedded.provisionprofile` and signs with `scripts/Notchmeter.entitlements`. Without it, the
   app is signed with no entitlements and the notices arrive at the ordinary level. Locally, pass the path yourself:
   `PROVISION_PROFILE=~/Downloads/Notchmeter.provisionprofile scripts/release.sh`.
5. Install the DMG and open it before making the release latest. Step 5 is not optional; see below.

**Two gates now stand where there were none.** `release.sh` fails the build if the signed app claims an entitlement
under `com.apple.*` that no profile in the bundle grants, naming the key; and it then starts the signed app and fails
if macOS kills it at exec, which is what a rejected entitlement looks like from outside. Neither existed for v0.2.0.
Neither replaces opening the app: they catch this class of fault, not the next one.

### 3. Notarisation credentials

Use an App Store Connect API key rather than your Apple ID; it has no two-factor prompt, so the same key works locally
and in CI.

1. <https://appstoreconnect.apple.com/access/integrations/api> → *Team Keys* → generate a key with the *Developer*
   role. Download the `AuthKey_<KEYID>.p8` (it can be downloaded once) and note the Key ID and the Issuer ID shown on
   that page.
2. Store it under a profile name once:

   ```bash
   xcrun notarytool store-credentials notchmeter --key ~/Downloads/AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER-UUID
   ```

   The profile name is `NOTARY_PROFILE`. (`--apple-id you@example.com --team-id TEAMID --password <app-specific
   password>` works too if you prefer an Apple ID.)

### 4. Sparkle signing key

The key exists. `scripts/Info.plist` carries its public half as `SUPublicEDKey`, the v0.1.0 appcast is signed with its
private half, and every installed copy verifies updates against it. **Never generate a second one.** A build signed
with a new key is refused by every copy already installed, there is no way to tell them the key changed, and the
updater does not recover from it; that is the one mistake this pipeline cannot undo.

Sparkle's tools come with the package; any `swift build` leaves them under `.build/artifacts/sparkle/Sparkle/bin/`.
On the Mac that made the key, `generate_appcast` reads it from the login keychain and `scripts/release.sh` needs
nothing. On any other Mac, hand the script the backed-up export instead of running `generate_keys`:

```bash
SPARKLE_KEY_PATH=~/sparkle-private-key.txt DEVELOPER_ID_APP="..." NOTARY_PROFILE=notchmeter scripts/release.sh
```

The export was made on the original Mac with `generate_keys -x ~/sparkle-private-key.txt`, and the same command
re-exports it from that keychain. Keep it outside the repository, for instance in a password manager. It is the only
key that can sign an update for every copy already installed. Lose it and existing users can never be updated in place
again; leak it and anyone can push them a build. Never commit it; `dist/` and `build/` are ignored, and
`~/sparkle-private-key.txt` should not be near the repo at all.

`scripts/release.sh`, `scripts/appcast-check.swift` and `--smoke` all check that `SUPublicEDKey` decodes to 32 bytes,
and the appcast is verified against it before anything is published.

### 5. GitHub Actions secrets

`.github/workflows/release.yml` runs on every `v*` tag. With these repository secrets it signs, notarises and
publishes; without them it publishes an unsigned DMG as a prerelease, says so in the job summary, and refuses to touch
a release that already exists. Optional only if every release is published by hand (path b in "Each release").
Whether all seven exist is reported, by name and never by value, in the summary of the *release secrets present* job
of `.github/workflows/secrets.yml` on every push, so it is known before a tag, not from one.

| Secret | Value |
|---|---|
| `DEVELOPER_ID_APP` | the identity string, `Developer ID Application: Your Name (TEAMID)` |
| `DEVELOPER_ID_APP_P12` | the certificate and private key exported from Keychain Access as `.p12`, base64: `base64 -i developer-id.p12 \| gh secret set DEVELOPER_ID_APP_P12` |
| `DEVELOPER_ID_APP_P12_PASSWORD` | the password chosen at export |
| `NOTARY_API_KEY` | the contents of `AuthKey_KEYID.p8`: `gh secret set NOTARY_API_KEY < AuthKey_KEYID.p8` |
| `NOTARY_API_KEY_ID` | the Key ID |
| `NOTARY_API_ISSUER` | the Issuer ID |
| `SPARKLE_PRIVATE_KEY` | the exported key: `gh secret set SPARKLE_PRIVATE_KEY < ~/sparkle-private-key.txt` |

## Each release

1. Bump `CFBundleShortVersionString` in `scripts/Info.plist` and commit. The release refuses to build if the tag and
   the plist disagree. `CFBundleVersion`, which Sparkle compares, is stamped from `git rev-list --count HEAD`, so it
   only grows and is the same number locally and in CI for the same commit. Build from the commit you tag: v0.1.0 was
   built from a branch three commits past its tag, which is why it shipped as build 89 while the tag counts 86.
2. Build:

   ```bash
   curl -fsSLo previous-appcast.xml https://github.com/Amir-Hackett/notchmeter/releases/latest/download/appcast.xml  # keeps older items in the feed; skip for the first release
   DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notchmeter PREVIOUS_APPCAST=previous-appcast.xml scripts/release.sh
   ```

   `SPARKLE_KEY_PATH=~/sparkle-private-key.txt` uses the exported key instead of the keychain. `RELEASE_NOTES=notes.html`
   embeds an HTML fragment as the update's release notes. Notarisation usually takes one to five minutes; the script
   waits and fails loudly with the `notarytool log` command if Apple rejects the build.

   **A beta** is the hand path only; the workflow ignores a tag with a hyphen in it. Set `CFBundleShortVersionString`
   to the beta's version (`0.2.0-beta.1`) and build with `scripts/release.sh --channel beta`, which writes
   `<sparkle:channel>beta</sparkle:channel>` into the new appcast item, so only copies with *Beta updates* on
   (Settings › Updates; `Updater.swift`, `allowedChannels`) are offered it and everyone else keeps the last stable
   item. Then publish the DMG as a prerelease, and put the merged appcast (`PREVIOUS_APPCAST` plus the beta item)
   onto the current stable release, because the feed is the newest non-prerelease's `appcast.xml`:

   ```bash
   gh release create v0.2.0-beta.1 dist/Notchmeter.dmg --prerelease --target <commit> --title "Notchmeter 0.2.0 beta 1"
   gh release upload v0.1.0 dist/appcast.xml --clobber   # the stable release releases/latest resolves to; the one deliberate --clobber
   ```

   The script prints these two commands, filled in, when `--channel` is set.
3. Publish, one way or the other and never both. Two publishers on one tag used to be how a notarised DMG got replaced; the workflow now refuses (signed) or stands down (unsigned) when a `Notchmeter.dmg` is already on the release, and uploads without `--clobber`, so the second publisher fails rather than replaces. Still: pick one.

   - **Secrets set (step 5)**: `git tag v0.2.0 <commit> && git push origin v0.2.0`, naming the commit the script
     built from (it prints it). The workflow rebuilds from the tag, signs, notarises and creates the release with the
     DMG and the appcast (it fetches the previous appcast itself). The local build was the rehearsal; do not
     `gh release create` as well.
   - **No secrets**: `gh release create v0.2.0 dist/Notchmeter.dmg dist/appcast.xml --target <commit> --title "Notchmeter 0.2.0" --generate-notes`,
     again naming the commit the script built from: without `--target`, a tag that does not exist yet is created on the
     default branch, which may have moved since the build. That creates the tag as well; the workflow it fires builds,
     finds a published release and stands down without touching it, green.

   The script ends with the same two commands, filled in. Either way the workflow never replaces a `Notchmeter.dmg`
   that is already on a release, and it uploads without `--clobber`, so a race with another publisher fails rather than
   deletes: publishing again means a new tag, or deleting the asset first, on purpose.
4. Confirm the feed moved: `curl -fsSL <feed> | grep sparkle:version`. Installed copies check once a day
   (`SUScheduledCheckInterval` 86400) and on *Options → Check for Updates…*.
5. Update `packaging/homebrew/notchmeter.rb` with the version and the DMG's sha256 (the script prints it; on path a it is in the job summary), then copy the file to `Casks/notchmeter.rb` in `Amir-Hackett/homebrew-tap` and push. `brew upgrade --cask notchmeter` should then report the new version; the tap is what users install from, not this repository's copy.

### Verifying on a clean Mac

```bash
spctl --assess --type execute --verbose=2 /Applications/Notchmeter.app   # accepted, source=Notarized Developer ID
xcrun stapler validate /Applications/Notchmeter.app
codesign --display --verbose=4 /Applications/Notchmeter.app 2>&1 | grep -E 'Authority|flags'   # runtime flag, Developer ID chain
/Applications/Notchmeter.app/Contents/MacOS/Notchmeter --smoke | grep updater   # updater: active; never started under --smoke
```

The gate the app applies before starting Sparkle is in `Sources/Notchmeter/Updater.swift`: an https `SUFeedURL`, an
`SUPublicEDKey` that decodes to 32 bytes, and a code signature that names a certificate (read with
`SecCodeCopySigningInformation`; the ad-hoc signature of a local build names none). `/usr/bin/log show --predicate
'subsystem == "com.amirhackett.notchmeter" and category == "updater"' --last 10m` shows the verdict of a normal launch.

## Homebrew

`packaging/homebrew/notchmeter.rb` is the cask. homebrew/cask's acceptance policy
(<https://docs.brew.sh/Package-Acceptance-Policy>) wants a repository at least 30 days old with 30 forks, 30 watchers
or 75 stars for a general submission, and 90 forks, 90 watchers or 225 stars for a self-submission by the owner. Until
then, the tap works for everyone today: the cask is published from `Amir-Hackett/homebrew-tap` (a copy of `packaging/homebrew/notchmeter.rb`) at
`Casks/notchmeter.rb`, and users run `brew tap Amir-Hackett/tap && brew trust --cask Amir-Hackett/tap/notchmeter &&
brew install --cask notchmeter`. The trust step is Homebrew's own: it refuses to load a cask from a tap outside
homebrew/cask until told to, and an install that skips it fails with the command to run. When the gate is
met, `brew bump-cask-pr` or a pull request to homebrew/cask with the same file.

## Troubleshooting

- *notarytool: Invalid* — `xcrun notarytool log <id> --keychain-profile notchmeter` names the file and the reason;
  the usual ones are a missing `--timestamp` or hardened runtime on a nested binary, both of which the script applies.
- *Sparkle: "The update is improperly signed"* on users' Macs — the appcast was signed with a key other than the one
  behind `SUPublicEDKey`. `scripts/release.sh` checks this before it finishes; if it passed, the feed was edited by
  hand afterwards. Regenerate with the same key.
- *Options menu has no "Check for Updates…"* — the gate is closed; `--smoke` prints why on its `updater:` line.
- *A GitHub Actions release is marked prerelease and unsigned* — at least one secret from the table is missing; the
  job summary lists which.

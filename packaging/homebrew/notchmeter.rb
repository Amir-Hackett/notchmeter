# Homebrew cask for Notchmeter.
#
# Not yet in homebrew/cask. The acceptance policy (https://docs.brew.sh/Package-Acceptance-Policy) wants a repository at
# least 30 days old with 30 forks, 30 watchers or 75 stars for a general submission, and 90 forks, 90 watchers or
# 225 stars for a self-submission by the repository owner. Until then it ships from a tap: copy this file to
# Casks/notchmeter.rb in a repository named homebrew-tap under the same account, and users run
#   brew tap Amir-Hackett/tap && brew install --cask notchmeter
# scripts/release.sh prints the sha256 of each DMG; bump `version` and `sha256` together.
# Homebrew refuses to load a cask from a third-party tap until it is trusted, so installing from the tap is
# three commands rather than two: tap, `brew trust --cask Amir-Hackett/tap/notchmeter`, install. The README, the
# site and docs/release.md all say so; change them together.
# A --dry-run DMG is ad-hoc signed and Gatekeeper refuses it on other Macs; a tester installs one with
# `brew install --cask --no-quarantine notchmeter` (docs/release.md, "Testing an unsigned build"). The published
# release is notarised and needs neither.
cask "notchmeter" do
  version "0.2.2"
  sha256 "44f543d35e4cc5d273871e8a7768584596d5c381416a519b79c089cd1d052b2e"

  url "https://github.com/Amir-Hackett/notchmeter/releases/download/v#{version}/Notchmeter.dmg"
  name "Notchmeter"
  desc "Usage rings for Claude Code, Codex, Cursor, Gemini CLI and Copilot beside the MacBook notch or on a screen edge"
  homepage "https://github.com/Amir-Hackett/notchmeter"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  # A bare symbol is the minimum version; the ">= :sonoma" string form is deprecated and warns on every install.
  depends_on macos: :sonoma

  app "Notchmeter.app"
  # The command-line tool is the same executable; Settings › General also links it into ~/.local/bin.
  binary "#{appdir}/Notchmeter.app/Contents/MacOS/Notchmeter", target: "notchmeter"

  uninstall quit: "com.amirhackett.notchmeter"

  # Everything the app writes (README, "What it keeps"): the caches and the daily history, the drain log and the
  # report file under Application Support, the preferences, the pre-2026-09-02 URL cache and cookie jar of the
  # bundle identifier, and the same for the --probe and --render-assets variants.
  zap trash: [
    "~/Library/Application Support/Notchmeter",
    "~/Library/Caches/Notchmeter",
    "~/Library/Caches/com.amirhackett.notchmeter",
    "~/Library/Caches/com.amirhackett.notchmeter.probe",
    "~/Library/Caches/com.amirhackett.notchmeter.render-assets",
    "~/Library/HTTPStorages/com.amirhackett.notchmeter",
    "~/Library/HTTPStorages/com.amirhackett.notchmeter.binarycookies",
    "~/Library/HTTPStorages/com.amirhackett.notchmeter.probe",
    "~/Library/HTTPStorages/com.amirhackett.notchmeter.probe.binarycookies",
    "~/Library/HTTPStorages/com.amirhackett.notchmeter.render-assets",
    "~/Library/HTTPStorages/com.amirhackett.notchmeter.render-assets.binarycookies",
    "~/Library/Preferences/com.amirhackett.notchmeter.plist",
    "~/Library/Preferences/com.amirhackett.notchmeter.render-assets.plist",
  ]
end

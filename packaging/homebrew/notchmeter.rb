# Homebrew cask for Notchmeter.
#
# Not yet in homebrew/cask. The acceptance policy (https://docs.brew.sh/Package-Acceptance-Policy) wants a repository at
# least 30 days old with 30 forks, 30 watchers or 75 stars for a general submission, and 90 forks, 90 watchers or
# 225 stars for a self-submission by the repository owner. Until then it ships from a tap: copy this file to
# Casks/notchmeter.rb in a repository named homebrew-tap under the same account, and users run
#   brew tap Amir-Hackett/tap && brew install --cask notchmeter
# scripts/release.sh prints the sha256 of each DMG; bump `version` and `sha256` together.
# Before the Developer ID exists the DMG is ad-hoc signed and Gatekeeper refuses it on other Macs; a tester can
# install it with `brew install --cask --no-quarantine notchmeter` (docs/release.md, "Testing a build before the
# Developer ID exists"). The notarised release needs neither.
cask "notchmeter" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/Amir-Hackett/notchmeter/releases/download/v#{version}/Notchmeter.dmg"
  name "Notchmeter"
  desc "Usage rings for Claude Code, Codex, Cursor, Gemini CLI and Copilot beside the MacBook notch or on a screen edge"
  homepage "https://github.com/Amir-Hackett/notchmeter"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Notchmeter.app"

  uninstall quit: "com.amirhackett.notchmeter"

  zap trash: [
    "~/Library/Caches/Notchmeter",
    "~/Library/Preferences/com.amirhackett.notchmeter.plist",
  ]
end

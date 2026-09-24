# Contributing to Notchmeter

A token exposure, an unexpected network destination or a hole in the local API goes to [SECURITY.md](SECURITY.md), not to a public issue. Run `scripts/test.sh` before a pull request; CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs the same tests plus a release build that fails on any compiler warning under `Sources/`, and assembles the app; a weekly workflow ([`.github/workflows/pricing.yml`](.github/workflows/pricing.yml)) diffs Anthropic's pricing page against the committed snapshot and fails loudly when a rate moved. CI builds pull requests and manual runs only, on one runner, cancelling superseded runs and skipping pull requests that only touch documentation: macOS runners bill at ten times the Linux rate, and a day of frequent pushes once spent the account's monthly allowance. Every `v*` tag is gated on the same build and tests by [`.github/workflows/release.yml`](.github/workflows/release.yml) before anything is signed or published. A cost-estimate disagreement is best reported with the [cost-estimate issue form](.github/ISSUE_TEMPLATE/cost-estimate.yml), as a golden-transcript fixture in `Tests/NotchmeterTests/CostGoldenTests.swift`; a new tool is one `UsageProvider` actor and one `ProviderRegistry` line. [`.github/FUNDING.yml`](.github/FUNDING.yml) names the account for GitHub Sponsors (the button appears once the Sponsors profile is enrolled); it is coffee money and nothing here depends on it.

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Building

Needs macOS 15 or later and the Xcode Command Line Tools only; Xcode itself is not required, and everything is plain SwiftPM.

```bash
scripts/build.sh            # build build/Notchmeter.app and ad-hoc sign it
scripts/build.sh run        # build and launch it from build/
scripts/build.sh install    # build, copy to /Applications and relaunch
```

`install` replaces whatever copy is in `/Applications` and quits the running one, so prefer `run` while you work. An ad-hoc signature changes with every build, which drops the Accessibility and Keychain grants each time; `scripts/signing-identity.sh` makes a local identity that keeps them ([docs/permissions.md](docs/permissions.md#why-the-grants-keep-disappearing)). Every other flag the binary takes, from `--probe` to `--render-assets`, is listed in [docs/install.md](docs/install.md#build-and-install).

## Testing

```bash
scripts/test.sh
```

Use the script rather than a bare `swift test`: it passes the Swift Testing framework paths the Command Line Tools need, runs the suites serially (several touch AppKit, and two of them racing the first Window Server connection abort the process), and sets the type-checker budget the test target is held to. The comments at the top of the script say why each flag is there. [docs/testing.md](docs/testing.md) covers the `--smoke` self check, `--probe --json` and the oracle, for changes the unit tests cannot see.

A change to a number the app shows needs a test that pins it; a change to a cost rule needs a golden-transcript fixture and a line in [docs/accuracy.md](docs/accuracy.md), which is the document the README's first line promises.

## No warnings

CI builds `swift build -c release` and fails if any compiler warning originates under `Sources/`; `Vendor/` is exempt. Build clean locally before pushing, since a warning that only CI sees costs a macOS run to find.

## Localization

Every user-visible string goes through `L("…")`, keyed by its English copy, and every key has to be in all six tables under `Sources/Notchmeter/Resources/`: `en`, `ja`, `ko`, `vi`, `zh-Hans` and `zh-Hant`, each `<language>.lproj/Localizable.strings`. `LocalizationTests` (run by `scripts/test.sh`) fails when a table is missing a key the code uses, when a translation's format arguments differ from the English, and when a table carries a key nothing uses any more, so a removed string comes out of all six too. Write a real translation rather than copying the English; the ja, ko, vi and zh-Hant tables were drafted without a native speaker, and a correction from one is a welcome one-line pull request. Adding a language is described in [docs/features.md](docs/features.md#languages).

## Pull requests

- One change per pull request, with a description that says what changed and why, and how you checked it: the test that pins it, or the `--smoke` or `--probe` output where no test can.
- `scripts/test.sh` passes and the release build is warning-free before you ask for review.
- Match the code around the change. Doc comments here explain *why* a thing is the way it is, in plain prose, and there are no TODOs: a known gap goes in [docs/roadmap.md](docs/roadmap.md) instead.
- A change to what is read, sent or kept updates [docs/privacy.md](docs/privacy.md) and, for a request, the table in [docs/accuracy.md](docs/accuracy.md#who-each-request-says-it-is) in the same pull request. A new network destination is a security question first ([SECURITY.md](SECURITY.md)).
- A change to the README's first screen or its Terms paragraph is mirrored in `site/` by hand; `ReleasePackagingTests` checks the two agree.
- Release notes for a version live in `docs/release-notes/<version>.md` ([docs/release.md](docs/release.md#release-notes)); [CHANGELOG.md](CHANGELOG.md) collects them.

import AppKit
import Foundation
import Testing
@testable import Notchmeter

/// Send Feedback's redaction (FeedbackRedaction): nothing the app knows to be a project, a branch, a title, a path,
/// a host, a link or your name survives into the text the sheet shows and sends, the home folder never does, and
/// the placeholders that replace them are stable, distinct and never themselves replaced.
@Suite struct FeedbackRedactionRules {
    static let home = "/Users/amir"
    static let values: [FeedbackRedaction.Kind: [String]] = [
        .project: ["acme-web", "Secret-Sauce", "api"],
        .branch: ["feat/acme-login", "main", "hotfix/billing"],
        .title: ["Fix the billing export for Globex"],
        .path: ["/Users/amir/Work/secret-sauce", "/Volumes/Clients/globex"],
        .host: ["build-box.local"],
        .link: ["https://github.com/acme/acme-web/pull/12"],
        .account: ["amir", "Amir Hackett"],
    ]
    static let names = FeedbackRedaction(home: home, values: values)

    /// Every value that must not survive, each as the test wrote it.
    static let secrets = ["acme-web", "Secret-Sauce", "feat/acme-login", "hotfix/billing", "Fix the billing export for Globex",
                          "/Users/amir", "Work/secret-sauce", "/Volumes/Clients/globex", "build-box.local", "github.com/acme",
                          "Amir Hackett"]

    static let sample = """
        12:00:01 [cost] rescanned /Users/amir/.claude/projects/-Users-amir-Work-secret-sauce (1 file changed)
        12:00:02 [usage] hook UserPromptSubmit from build-box.local in ACME-WEB on feat/acme-login
        {"cwd":"\\/Users\\/amir\\/Work\\/secret-sauce","branch":"hotfix/billing"}
        My session "Fix the billing export for Globex" froze in /Volumes/Clients/globex; PR https://github.com/acme/acme-web/pull/12
        Signed in as Amir Hackett (amir). The secret-sauce repo, and api-server, on main.
        cd /Users/amir/Work/secret-sauce && swift build
        """

    @Test func noProjectBranchTitlePathOrNameSurvives() {
        let result = Self.names.apply(Self.sample)
        for secret in Self.secrets {
            #expect(result.text.range(of: secret, options: .caseInsensitive) == nil, "\(secret) survived: \(result.text)")
        }
        // "amir" goes as a word of its own, in a path's pieces too; the default branch stays.
        #expect(result.text.range(of: "amir", options: .caseInsensitive) == nil)
        #expect(result.text.contains("on main."))
        #expect(result.home)
        let other = result.count(.path, .link, .host, .account)
        #expect(result.count(.project) == 3)
        #expect(result.count(.branch) == 2)
        #expect(result.count(.title) == 1)
        #expect(other == 6)
    }

    /// The one expression that reads the text once (`apply`) gives the same text and the same names as the scan
    /// it replaced, one name at a time over the whole text (`scan`), which is the reference it is held to.
    @Test func theExpressionReadsAsTheScanDoes() {
        var scrubbed = Self.sample
        for spelling in [Self.home, Self.home.replacingOccurrences(of: "/", with: "\\/")] {
            scrubbed = FeedbackRedaction.replace(spelling, with: "~", in: scrubbed)
        }
        let expression = Self.names.apply(Self.sample)
        let (text, matched) = Self.names.scan(scrubbed)
        #expect(expression.text == text)
        #expect(expression.matched == matched)
        let tricky = FeedbackRedaction(home: "", values: [.project: ["project", "branch"], .branch: ["title"]])
        #expect(tricky.apply("project branch title").text == tricky.scan("project branch title").0)
        #expect(Self.names.pattern != nil)
        #expect(FeedbackRedaction(home: "", values: [:]).pattern == nil)
    }

    /// A name replaced as a word, whatever its case, and never inside another word. The projects are numbered by
    /// name: acme-web, api, Secret-Sauce.
    @Test func aNameIsReplacedAsAWordAndNotInsideOne() {
        let result = Self.names.apply("rapid API calls; api-server; therapist; the Api.")
        #expect(result.text == "rapid [project 2] calls; [project 2]-server; therapist; the [project 2].")
    }

    /// The longest name is claimed first, so a branch with a project in it becomes one placeholder, and the text is
    /// matched once, so a placeholder is never replaced again by a name that is also a word in it.
    @Test func longerNamesWinAndPlaceholdersAreNeverReplacedAgain() {
        #expect(Self.names.apply("on feat/acme-login").text == "on [branch 1]")
        let tricky = FeedbackRedaction(home: "", values: [.project: ["project", "branch"], .branch: ["title"]])
        let result = tricky.apply("project branch title")
        #expect(result.text == "[project 2] [project 1] [branch 1]")
    }

    /// A name with a character the expression would otherwise read as its own syntax is matched as written and
    /// as nothing else: unescaped, `c++` would match "c+" and `fix/[urgent].*` the rest of any line.
    @Test func aNameMadeOfPunctuationIsMatchedAsWritten() {
        let names = FeedbackRedaction(home: "", values: [.project: ["c++ (v2)"], .branch: ["fix/[urgent].*"]])
        let result = names.apply("in c++ (v2) on fix/[urgent].* and not c+ (v2) or fix/urgent at all")
        #expect(result.text == "in [project 1] on [branch 1] and not c+ (v2) or fix/urgent at all")
    }

    /// Placeholders are numbered by name within each kind, so the same names give the same text every time.
    @Test func placeholdersAreNumberedInAFixedOrder() {
        let once = FeedbackRedaction(home: "", values: [.project: ["zeta", "alpha", "Mid"]])
        let again = FeedbackRedaction(home: "", values: [.project: ["Mid", "zeta", "alpha"]])
        #expect(once == again)
        #expect(once.apply("zeta alpha mid").text == "[project 3] [project 1] [project 2]")
    }

    /// One character, a default branch and the report's own words say nothing about anybody and are left alone.
    @Test func trivialDefaultAndReservedNamesAreLeftAlone() {
        let names = FeedbackRedaction(home: "", values: [
            .project: ["x", "Notchmeter", "claude", "Codex", "Gemini CLI"],
            .branch: ["main", "MASTER", "develop", "dev", "trunk", "HEAD"],
        ])
        #expect(names.terms.isEmpty)
        let text = "Notchmeter: Claude Code ready, Codex ready, Gemini CLI on main, x marks the spot"
        #expect(names.apply(text).text == text)
    }

    /// The home folder is a path: it goes as `~` in both spellings, and never out of the middle of a longer name.
    @Test func theHomeFolderIsReplacedInBothSpellingsAndOnlyWhole() {
        let names = FeedbackRedaction(home: "/Users/amir", values: [:])
        let result = names.apply(#"/Users/amir/x and \/Users\/amir\/y but /Users/amirah/z"#)
        #expect(result.text == #"~/x and ~\/y but /Users/amirah/z"#)
        #expect(result.home)
        #expect(!names.apply("/Users/amirah").home)
    }

    /// A path under the home folder is matched the way the text will spell it once the home folder is `~`.
    @Test func aPathUnderTheHomeFolderIsMatchedAsTheTextSpellsIt() {
        let names = FeedbackRedaction(home: "/Users/amir", values: [.path: ["/Users/amir/Work/globex", "/Users/amir"]])
        #expect(names.terms.map(\.value) == ["~/Work/globex"])
        #expect(names.apply("cd /Users/amir/Work/globex/src").text == "cd [path 1]/src")
    }

    /// A name the app learns twice keeps its first kind, in the order folders, links, titles, projects, branches.
    @Test func aNameClaimedTwiceKeepsTheFirstKind() {
        let names = FeedbackRedaction(home: "", values: [.project: ["globex"], .branch: ["Globex"], .host: ["globex"]])
        #expect(names.terms.count == 1)
        #expect(names.terms.first?.kind == .project)
    }
}

/// What the store hands the redaction: the fixture afternoon's sessions, branches, titles, task lists and cost
/// projects, and nothing of the app's own labels.
@MainActor @Suite struct FeedbackRedactionGathering {
    @Test func everyNameTheFixtureStoreHoldsIsGathered() throws {
        let (store, prefs) = DemoFixtures.store(now: Date())
        let names = FeedbackRedaction.gather(store: store, prefs: prefs, home: DemoFixtures.home, accounts: [DemoFixtures.account])
        let values = Set(names.terms.map(\.value))
        #expect(values.contains("scout"))
        #expect(values.contains("feat/side-notch"))
        #expect(values.contains(DemoFixtures.notchmeterTitle))
        #expect(values.contains(DemoFixtures.scoutTitle))
        for item in DemoFixtures.todoItems { #expect(values.contains(try #require(item.content))) }
        #expect(values.contains(DemoFixtures.account))
        // The app's own words are not names: its fold of the small projects, its own name, a default branch.
        #expect(!values.contains(CostShare.other))
        #expect(!values.contains("notchmeter"))
        #expect(!values.contains("main"))
    }

    /// The fixture report and message through the fixture names: the project, the branch, the account and the
    /// home folder are all gone, and the report still reads as a report, split where its log begins.
    @Test func theFixtureReportComesOutWithNoNameInIt() {
        let (store, prefs) = DemoFixtures.store(now: Date())
        let names = FeedbackRedaction.gather(store: store, prefs: prefs, home: DemoFixtures.home, accounts: [DemoFixtures.account])
        let report = Feedback.Report(redacting: DemoFixtures.diagnostics(now: Date(), extraLines: 5), with: names)
        let message = names.apply(DemoFixtures.feedbackMessage)
        let head = report.head.joined(separator: "\n")
        let log = report.log.joined(separator: "\n")
        for text in [head, log, message.text] {
            for secret in ["scout", "feat/side-notch", DemoFixtures.home, "-sam-"] {
                #expect(!text.localizedCaseInsensitiveContains(secret), "\(secret) survived in \(text)")
            }
        }
        #expect(head.contains("\(AppInfo.name) \(AppInfo.version) diagnostics"))
        #expect(report.head.last?.hasPrefix(Diagnostics.logHeading) == true)
        #expect(!report.log.isEmpty)
        #expect(message.home)
        let replaced = Feedback.Replaced(message: message, report: report)
        #expect(replaced.projects == 1)
        #expect(replaced.branches == 1)
        #expect(replaced.other == 1)
        #expect(replaced.home)
    }
}

/// The payload: the body's shape, the cut that makes a link fit (oldest log lines first, then the diagnostics,
/// then the message), and a mail handed to Mail never cut.
@Suite struct FeedbackPayloadRules {
    static let about = "Notchmeter 0.9.0 · macOS Version 26.0 · en"

    static func raw(lines: Int) -> String {
        var facts = Diagnostics.Facts()
        facts.version = "0.9.0"
        facts.macOS = "Version 26.0"
        let log = (0..<lines).map { String(format: "12:%02d:%02d [cost] line %04d of the log, padded to look like a real one", $0 / 60 % 60, $0 % 60, $0) }
        return Diagnostics.report(facts, log: log, now: Date(timeIntervalSince1970: 0), home: "/Users/nobody")
    }

    static func report(lines: Int) -> Feedback.Report {
        Feedback.Report(text: raw(lines: lines))
    }

    @Test func aReportSplitsWhereItsLogBegins() {
        let report = Self.report(lines: 3)
        #expect(report.head.last?.hasPrefix(Diagnostics.logHeading) == true)
        #expect(report.head.first?.hasPrefix("\(AppInfo.name) 0.9.0 diagnostics") == true)
        #expect(report.log.count == 3)
        #expect(report.log.last?.contains("line 0002") == true)
        let noLog = Feedback.Report(text: "just\nfacts")
        #expect(noLog.head == ["just", "facts"])
        #expect(noLog.log.isEmpty)
    }

    /// The raw report is split before it is redacted, so a project that is one of the heading's own words garbles
    /// the heading and nothing else: the log is still the log, and a report too long for a link loses its oldest
    /// lines rather than the whole of itself.
    @Test func aProjectNamedLogStillSplitsTheReport() throws {
        let names = FeedbackRedaction(home: "", values: [.project: ["log", "lines"], .branch: ["minutes"]])
        let report = Feedback.Report(redacting: Self.raw(lines: 600), with: names)
        let expectedLines = 600
        #expect(report.log.count == expectedLines)
        // Numbered by name within the kind: lines, then log.
        #expect(report.head.last?.hasPrefix("unified [project 2], last 10 [branch 1] (600 [project 1]):") == true)
        #expect(report.log.first?.contains("of the [project 2],") == true)
        #expect(report.matched.count == 3)
        let payload = Feedback.payload(message: "Busy", about: Self.about, report: report, route: .browser)
        guard case .logLines(let dropped) = payload.cut else {
            Issue.record("a busy report was cut as \(payload.cut) rather than trimmed")
            return
        }
        #expect(dropped > 0)
        #expect(dropped < expectedLines)
    }

    @Test func aShortPayloadIsSentWhole() throws {
        let payload = Feedback.payload(message: "The ring froze.\nSecond line.", about: Self.about, report: Self.report(lines: 4), route: .browser)
        #expect(payload.cut == .none)
        #expect(payload.title == "The ring froze.")
        // The issue form's Diagnostics field renders as text of its own accord, so the browser's body has no fence.
        #expect(payload.body.hasPrefix("The ring froze.\nSecond line.\n\n---\n\(Self.about)\n\nDiagnostics:\n\(AppInfo.name) 0.9.0 diagnostics"))
        #expect(payload.body.hasSuffix("line 0003 of the log, padded to look like a real one"))
        #expect(!payload.body.contains("```"))
        let url = try #require(payload.url)
        #expect(Feedback.length(of: url, route: .browser) <= Feedback.browserLimit)
        #expect(payload.plainText == "\(payload.title)\n\n\(payload.body)")
        // A mail is one text, so there the diagnostics are fenced.
        let mail = Feedback.payload(message: "The ring froze.", about: Self.about, report: Self.report(lines: 4), route: .mailto)
        #expect(mail.body.contains("\n\nDiagnostics:\n```text\n\(AppInfo.name) 0.9.0 diagnostics"))
        #expect(mail.body.hasSuffix("line 0003 of the log, padded to look like a real one\n```"))
        let without = Feedback.payload(message: "Hi", about: Self.about, report: nil, route: .browser)
        #expect(without.body == "Hi\n\n---\n\(Self.about)")
    }

    /// Too long for a link: the oldest lines go, as few as it takes, every fact stays, and the body says how many.
    /// Each route is held to its own cap in its own measure (Feedback.length).
    @Test func theOldestLogLinesGoFirstAndAsFewAsItTakes() throws {
        let report = Self.report(lines: 600)
        for route in [Feedback.Route.browser, .mailto] {
            let cap = try #require(route.limit)
            let payload = Feedback.payload(message: "Too long", about: Self.about, report: report, route: route)
            guard case .logLines(let dropped) = payload.cut else {
                Issue.record("\(route) was cut as \(payload.cut)")
                continue
            }
            let length = Feedback.length(of: try #require(payload.url), route: route)
            #expect(length <= cap)
            let kept = report.log.count - dropped
            #expect(kept > 0)
            for fact in report.head where !fact.isEmpty { #expect(payload.body.contains(fact)) }
            #expect(payload.body.contains("[\(dropped) older log lines left out to fit the length a link can carry]"))
            #expect(payload.body.contains(report.log[report.log.count - 1]))
            #expect(!payload.body.contains(report.log[dropped - 1]))
            // One more line would not have fitted.
            let more = Feedback.parts(message: "Too long", about: Self.about, report: report, keep: kept + 1)
            let longer = Feedback.length(of: try #require(Feedback.url(route: route, title: payload.title, parts: more)), route: route)
            #expect(longer > cap)
        }
    }

    /// The browser's cap is on the address a signed-out browser is sent to, which is longer than the link, and
    /// the mail link's on the link itself; the same text is therefore cut shorter for the browser.
    @Test func theBrowserIsHeldShorterThanTheMailLink() throws {
        let report = Self.report(lines: 600)
        let browser = Feedback.payload(message: "Same text", about: Self.about, report: report, route: .browser)
        let mail = Feedback.payload(message: "Same text", about: Self.about, report: report, route: .mailto)
        guard case .logLines(let browserDropped) = browser.cut, case .logLines(let mailDropped) = mail.cut else {
            Issue.record("cut as \(browser.cut) and \(mail.cut)")
            return
        }
        #expect(browserDropped > mailDropped)
        let link = try #require(browser.url)
        #expect(link.absoluteString.utf8.count < Feedback.length(of: link, route: .browser))
    }

    @Test func whenNotEvenTheFactsFitTheDiagnosticsGoThenTheMessageIsCut() throws {
        let report = Self.report(lines: 10)
        let limit = 600
        let small = Feedback.payload(message: "Short", about: Self.about, report: report, route: .browser, limit: limit)
        #expect(small.cut == .diagnostics)
        #expect(small.body.hasPrefix("Short\n\n[Diagnostics left out to fit the length a link can carry]\n\n---"))
        let smallLength = Feedback.length(of: try #require(small.url), route: .browser)
        #expect(smallLength <= limit)
        let long = String(repeating: "word ", count: 2_000)
        let cut = Feedback.payload(message: long, about: Self.about, report: report, route: .browser)
        #expect(cut.cut == .message)
        #expect(cut.body.contains("[Message cut to fit the length a link can carry]"))
        let cutLength = Feedback.length(of: try #require(cut.url), route: .browser)
        #expect(cutLength <= Feedback.browserLimit)
    }

    /// Mail's compose window takes the body directly, so it is never cut and carries no link.
    @Test func aMailHandedToMailIsNeverCut() {
        let report = Self.report(lines: 2_000)
        let payload = Feedback.payload(message: "Whole", about: Self.about, report: report, route: .mailCompose)
        #expect(payload.cut == .none)
        #expect(payload.url == nil)
        #expect(payload.body.contains(report.log[0]))
        #expect(payload.body.contains("```text"))
        #expect(payload.recipient == Feedback.address)
        #expect(payload.title == "\(AppInfo.name) feedback: Whole")
    }

    /// The clipboard has no length to fit, and Copy is the way out when nothing takes the link, so it carries
    /// every line whatever the route, with the diagnostics fenced for the markdown box a paste may land in.
    @Test func theClipboardCarriesTheWholeTextWhateverTheRoute() {
        let report = Self.report(lines: 2_000)
        for route in [Feedback.Route.browser, .mailto, .mailCompose] {
            let payload = Feedback.clipboard(message: "Whole", about: Self.about, report: report, route: route)
            #expect(payload.cut == .none)
            #expect(payload.url == nil)
            #expect(payload.route == route)
            #expect(payload.body.contains(report.log[0]))
            #expect(payload.body.contains(report.log[1_999]))
            #expect(!payload.body.contains("left out"))
            #expect(payload.body.contains("\nDiagnostics:\n```text\n"))
            #expect(payload.body.hasSuffix("\n```"))
        }
        let expected = "Whole\n\n---\n\(Self.about)"
        #expect(Feedback.clipboard(message: "Whole", about: Self.about, report: nil, route: .browser).body == expected)
    }

    @Test func theTitleIsTheFirstLineCutShort() {
        #expect(Feedback.title(for: "\n\n   spaced    out  \nrest", route: .browser) == "spaced out")
        #expect(Feedback.title(for: "   ", route: .browser) == "Feedback")
        let long = String(repeating: "a", count: 200)
        let title = Feedback.title(for: long, route: .browser)
        #expect(title.count == Feedback.titleLimit)
        #expect(title.hasSuffix("…"))
        #expect(Feedback.title(for: "Hi", route: .mailto) == "\(AppInfo.name) feedback: Hi")
    }

    @Test func largestFindsTheLastValueThatHolds() {
        #expect(Feedback.largest(in: 0...100, where: { $0 <= 37 }) == 37)
        #expect(Feedback.largest(in: 0...100, where: { _ in true }) == 100)
        #expect(Feedback.largest(in: 0...100, where: { _ in false }) == nil)
        #expect(Feedback.largest(in: 0...0, where: { $0 == 0 }) == 0)
    }

    /// Send is held back for one reason at a time, the shared screen first, then the report on its way, then the
    /// missing message, and not at all otherwise.
    @Test func sendIsHeldBackForTheFirstReasonThatHolds() {
        #expect(Feedback.sendBlock(messageEmpty: false, loading: false, hiddenBySharing: false) == nil)
        #expect(Feedback.sendBlock(messageEmpty: true, loading: false, hiddenBySharing: false) == .emptyMessage)
        #expect(Feedback.sendBlock(messageEmpty: false, loading: true, hiddenBySharing: false) == .loading)
        #expect(Feedback.sendBlock(messageEmpty: false, loading: false, hiddenBySharing: true) == .hiddenBySharing)
        #expect(Feedback.sendBlock(messageEmpty: true, loading: true, hiddenBySharing: false) == .loading)
        #expect(Feedback.sendBlock(messageEmpty: true, loading: true, hiddenBySharing: true) == .hiddenBySharing)
    }
}

/// The links: every reserved character is encoded, so what GitHub or the mail app reads back is what was written,
/// and the address a signed-out browser is sent to is counted as GitHub builds it.
@Suite struct FeedbackLinks {
    static let awkward = "C++ & a=b #1 100% ~/x?y\nsecond line\t“quoted” 日本語 🙂"

    func query(_ url: URL) throws -> [String: String] {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    /// The form named in the link, and each of its fields filled by its id: the message, the version line and
    /// the diagnostics, each exactly as written.
    @Test func anIssueLinkFillsTheFormFieldByField() throws {
        let parts = Feedback.Parts(message: Self.awkward, about: "v 1.0 · en", diagnostics: "d & e\n```not a fence")
        let url = try #require(Feedback.issueURL(title: "A + B", parts: parts))
        #expect(url.host == "github.com")
        #expect(url.path == "/\(Feedback.repository)/issues/new")
        let fields = try query(url)
        #expect(fields["template"] == Feedback.issueTemplate)
        #expect(fields["title"] == "A + B")
        #expect(fields["what"] == Self.awkward)
        #expect(fields["setup"] == "v 1.0 · en")
        #expect(fields["diagnostics"] == "d & e\n```not a fence")
        #expect(fields["body"] == nil)
        // A bare + would read as a space on GitHub's side; it must go as %2B.
        #expect(!url.absoluteString.contains("+"))
        #expect(url.absoluteString.contains("%2B%2B"))
        let bare = try #require(Feedback.issueURL(title: "T", parts: Feedback.Parts(message: "m", about: "a", diagnostics: nil)))
        #expect(try query(bare)["diagnostics"] == nil)
    }

    @Test func aMailtoLinkCarriesTheTextWithCRLFLines() throws {
        let url = try #require(Feedback.mailtoURL(subject: "Hi & bye", body: "one\ntwo\r\nthree"))
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:\(Feedback.address)?"))
        let fields = try query(url)
        #expect(fields["subject"] == "Hi & bye")
        #expect(fields["body"] == "one\r\ntwo\r\nthree")
    }

    @Test func onlyTheUnreservedCharactersAreLeftAsTheyAre() {
        #expect(Feedback.encode("aZ09-._~") == "aZ09-._~")
        #expect(Feedback.encode("a b+c&d=e/f") == "a%20b%2Bc%26d%3De%2Ff")
    }

    /// The two links measured against GitHub on 2026-09-24 (docs/accuracy.md, *Send Feedback's link*): a 4,500-byte
    /// link of plain letters was sent on to a 4,561-byte sign-in address, and one of `%20` escapes to 7,505 bytes.
    @Test func theSignInAddressIsCountedAsGitHubBuildsIt() throws {
        let base = "https://github.com/Amir-Hackett/notchmeter/issues/new?template=bug.yml&title=t&what="
        let linkBytes = 4_500
        let plain = try #require(URL(string: base + String(repeating: "a", count: linkBytes - base.utf8.count)))
        let escapes = try #require(URL(string: base + String(repeating: "%20", count: (linkBytes - base.utf8.count) / 3)))
        #expect(plain.absoluteString.utf8.count == linkBytes)
        #expect(escapes.absoluteString.utf8.count == linkBytes)
        let plainAddress = 4_561
        let escapedAddress = 7_505
        #expect(Feedback.loginRedirectLength(of: plain) == plainAddress)
        #expect(Feedback.loginRedirectLength(of: escapes) == escapedAddress)
        #expect(Feedback.length(of: plain, route: .browser) == plainAddress)
        // A mail link is measured as itself.
        let mail = try #require(Feedback.mailtoURL(subject: "s", body: "b"))
        #expect(Feedback.length(of: mail, route: .mailto) == mail.absoluteString.utf8.count)
        #expect(Feedback.browserLimit < 6_928)
        #expect(Feedback.mailtoLimit < 8_191)
    }
}

/// How the text leaves, and what the oracle hears of it.
@Suite struct FeedbackRouting {
    @Test func githubIsTheBrowserAndMailIsMailOnlyWhenMailIsTheDefault() {
        #expect(Feedback.route(for: .github, defaultMailApp: Feedback.mailBundleID, composeAvailable: true) == .browser)
        #expect(Feedback.route(for: .email, defaultMailApp: Feedback.mailBundleID, composeAvailable: true) == .mailCompose)
        #expect(Feedback.route(for: .email, defaultMailApp: Feedback.mailBundleID, composeAvailable: false) == .mailto)
        #expect(Feedback.route(for: .email, defaultMailApp: "com.microsoft.Outlook", composeAvailable: true) == .mailto)
        #expect(Feedback.route(for: .email, defaultMailApp: nil, composeAvailable: true) == .mailto)
    }

    /// The oracle's line carries how it went and counts, never a word of the message, the report or a name.
    @Test func theOracleHearsCountsAndNeverTheText() throws {
        let names = FeedbackRedaction(home: "/Users/amir", values: [.project: ["globex"], .branch: ["feat/globex-sso"]])
        let message = names.apply("globex broke on feat/globex-sso in /Users/amir/src")
        let payload = Feedback.payload(message: message.text, about: "about", report: nil, route: .browser)
        let fields = Feedback.oracleFields(action: "sent", destination: .github, includesDiagnostics: false, payload: payload,
                                           replaced: Feedback.Replaced(message: message, report: nil))
        let line = try #require(Oracle.line(event: "feedback", fields: fields))
        for word in ["globex", "feat/", "broke", "/Users/amir", "[project", "about"] {
            #expect(!line.contains(word), "\(word) reached the oracle: \(line)")
        }
        #expect(line.contains(#""route":"browser""#))
        #expect(line.contains(#""cut":"none""#))
        #expect(line.contains(#""projects":1"#))
        #expect(line.contains(#""branches":1"#))
        #expect(line.contains(#""home":true"#))
        // A failed hand-over says which way it was going, and nothing of the text.
        let failed = try #require(Oracle.line(event: "feedback", fields: Feedback.oracleFields(action: "failed", destination: .github, includesDiagnostics: false, payload: payload)))
        #expect(failed.contains(#""action":"failed""#))
        #expect(failed.contains(#""route":"browser""#))
        #expect(!failed.contains("globex"))
    }
}

/// The message field: Tab and Shift-Tab leave it for the next and previous key view, as they leave any field in a
/// dialog, and type nothing; Return is still a new line.
@MainActor @Suite struct FeedbackKeyboard {
    /// A view that can be a key view whatever Full Keyboard Access says, standing in for the sheet's controls.
    final class Stop: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test func tabLeavesTheMessageForTheNextControlAndTypesNothing() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let message = FeedbackTextView(frame: NSRect(x: 0, y: 100, width: 300, height: 100))
        let checkbox = Stop(frame: NSRect(x: 0, y: 50, width: 100, height: 20))
        let send = Stop(frame: NSRect(x: 200, y: 50, width: 100, height: 20))
        for view in [message, checkbox, send] { content.addSubview(view) }
        message.nextKeyView = checkbox
        checkbox.nextKeyView = send
        send.nextKeyView = message
        #expect(window.makeFirstResponder(message))
        message.insertTab(nil)
        #expect(window.firstResponder === checkbox)
        #expect(message.string.isEmpty)
        #expect(window.makeFirstResponder(message))
        message.insertBacktab(nil)
        #expect(window.firstResponder === send)
        #expect(window.makeFirstResponder(message))
        message.insertNewline(nil)
        #expect(message.string == "\n")
        #expect(window.firstResponder === message)
    }
}

/// The sheet's two remembered choices, and the way in from the Options menu.
@MainActor @Suite struct FeedbackSettings {
    @Test func theDestinationAndTheDiagnosticsChoiceAreRemembered() {
        let suite = "NotchmeterTests.Feedback"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.feedbackDestination == .github)
        #expect(prefs.feedbackDiagnostics)
        prefs.feedbackDestination = .email
        prefs.feedbackDiagnostics = false
        let reread = Preferences(defaults: defaults)
        #expect(reread.feedbackDestination == .email)
        #expect(!reread.feedbackDiagnostics)
    }

    @Test func theOptionsMenuOffersSendFeedbackAndItReachesTheAction() throws {
        let suite = "NotchmeterTests.FeedbackMenu"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let actions = NotchActions()
        var asked = 0
        actions.sendFeedback = { asked += 1 }
        let options = OptionsMenu(prefs: Preferences(defaults: defaults), actions: actions)
        let item = try #require(options.build().items.first { $0.title == L("Send Feedback…") })
        let target = try #require(item.target as? NSObject)
        let action = try #require(item.action)
        #expect(target.responds(to: action))
        target.perform(action, with: item)
        #expect(asked == 1)
    }
}

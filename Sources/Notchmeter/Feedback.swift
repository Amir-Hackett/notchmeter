import AppKit
import Foundation

/// Send Feedback (Settings › General › About, beside Copy diagnostics, and the Options menu): a message, the
/// diagnostics if you tick them, and the whole of what would leave shown before anything does.
///
/// Notchmeter has no server and this does not give it one. Send hands the text to something already on the Mac
/// that you drive yourself: the browser, opened on a new GitHub issue with the title and body filled in, or the
/// mail app, opened on a message to the address in SECURITY.md. Nothing is filed until you press *Submit new
/// issue* on GitHub, and nothing is mailed until you press Send in the mail app. The one thing the app cannot
/// hold back is the page load itself: a prefilled issue travels in the page's address, so GitHub receives the
/// text as the page opens (and publishes nothing from it). The sheet says so beside the button, and so does
/// docs/privacy.md.
///
/// Before the text is shown, and so before it can be sent, every project name, branch, session title, the home
/// folder and the rest of what `FeedbackRedaction` knows is replaced with a placeholder, in the message as well as
/// in the diagnostics. The preview is built from the same `Payload` the button sends, so what is on screen is
/// what goes: a report too long for a link is cut here, with a line saying so, and the preview shows the cut.
enum Feedback {
    /// Where the person chose to send it; remembered (Preferences.feedbackDestination).
    enum Destination: String, CaseIterable, Sendable {
        case github, email

        var title: String {
            switch self {
            case .github: L("GitHub issue")
            case .email: L("Email")
            }
        }
    }

    /// How the text actually leaves, which is what decides whether it has to fit in a link.
    enum Route: String, Equatable, Sendable {
        /// A new-issue page in the browser, the title and body in its address.
        case browser
        /// Mail's compose window through NSSharingService, the body handed over whole. Only when Mail is the
        /// default mail app: the service opens Mail whatever the default is, and a person who reads mail
        /// elsewhere should get their own app.
        case mailCompose
        /// A `mailto:` link, for whichever app is the default for mail; the body travels in the link.
        case mailto

        var carriesTextInLink: Bool { self != .mailCompose }
    }

    /// What was left out to make the text fit in a link, if anything; the body says the same in a line of its own.
    enum Cut: Equatable, Sendable {
        case none
        /// The oldest log lines, this many of them; every fact above the log is kept.
        case logLines(Int)
        /// The diagnostics as a whole: not even the facts fitted beside the message.
        case diagnostics
        /// The message itself, cut short, with the diagnostics left out.
        case message

        var name: String {
            switch self {
            case .none: "none"
            case .logLines: "logLines"
            case .diagnostics: "diagnostics"
            case .message: "message"
            }
        }
    }

    static let repository = "Amir-Hackett/notchmeter"
    /// The project's address, the one SECURITY.md gives for a report by email.
    static let address = "privacy@notchmeter.com"
    /// The longest link the sheet will open, counted in bytes of the finished, percent-encoded address.
    ///
    /// GitHub refuses a longer one with *414 URI Too Long* ([Creating an issue](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-an-issue),
    /// read 2026-09-24). Its documentation names no figure; the server cuts off at 8,191 bytes
    /// ([github/docs#5136](https://github.com/github/docs/issues/5136), 2021). 8,000 leaves room under that. A
    /// `mailto:` link is held to the same figure: mail apps publish no limit of their own, and one figure for every
    /// link keeps the cut the same whichever way the text leaves.
    static let urlLimit = 8_000
    /// An issue title or subject longer than this is cut, with an ellipsis: it is the first line of the message,
    /// and the rest of the message is right under it.
    static let titleLimit = 80
    static let mailBundleID = "com.apple.mail"

    // MARK: - The diagnostics

    /// The diagnostics report, already through the redaction, split where its facts end and its log begins.
    struct Report: Equatable, Sendable {
        /// Everything above the log, the log's own heading line included.
        let head: [String]
        /// The log lines, oldest first.
        let log: [String]

        init(text: String) {
            let lines = text.components(separatedBy: "\n")
            if let heading = lines.firstIndex(where: { $0.hasPrefix(Diagnostics.logHeading) }) {
                head = Array(lines[...heading])
                log = Array(lines[(heading + 1)...]).filter { !$0.isEmpty }
            } else {
                head = lines
                log = []
            }
        }
    }

    // MARK: - The payload

    /// Exactly what Send hands over, and exactly what the sheet shows.
    struct Payload: Equatable, Sendable {
        let route: Route
        /// The issue title, or the mail's subject.
        let title: String
        let body: String
        /// The link opened, nil for Mail's compose window, which takes the text directly.
        let url: URL?
        let cut: Cut

        /// The recipient as the preview names it: the repository, or the address.
        var recipient: String { route == .browser ? Feedback.repository : Feedback.address }
        /// What Copy puts on the clipboard: the title, then the body.
        var plainText: String { "\(title)\n\n\(body)" }
    }

    /// The payload for a message and (optionally) a report, both already redacted, as it leaves by `route`.
    ///
    /// Everything is kept when it fits, and a mail handed to Mail always fits. When the link would be longer
    /// than `limit`, the oldest log lines go first, as few as it takes, since the newest are the ones about what
    /// just went wrong; then the diagnostics as a whole; and last the message is cut short. Each cut leaves a line
    /// in the body, so the reader of the issue knows something is missing and what.
    static func payload(message: String, about: String, report: Report?, route: Route, limit: Int = urlLimit) -> Payload {
        let title = title(for: message, route: route)
        func make(_ body: String, _ cut: Cut) -> Payload {
            Payload(route: route, title: title, body: body, url: url(route: route, title: title, body: body), cut: cut)
        }
        func fits(_ body: String) -> Bool {
            guard route.carriesTextInLink else { return true }
            guard let url = url(route: route, title: title, body: body) else { return false }
            return url.absoluteString.utf8.count <= limit
        }
        let whole = body(message: message, about: about, report: report, keep: report?.log.count ?? 0)
        if fits(whole) { return make(whole, .none) }
        if let report {
            // A log line costs at least its own bytes in the link, so no more lines than fit by that count can
            // fit once encoded: the search below never builds a body far past the limit.
            var upper = 0
            var bytes = 0
            for line in report.log.reversed() {
                bytes += line.utf8.count + 1
                if bytes > limit { break }
                upper += 1
            }
            if let keep = largest(in: 0...upper, where: { fits(body(message: message, about: about, report: report, keep: $0)) }) {
                return make(body(message: message, about: about, report: report, keep: keep), .logLines(report.log.count - keep))
            }
            let without = body(message: message, about: about, report: nil, keep: 0, droppedDiagnostics: true)
            if fits(without) { return make(without, .diagnostics) }
        }
        let characters = Array(message)
        var upper = 0
        var bytes = 0
        for character in characters {
            bytes += character.utf8.count
            if bytes > limit { break }
            upper += 1
        }
        let keep = largest(in: 0...upper, where: { fits(body(message: String(characters.prefix($0)), about: about, report: nil, keep: 0, cutMessage: true)) }) ?? 0
        return make(body(message: String(characters.prefix(keep)), about: about, report: nil, keep: 0, cutMessage: true), .message)
    }

    /// The largest value in the range the test holds for, given that it holds for every value below one it holds
    /// for (a shorter body fits wherever a longer one does); nil when it holds for none.
    static func largest(in range: ClosedRange<Int>, where holds: (Int) -> Bool) -> Int? {
        guard holds(range.lowerBound) else { return nil }
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            let middle = (low + high + 1) / 2
            if holds(middle) { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The body: the message, a rule, the version line, and the diagnostics in a fenced block with the newest
    /// `keep` log lines. The lines the app writes into the body are English, as the diagnostics themselves are:
    /// they are addressed to whoever reads the issue, not to the person sending it.
    static func body(message: String, about: String, report: Report?, keep: Int, droppedDiagnostics: Bool = false,
                     cutMessage: Bool = false) -> String {
        var out = [message.trimmingCharacters(in: .whitespacesAndNewlines)]
        if cutMessage { out.append("[Message cut to fit the length a link can carry]") }
        out.append("")
        out.append("---")
        out.append(about)
        if let report {
            let kept = Array(report.log.suffix(max(0, keep)))
            out.append("")
            out.append("Diagnostics:")
            out.append("```text")
            out.append(contentsOf: report.head)
            if kept.count < report.log.count {
                out.append("[\(report.log.count - kept.count) older log lines left out to fit the length a link can carry]")
            }
            out.append(contentsOf: kept)
            out.append("```")
        } else if droppedDiagnostics {
            out.append("")
            out.append("[Diagnostics left out to fit the length a link can carry]")
        }
        return out.joined(separator: "\n")
    }

    /// The first line of the message, cut to `titleLimit`; the mail's subject names the app as well, since it
    /// arrives among other mail rather than in the app's own tracker.
    static func title(for message: String, route: Route) -> String {
        let line = message.split(whereSeparator: \.isNewline).lazy
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        let cut = line.count > titleLimit ? String(line.prefix(titleLimit - 1)) + "…" : line
        let title = cut.isEmpty ? "Feedback" : cut
        return route == .browser ? title : "\(AppInfo.name) feedback: \(title)"
    }

    /// The line under the rule: the version with its build stamp, the macOS version and the app's language, which
    /// is the least a bug report needs and nothing that says who sent it.
    static func about(version: String = AppInfo.versionWithBuild, macOS: String = ProcessInfo.processInfo.operatingSystemVersionString,
                      language: String = Localization.current) -> String {
        "\(AppInfo.name) \(version) · macOS \(macOS) · \(language)"
    }

    // MARK: - Links

    /// RFC 3986's unreserved characters, the only ones left as they are. Anything else is percent-encoded, `+`
    /// included: GitHub reads a query the way a form is read, where a bare `+` is a space, so "C++" would arrive
    /// as "C  ". A `&` or `=` in the text would otherwise end the field it is in.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// `https://github.com/<repository>/issues/new?title=…&body=…`, the prefilled new-issue page GitHub documents.
    static func issueURL(title: String, body: String) -> URL? {
        URL(string: "https://github.com/\(repository)/issues/new?title=\(encode(title))&body=\(encode(body))")
    }

    /// `mailto:<address>?subject=…&body=…`, with the body's line breaks as CRLF, which is what RFC 6068 asks of a
    /// body in a mailto link.
    static func mailtoURL(subject: String, body: String) -> URL? {
        let crlf = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        return URL(string: "mailto:\(address)?subject=\(encode(subject))&body=\(encode(crlf))")
    }

    static func url(route: Route, title: String, body: String) -> URL? {
        switch route {
        case .browser: issueURL(title: title, body: body)
        case .mailto: mailtoURL(subject: title, body: body)
        case .mailCompose: nil
        }
    }

    // MARK: - What the sheet reports

    /// How many different names of each kind the preview replaced, over the message and the report together; the
    /// sheet prints it above the preview, and the oracle hears it.
    struct Replaced: Equatable, Sendable {
        var projects = 0
        var branches = 0
        var titles = 0
        /// Paths, links, hosts and your own names.
        var other = 0
        var home = false

        init(_ results: [FeedbackRedaction.Result]) {
            let matched = results.reduce(into: Set<FeedbackRedaction.Term>()) { $0.formUnion($1.matched) }
            projects = matched.count { $0.kind == .project }
            branches = matched.count { $0.kind == .branch }
            titles = matched.count { $0.kind == .title }
            other = matched.count { [.path, .link, .host, .account].contains($0.kind) }
            home = results.contains(where: \.home)
        }
    }

    /// The oracle's `feedback` line: what was done and how, and counts, never a word of the text or a name.
    static func oracleFields(action: String, destination: Destination, includesDiagnostics: Bool, payload: Payload? = nil,
                             replaced: Replaced? = nil) -> [String: Any] {
        var fields: [String: Any] = ["action": action, "destination": destination.rawValue, "diagnostics": includesDiagnostics]
        if let payload {
            fields["route"] = payload.route.rawValue
            fields["length"] = payload.body.count
            fields["cut"] = payload.cut.name
            if case .logLines(let lines) = payload.cut { fields["omitted"] = lines }
        }
        if let replaced {
            fields["replaced"] = ["projects": replaced.projects, "branches": replaced.branches, "titles": replaced.titles,
                                  "other": replaced.other, "home": replaced.home]
        }
        return fields
    }

    // MARK: - Sending

    /// The route for a destination: GitHub is always the browser; mail goes to Mail's compose window only when
    /// Mail is the default mail app and the share service can take the text, and to a `mailto:` link otherwise.
    static func route(for destination: Destination, defaultMailApp: String?, composeAvailable: Bool) -> Route {
        switch destination {
        case .github: .browser
        case .email: defaultMailApp == mailBundleID && composeAvailable ? .mailCompose : .mailto
        }
    }

    /// The same, asked of this Mac: which app opens a `mailto:` link, and whether Mail's share service is there.
    @MainActor
    static func liveRoute(for destination: Destination) -> Route {
        guard destination == .email else { return .browser }
        let mailApp = URL(string: "mailto:").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let compose = NSSharingService(named: .composeEmail)?.canPerform(withItems: ["Notchmeter"]) ?? false
        return route(for: destination, defaultMailApp: mailApp, composeAvailable: compose)
    }

    /// Hands the payload to the browser or the mail app. False when nothing would take it (no app for the link,
    /// or the share service refusing the text), so the sheet can stay up and say so.
    @MainActor
    static func send(_ payload: Payload) -> Bool {
        switch payload.route {
        case .browser, .mailto:
            guard let url = payload.url else { return false }
            return NSWorkspace.shared.open(url)
        case .mailCompose:
            guard let service = NSSharingService(named: .composeEmail) else { return false }
            service.recipients = [address]
            service.subject = payload.title
            guard service.canPerform(withItems: [payload.body]) else { return false }
            service.perform(withItems: [payload.body])
            return true
        }
    }
}

/// What Send Feedback replaces before the text is shown: the home folder, and every name the app holds that could
/// say who you are or what you work on, each with a numbered placeholder so a reader can still tell two apart.
///
/// The names come from the app's own memory (`gather`), never from a file read for the purpose: each session's
/// project, branch, title, the name Claude Code or Cursor gives it, its task list, the machine a remote hook
/// posted from, its pull request link and the folder its editor has open; the status line's project, branch,
/// repository owner and name, pull request link, session and agent names; every project the cost figures have
/// split spend by in the last 90 days; the folders added under *Also read transcripts from*; and your account's
/// short and full names.
///
/// A name is replaced wherever it stands as a word of its own, whatever its case: `acme` goes in "acme-web" and
/// "~/src/acme", and stays in "acmefoods", which is another word. Longer names are matched first, so a branch
/// `feat/acme-login` becomes one placeholder rather than a branch with a project inside it, and the text is
/// matched once, so a placeholder is never itself matched again. Three kinds of name are left as they are, because
/// they say nothing about you and replacing them would garble the report: a name of one character, a branch whose
/// name is a common default (`main`, `master`, `develop`, `dev`, `trunk`, `HEAD`), and a name that is one of the
/// report's own words (the app's name, an assistant's). Over-replacing is the safe way round, and the preview shows
/// the result before anything can leave.
struct FeedbackRedaction: Equatable, Sendable {
    /// In the order a name claimed twice is claimed: a folder that is also a project reads as a folder.
    enum Kind: String, CaseIterable, Sendable {
        case path, link, title, project, branch, host, account

        var placeholder: String {
            switch self {
            case .path: "path"
            case .link: "link"
            case .title: "title"
            case .project: "project"
            case .branch: "branch"
            case .host: "host"
            case .account: "name"
            }
        }
    }

    struct Term: Hashable, Sendable {
        let kind: Kind
        let value: String
        let placeholder: String
    }

    /// What one pass replaced: the text, which names it met at least once, and whether the home folder was in it.
    struct Result: Equatable, Sendable {
        let text: String
        let matched: Set<Term>
        let home: Bool

        func count(_ kinds: Kind...) -> Int { matched.count { kinds.contains($0.kind) } }
    }

    static let defaultBranches: Set<String> = ["main", "master", "develop", "dev", "trunk", "head"]
    static let minimumLength = 2
    /// The words the report is written in, which a project may share a name with: replacing them would turn
    /// "Claude Code: ready" into "[project 1] Code: ready" and tell nobody anything the report does not already say.
    static let reserved: Set<String> = Set(([AppInfo.name] + ToolID.allCases.flatMap { [$0.rawValue, $0.displayName, $0.productName] }
        + HookVendor.allCases.map(\.displayName)).map { $0.lowercased() })

    let home: String
    /// Longest first, which is the order they are matched in.
    let terms: [Term]

    init(home: String, values: [Kind: [String]]) {
        self.home = home
        var seen: Set<String> = []
        var terms: [Term] = []
        for kind in Kind.allCases {
            var kept: [String] = []
            for raw in values[kind] ?? [] {
                var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if kind == .path, !home.isEmpty {
                    if value == home { continue }
                    if value.hasPrefix(home + "/") { value = "~" + value.dropFirst(home.count) }
                }
                let folded = value.lowercased()
                guard value.count >= Self.minimumLength, !Self.reserved.contains(folded), !seen.contains(folded),
                      kind != .branch || !Self.defaultBranches.contains(folded) else { continue }
                seen.insert(folded)
                kept.append(value)
            }
            // Numbered in a fixed order, so the same names give the same placeholders on every preview.
            for (index, value) in kept.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).enumerated() {
                terms.append(Term(kind: kind, value: value, placeholder: "[\(kind.placeholder) \(index + 1)]"))
            }
        }
        self.terms = terms.enumerated().sorted { lhs, rhs in
            lhs.element.value.count != rhs.element.value.count ? lhs.element.value.count > rhs.element.value.count : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Replaces the home folder with `~` (its JSON-escaped spelling too), then every term with its placeholder.
    func apply(_ text: String) -> Result {
        var scrubbed = text
        var homeFound = false
        if !home.isEmpty {
            for spelling in [home, home.replacingOccurrences(of: "/", with: "\\/")] {
                let replaced = Self.replace(spelling, with: "~", in: scrubbed)
                homeFound = homeFound || replaced != scrubbed
                scrubbed = replaced
            }
        }
        var claimed: [(range: Range<String.Index>, term: Term)] = []
        for term in terms {
            for range in Self.occurrences(of: term.value, in: scrubbed) where !claimed.contains(where: { $0.range.overlaps(range) }) {
                claimed.append((range, term))
            }
        }
        guard !claimed.isEmpty else { return Result(text: scrubbed, matched: [], home: homeFound) }
        var out = ""
        var cursor = scrubbed.startIndex
        for claim in claimed.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            out += scrubbed[cursor..<claim.range.lowerBound]
            out += claim.term.placeholder
            cursor = claim.range.upperBound
        }
        out += scrubbed[cursor...]
        return Result(text: out, matched: Set(claimed.map(\.term)), home: homeFound)
    }

    /// Every place `value` stands as a word of its own in `text`, ignoring case: an edge of the value that is a
    /// letter or a digit must not run on into another letter or digit.
    static func occurrences(of value: String, in text: String) -> [Range<String.Index>] {
        guard !value.isEmpty else { return [] }
        let leadingWord = value.first.map(isWord) ?? false
        let trailingWord = value.last.map(isWord) ?? false
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: value, options: [.caseInsensitive], range: start..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if (leadingWord && before.map(isWord) == true) || (trailingWord && after.map(isWord) == true) {
                start = text.index(after: range.lowerBound)
            } else {
                found.append(range)
                start = range.upperBound
            }
        }
        return found
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// `value` replaced wherever it is not run on into another word, matching case exactly: the home folder is a
    /// path, and `/Users/amir` must not eat the front of `/Users/amirah`.
    static func replace(_ value: String, with replacement: String, in text: String) -> String {
        guard !value.isEmpty, text.contains(value) else { return text }
        let trailingWord = value.last.map(isWord) ?? false
        var out = ""
        var cursor = text.startIndex
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: value, range: start..<text.endIndex) {
            if trailingWord, range.upperBound < text.endIndex, isWord(text[range.upperBound]) {
                start = text.index(after: range.lowerBound)
                continue
            }
            out += text[cursor..<range.lowerBound]
            out += replacement
            cursor = range.upperBound
            start = range.upperBound
        }
        out += text[cursor...]
        return out
    }
}

extension FeedbackRedaction {
    /// Every name the app is holding right now that the text could carry (see the type's own comment for the
    /// list). `home` and `accounts` are parameters so `--render-assets` can draw a Mac that is not this one.
    @MainActor
    static func gather(store: UsageStore, prefs: Preferences, home: String = Paths.home.path,
                       accounts: [String] = [NSUserName(), NSFullUserName()]) -> FeedbackRedaction {
        var values: [Kind: [String]] = [:]
        func add(_ kind: Kind, _ value: String?) {
            if let value, !value.isEmpty { values[kind, default: []].append(value) }
        }
        for session in store.sessions.all {
            add(.project, session.project)
            add(.branch, session.branch)
            add(.title, session.title)
            add(.title, session.sessionName)
            for item in session.todos?.items ?? [] { add(.title, item.content) }
            add(.host, session.host)
            add(.link, session.prURL)
            if let workspace = session.terminal?.workspace {
                add(.path, workspace)
                add(.project, URL(fileURLWithPath: workspace).lastPathComponent)
            }
        }
        if let line = store.statusline {
            add(.project, line.project)
            add(.branch, line.branch)
            add(.link, line.prURL)
            add(.title, line.sessionName)
            add(.title, line.agentName)
            add(.project, line.repoOwner)
            add(.project, line.repoName)
        }
        if let cost = store.cost {
            let ranges = Array(cost.ranges.values) + cost.providers.flatMap { Array($0.ranges.values) }
            // "Other" is the card's own fold of the small projects, and "Cowork" the label Claude Desktop's
            // sessions are filed under: both are the app's words, not a folder of yours.
            for name in Set(ranges.flatMap(\.byProject.keys)) where name != CostShare.other && name != "Cowork" {
                add(.project, name)
            }
        }
        for root in prefs.extraTranscriptRoots { add(.path, root) }
        for account in accounts { add(.account, account) }
        return FeedbackRedaction(home: home, values: values)
    }
}

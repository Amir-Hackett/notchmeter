import Foundation
import Testing
@testable import Notchmeter

/// The usage-tracker pages under `site/`: a hub (`usage-trackers/`) and nine pages, one per tool or question, each a
/// folder with an `index.html` so the URL is the folder on any static host. They are hand-maintained HTML, so what a
/// search engine or a reader relies on is held here rather than trusted: the head each page needs to be found, the
/// JSON-LD (a SoftwareApplication that is this app and never another product's name, and a FAQPage that says
/// exactly what the visible FAQ says), the sitemap and robots, every local link and image resolving, the heading
/// order, and that no page runs a script, loads a tracker or names a competitor. Read off `#filePath` the way
/// `SiteParity` reads the home page.
@Suite struct SiteLandingPages {
    static let site = ClaudeCodePlugin.root.appendingPathComponent("site")
    static let host = "https://www.notchmeter.com/"
    static let dmg = "https://github.com/Amir-Hackett/notchmeter/releases/latest/download/Notchmeter.dmg"
    static let accuracy = "https://github.com/Amir-Hackett/notchmeter/blob/main/docs/accuracy.md"
    static let hub = "usage-trackers"
    static let pages = ["claude-code-usage-tracker", "claude-code-rate-limit-reset", "claude-code-opus-weekly-limit",
                        "codex-cli-usage-tracker", "cursor-usage-tracker", "copilot-usage-tracker",
                        "gemini-cli-quota-tracker", "antigravity-usage-tracker", "ai-usage-tracker-mac"]
    static var all: [String] { [hub] + pages }

    static func folder(_ slug: String) -> URL { site.appendingPathComponent(slug) }

    static func text(_ slug: String) throws -> String {
        try String(contentsOf: folder(slug).appendingPathComponent("index.html"), encoding: .utf8)
    }

    /// Every capture group of every match, in order.
    static func captures(_ pattern: String, in text: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }

    /// The `content` of `<meta property|name="key" content="…">`, or nil.
    static func meta(_ key: String, in html: String) -> String? {
        for attribute in ["property", "name"] {
            if let found = captures("<meta \(attribute)=\"\(NSRegularExpression.escapedPattern(for: key))\" content=\"([^\"]*)\"", in: html).first?.first {
                return found
            }
        }
        return nil
    }

    static func canonical(in html: String) -> String? {
        captures("<link rel=\"canonical\" href=\"([^\"]+)\"", in: html).first?.first
    }

    /// The text a reader sees: tags gone, the entities the pages use decoded, whitespace folded to one space.
    static func plain(_ fragment: String) -> String {
        var text = fragment.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Every `<script type="application/ld+json">` block, parsed.
    static func jsonLD(in html: String, page: String) throws -> [[String: Any]] {
        try captures("<script type=\"application/ld\\+json\">(.*?)</script>", in: html).map { block in
            let data = Data(block[0].utf8)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(page): a JSON-LD block is not a JSON object")
        }
    }

    static func block(_ type: String, in ld: [[String: Any]]) -> [String: Any]? {
        ld.first { $0["@type"] as? String == type }
    }

    @Test func everyPageCarriesTheHeadItNeedsToBeFound() throws {
        for slug in Self.all {
            let html = try Self.text(slug)
            let url = Self.host + slug + "/"
            #expect(Self.canonical(in: html) == url, "\(slug): canonical is the folder's URL")
            #expect(Self.meta("og:url", in: html) == url, "\(slug): og:url is the canonical URL")
            #expect(Self.meta("og:type", in: html) == "website", "\(slug): og:type")
            #expect(Self.meta("og:site_name", in: html) == "Notchmeter", "\(slug): og:site_name")
            #expect(Self.meta("color-scheme", in: html) == "dark", "\(slug): the pages are dark only, so the browser's own scrollbars and controls follow the palette")
            for key in ["description", "og:title", "og:description", "og:image"] {
                #expect(!(Self.meta(key, in: html) ?? "").isEmpty, "\(slug): \(key)")
            }
            let titles = Self.captures("<title>(.*?)</title>", in: html)
            let oneTitle = 1
            #expect(titles.count == oneTitle, "\(slug): one <title>")
            #expect(titles.first?.first?.hasSuffix(" · Notchmeter") == true, "\(slug): the title names the app")
            let h1s = Self.captures("<h1>(.*?)</h1>", in: html)
            #expect(h1s.count == oneTitle, "\(slug): one <h1>")
            #expect(Self.meta("og:title", in: html).map(Self.plain) == h1s.first?.first.map(Self.plain), "\(slug): og:title is the h1")
            #expect(html.contains("<a class=\"skip\" href=\"#main\">"), "\(slug): a skip link")
            #expect(html.contains("<main id=\"main\">"), "\(slug): the skip link's target")
            #expect(html.contains("href=\"../style.css\"") && html.contains("href=\"../landing.css\""), "\(slug): the site's stylesheet and the pages' own")
            #expect(html.contains("href=\"\(Self.accuracy)"), "\(slug): links the accuracy document")
            #expect(html.contains("href=\"\(Self.dmg)\""), "\(slug): a download link")
            if slug != Self.hub {
                #expect(html.contains("href=\"../\(Self.hub)/\""), "\(slug): links the hub")
            }
        }
    }

    /// A search result shows about 155 to 160 characters of a description on a desktop and fewer on a phone (read on
    /// 2026-09-24), so a longer one is cut mid-sentence and whatever it ends on, here the line that the app is free and
    /// never signs in, is the part that goes. Link cards show the Open Graph description whole up to about 200.
    @Test func everyDescriptionFitsASearchSnippetAndALinkCard() throws {
        let snippet = 155
        let card = 200
        for slug in Self.all {
            let html = try Self.text(slug)
            let description = try #require(Self.meta("description", in: html))
            #expect(description.count <= snippet, "\(slug): the description is \(description.count) characters; a snippet shows \(snippet)")
            let og = try #require(Self.meta("og:description", in: html))
            #expect(og.count <= card, "\(slug): og:description is \(og.count) characters; a card shows \(card)")
        }
    }

    /// The structured data says what the page says: this app, on macOS 15 or later, free, in the developer category,
    /// and its aliases are its own name and never another product's.
    @Test func theSoftwareApplicationIsNotchmeterFreeOnMacOSAndNeverAnotherProductsName() throws {
        for slug in Self.all {
            let html = try Self.text(slug)
            let ld = try Self.jsonLD(in: html, page: slug)
            let twoBlocks = 2
            #expect(ld.count == twoBlocks, "\(slug): a SoftwareApplication and a FAQPage")
            let app = try #require(Self.block("SoftwareApplication", in: ld), "\(slug): a SoftwareApplication")
            #expect(app["name"] as? String == "Notchmeter")
            #expect(app["operatingSystem"] as? String == "macOS 15+")
            #expect(app["applicationCategory"] as? String == "DeveloperApplication")
            #expect(app["url"] as? String == Self.host)
            #expect(app["downloadUrl"] as? String == Self.dmg)
            let offer = try #require(app["offers"] as? [String: Any])
            #expect(offer["price"] as? String == "0" && offer["priceCurrency"] as? String == "USD", "\(slug): free")
            #expect(app["isAccessibleForFree"] as? Bool == true)
            let aliases = try #require(app["alternateName"] as? [String], "\(slug): aliases")
            #expect(!aliases.isEmpty)
            for alias in aliases {
                #expect(alias.hasPrefix("Notchmeter"), "\(slug): \(alias) is not this app's own name")
            }
            #expect(app["description"] as? String == Self.meta("description", in: html), "\(slug): the description is the page's")
        }
    }

    /// The FAQPage block is read by search engines as the page's FAQ, so it must be that FAQ, word for word: the same
    /// questions in the same order with the same answers as the visible `<details>` rows.
    @Test func theFAQPageSaysExactlyWhatTheVisibleFAQSays() throws {
        for slug in Self.all {
            let html = try Self.text(slug)
            let visible = Self.captures("<summary>(.*?)</summary>\\s*<p class=\"a\">(.*?)</p>", in: html)
            let page = try #require(Self.block("FAQPage", in: try Self.jsonLD(in: html, page: slug)), "\(slug): a FAQPage")
            let entities = try #require(page["mainEntity"] as? [[String: Any]])
            #expect((4...6).contains(visible.count), "\(slug): \(visible.count) questions; four to six real ones")
            #expect(entities.count == visible.count, "\(slug): the FAQPage has one entry per visible question")
            for (row, entity) in zip(visible, entities) {
                #expect(entity["@type"] as? String == "Question")
                #expect(entity["name"] as? String == Self.plain(row[0]), "\(slug): question \(row[0].prefix(40))…")
                let answer = try #require(entity["acceptedAnswer"] as? [String: Any])
                #expect(answer["@type"] as? String == "Answer")
                #expect(answer["text"] as? String == Self.plain(row[1]), "\(slug): the answer to \(row[0].prefix(40))…")
            }
        }
    }

    @Test func theSitemapListsEveryPageAtItsCanonicalURLAndRobotsPointsAtIt() throws {
        let sitemap = try String(contentsOf: Self.site.appendingPathComponent("sitemap.xml"), encoding: .utf8)
        let listed = Self.captures("<loc>(.*?)</loc>", in: sitemap).map { $0[0] }
        for slug in Self.all {
            let url = try #require(Self.canonical(in: try Self.text(slug)))
            #expect(listed.contains(url), "sitemap.xml lists \(url)")
        }
        for page in ["", "pricing.html", "privacy.html", "terms.html"] {
            #expect(listed.contains(Self.host + page), "sitemap.xml lists the \(page.isEmpty ? "home page" : page)")
        }
        #expect(listed.count == Set(listed).count, "no page listed twice")
        let robots = try String(contentsOf: Self.site.appendingPathComponent("robots.txt"), encoding: .utf8)
        #expect(robots.contains("Sitemap: \(Self.host)sitemap.xml"))
        #expect(robots.contains("Allow: /"))
    }

    /// A relative link or image on a generated page points at a file that exists, an anchor at an id on the page, and
    /// every picture has alternative text; the headings never skip a level, so the outline reads in order.
    @Test func everyLocalLinkAndImageResolvesAndHeadingsDoNotSkipALevel() throws {
        for slug in Self.all {
            let html = try Self.text(slug)
            let folder = Self.folder(slug)
            for href in Self.captures("<a [^>]*href=\"([^\"]+)\"", in: html).map({ $0[0] }) {
                if href.hasPrefix("http://") || href.hasPrefix("https://") || href.hasPrefix("mailto:") { continue }
                let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let path = String(parts[0])
                if path.isEmpty {
                    #expect(html.contains("id=\"\(parts[1])\""), "\(slug): #\(parts[1]) is not on the page")
                    continue
                }
                var target = URL(fileURLWithPath: path, relativeTo: folder).standardizedFileURL
                if path.hasSuffix("/") { target.appendPathComponent("index.html") }
                #expect(FileManager.default.fileExists(atPath: target.path), "\(slug): \(href) resolves to nothing")
            }
            for img in Self.captures("<img ([^>]*)>", in: html).map({ $0[0] }) {
                #expect(img.contains("alt=\""), "\(slug): an image with no alt attribute")
                let src = try #require(Self.captures("src=\"([^\"]+)\"", in: img).first?.first)
                let target = URL(fileURLWithPath: src, relativeTo: folder).standardizedFileURL
                #expect(FileManager.default.fileExists(atPath: target.path), "\(slug): \(src) is missing from site/")
            }
            var previous = 0
            for level in Self.captures("<h([1-6])[ >]", in: html).compactMap({ Int($0[0]) }) {
                #expect(level <= previous + 1, "\(slug): the headings jump from h\(previous) to h\(level)")
                previous = level
            }
        }
    }

    /// A tag that names an attribute twice keeps the first and silently drops the second, so `class="here"
    /// … class="hide-sm"` shows a link the small-screen rule meant to hide (the hub's header, 2026-09-24). No
    /// validator runs on these pages, so the rule is held here: every attribute name on a tag appears once.
    @Test func noTagRepeatsAnAttribute() throws {
        for slug in Self.all {
            let html = try Self.text(slug)
            for tag in Self.captures("<([a-zA-Z][^>]*)>", in: html).map({ $0[0] }) {
                let names = Self.captures("\\s([a-zA-Z-]+)=\"[^\"]*\"", in: tag).map { $0[0].lowercased() }
                #expect(names.count == Set(names).count, "\(slug): <\(tag.prefix(60))…> repeats an attribute")
            }
        }
    }

    /// No analytics, by decision (the note at the head of index.html): the only scripts on these pages are the two
    /// JSON-LD data blocks, which run nothing. And no page compares this app with a named competitor: the category
    /// pages say what this app does and let the reader judge.
    @Test func noPageRunsAScriptLoadsATrackerOrNamesACompetitor() throws {
        let trackers = ["googletagmanager", "google-analytics", "plausible", "_vercel/insights", "va.vercel-scripts",
                        "segment.com", "mixpanel", "hotjar", "clarity.ms", "posthog"]
        let competitors = ["codexisland", "codex island", "codeisland", "vibe-notch", "notchi ", "mioisland", "agentnotch", "openusage", "ccusage"]
        for slug in Self.all {
            let html = try Self.text(slug)
            for tag in Self.captures("(<script[^>]*>)", in: html).map({ $0[0] }) {
                #expect(tag == "<script type=\"application/ld+json\">", "\(slug): \(tag) is not a JSON-LD data block")
            }
            let lower = html.lowercased()
            for tracker in trackers {
                #expect(!lower.contains(tracker), "\(slug) names \(tracker)")
            }
            for name in competitors {
                #expect(!lower.contains(name), "\(slug) names a competitor: \(name)")
            }
        }
    }

    @Test func theHubListsEveryPageAndTheHomePageLinksTheHub() throws {
        let hub = try Self.text(Self.hub)
        for slug in Self.pages {
            #expect(hub.contains("href=\"../\(slug)/\""), "the hub links \(slug)")
        }
        let home = try String(contentsOf: Self.site.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(home.contains("href=\"\(Self.hub)/\""), "the home page links the hub, so the cluster is reachable without the sitemap")
        // The folders on disk are exactly the pages this suite knows, so a page added without a test fails here.
        let folders = try FileManager.default.contentsOfDirectory(atPath: Self.site.path)
            .filter { FileManager.default.fileExists(atPath: Self.site.appendingPathComponent($0).appendingPathComponent("index.html").path) }
        #expect(Set(folders) == Set(Self.all), "the folders under site/ are exactly the pages this suite knows")
    }
}

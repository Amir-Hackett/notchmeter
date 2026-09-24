import AppKit
import Foundation
import Testing
@testable import Notchmeter

/// The documents the repository ships beside the app: the Claude Code plugin under `plugin/` and the marketplace at the root that lists it,
/// the README's first screen and Terms paragraph, which `site/` mirrors by hand, and the site's guides, sitemap and
/// page heads, which nothing but a reader or a crawler would otherwise check. Each is read off `#filePath`, the way
/// `TestHygiene` and `LocalizationTests` read the sources, so a change to one file that leaves its mirror behind
/// fails here rather than on the published page.
@Suite struct ClaudeCodePlugin {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func object(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(path) is not a JSON object")
    }

    static func bundleVersion() throws -> String {
        let data = try Data(contentsOf: root.appendingPathComponent("scripts/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try #require(plist["CFBundleShortVersionString"] as? String)
    }

    @Test func theManifestNamesThePluginTheShippedVersionAndTheSkillFolder() throws {
        let manifest = try Self.object("plugin/.claude-plugin/plugin.json")
        #expect(manifest["name"] as? String == "notchmeter")
        #expect(manifest["license"] as? String == "MIT")
        // The version is the app's, so a release that bumps scripts/Info.plist and forgets this file fails here.
        let shipped = try Self.bundleVersion()
        #expect(manifest["version"] as? String == shipped)

        let skills = try #require(manifest["skills"] as? String, "skills is one path, the folder the README names")
        #expect(skills.hasPrefix("./"), "a plugin path is relative to the plugin root and starts with ./")
        let skillFile = Self.root.appendingPathComponent("plugin").appendingPathComponent(skills).appendingPathComponent("notchmeter/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: skillFile.path), "\(skills) holds notchmeter/SKILL.md")
        let skill = try String(contentsOf: skillFile, encoding: .utf8)
        #expect(skill.hasPrefix("---\nname: notchmeter\n"), "the skill's frontmatter names it after the plugin")
    }

    @Test func theManifestsMCPServerIsTheOneSettingsShows() throws {
        let manifest = try Self.object("plugin/.claude-plugin/plugin.json")
        let servers = try #require(manifest["mcpServers"] as? [String: Any])
        let server = try #require(servers["notchmeter"] as? [String: Any])
        // The friendlier command: the alias Settings › General › Install command line tool creates, since the app may
        // live in /Applications or in build/ and a manifest cannot say which.
        #expect(server["command"] as? String == "notchmeter")
        #expect(server["args"] as? [String] == ["--mcp"])
        // And the same server Settings offers to paste, so the two cannot drift.
        let snippet = try #require(try JSONSerialization.jsonObject(with: Data(MCPServer.snippet(executable: "notchmeter").utf8)) as? [String: Any])
        let shown = try #require((snippet["mcpServers"] as? [String: Any])?["notchmeter"] as? [String: Any])
        #expect(shown["command"] as? String == server["command"] as? String)
        #expect(shown["args"] as? [String] == server["args"] as? [String])
    }

    @Test func theMarketplaceListsThePluginFolder() throws {
        let marketplace = try Self.object(".claude-plugin/marketplace.json")
        #expect(marketplace["name"] as? String == "notchmeter")
        let owner = try #require(marketplace["owner"] as? [String: Any])
        #expect((owner["name"] as? String)?.isEmpty == false)
        let plugins = try #require(marketplace["plugins"] as? [[String: Any]])
        let entry = try #require(plugins.first { $0["name"] as? String == "notchmeter" })
        let source = try #require(entry["source"] as? String, "the plugin is a folder of this repository, a relative source")
        // Its own folder, so a reviewer who opens the source sees only what the plugin loads, not the app around it.
        #expect(source == "./plugin")
        let manifest = Self.root.appendingPathComponent(source).appendingPathComponent(".claude-plugin/plugin.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path), "the source folder holds the plugin manifest")
        let contents = try FileManager.default.contentsOfDirectory(atPath: Self.root.appendingPathComponent(source).path)
        #expect(Set(contents.filter { $0 != ".DS_Store" }) == [".claude-plugin", "skills", "README.md"],
                "the plugin folder holds the manifest, the skills and the README, and nothing a marketplace reviewer has to read past")
        let onlyOne = 1
        #expect(plugins.count == onlyOne)
    }
}

@Suite struct SiteParity {
    static let root = ClaudeCodePlugin.root

    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The README's first screen leads with the job the app does and proves it second, with the accuracy document one
    /// click away; the site's hero says the same two things in the same order. Until 2026-09-24 both led with the proof
    /// ("Every figure on this panel is sourced, dated and tested"), which answered "can I trust the number" before the
    /// reader knew what the number was for.
    static let job = "Know which assistant is waiting, and whether you can afford the next task."
    static let proof = "Every figure sourced, dated and tested"
    static let menuBar = "Your menu bar ran out of room three apps ago. This one doesn't take any."
    static let twoWay = "from the notch"
    static let platform = "macOS 15 or later"

    /// Anthropic's own words, quoted rather than paraphrased, in the README's Terms paragraph and on the site's Terms
    /// page: the credential sentence from Claude Code's "Authentication and credential use" and item 7 of the Consumer
    /// Terms' section 3. Read on 2026-09-20; a change to either page is a change to make in both files, by hand.
    static let credentialQuote = "developers may not collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must complete through Anthropic's own flow."
    static let automatedAccessQuote = "Except when you are accessing our Services via an Anthropic API Key or where we otherwise explicitly permit it, to access the Services through automated or non-human means, whether through a bot, script, or otherwise."

    /// The page's text with its tags removed and its whitespace collapsed, so a sentence can be found however the
    /// markup around it breaks it (the headline carries a `<br>` for wide screens).
    static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// The inner HTML of the first `<tag …>…</tag>`, or nil.
    static func element(_ tag: String, in html: String) -> String? {
        guard let open = html.range(of: "<\(tag)[ >]", options: .regularExpression),
              let close = html.range(of: ">", range: open.lowerBound..<html.endIndex),
              let end = html.range(of: "</\(tag)>", range: close.upperBound..<html.endIndex) else { return nil }
        return String(html[close.upperBound..<end.lowerBound])
    }

    @Test func theFirstScreenLeadsWithTheJobAndProvesItSecond() throws {
        let readme = try Self.text("README.md")
        let lines = readme.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let opening = Array(lines.prefix(3))
        try #require(opening.count == 3)
        #expect(opening[0] == "# Notchmeter")
        #expect(opening[1].contains(Self.job), "the README's first line under the title is the job")
        #expect(opening[2].hasPrefix(Self.proof), "the proof comes second")
        #expect(opening[2].contains("docs/accuracy.md"), "and links the document")

        let index = try Self.text("site/index.html")
        let headline = try #require(Self.element("h1", in: index))
        #expect(Self.plain(headline).trimmingCharacters(in: .whitespaces) == Self.job, "the site's headline is the job")
        // The proof's own paragraph carries the link, so the document is one click from the claim.
        let proofAt = try #require(index.range(of: Self.proof))
        let paragraphEnd = try #require(index.range(of: "</p>", range: proofAt.upperBound..<index.endIndex))
        #expect(index[proofAt.lowerBound..<paragraphEnd.lowerBound].contains("docs/accuracy.md"), "the proof links the document")

        // The same sentences, in the same order, in both files.
        for (name, text) in [("README", readme), ("site/index.html", Self.plain(index))] {
            let positions = [Self.job, Self.proof, Self.menuBar, Self.twoWay].map { text.range(of: $0)?.lowerBound }
            #expect(!positions.contains(nil), "\(name) carries all four lines")
            let found = positions.compactMap { $0 }
            #expect(found == found.sorted(), "\(name): job, proof, menu-bar line, two-way line, in that order")
            #expect(text.contains(Self.platform), "\(name): \(Self.platform)")
        }
    }

    @Test func theTermsQuoteAnthropicVerbatimInBothPlaces() throws {
        let readme = try Self.text("README.md")
        let terms = try Self.text("site/terms.html")
        for quote in [Self.credentialQuote, Self.automatedAccessQuote] {
            #expect(readme.contains(quote), "README: \(quote.prefix(40))…")
            #expect(terms.contains(quote), "site/terms.html: \(quote.prefix(40))…")
        }
        // The reading the quotes are given: no login, no routing, no credential kept, the switch that stops the poll,
        // the user agent every request to Anthropic carries, and the two vendor reads that carry another.
        for claim in ["Also poll Claude's usage endpoint", "every request to Anthropic names itself", "User-Agent: Notchmeter/",
                      "under those clients' own identity"] {
            #expect(readme.contains(claim), "README: \(claim)")
            #expect(terms.contains(claim), "site/terms.html: \(claim)")
        }
        #expect(!readme.contains("grey area"), "Anthropic's position is quoted, not called a grey area")
        #expect(!terms.contains("grey area"))
    }

    /// The pricing page argued until 2026-09-24 that "a paid tier would need an account to check", which is not so: a
    /// licence can be a signed file checked on the Mac. It now gives the real reason, a choice, and says when the choice
    /// will be looked at again.
    @Test func thePricingPageGivesTheRealReasonItIsFree() throws {
        let pricing = try Self.text("site/pricing.html")
        let words = Self.plain(pricing)
        #expect(!words.contains("would need an account"), "the account argument is gone")
        #expect(words.contains("the project chose to be free and open"))
        #expect(words.contains("real download numbers"), "and says the choice will be revisited")
    }
}

/// The guides under `site/guides/`, the index that lists them, and the files that tell a search engine what the site
/// holds. Each guide is written to a question people search for, dated, and stamped with the version it was checked
/// against; these hold the parts a hand edit most easily drops: the head every page needs to be shared and found, the
/// stamp, the sitemap entry, the way back to the index, and the promise that no page measures its reader.
@Suite struct SiteGuides {
    static let site = ClaudeCodePlugin.root.appendingPathComponent("site")
    static let host = "https://www.notchmeter.com/"
    static let published = "2026-09-24"
    static let stamp = "Tested on Notchmeter 0.9.0"
    static let guides = [
        "claude-code-cost-estimate-vs-bill",
        "will-you-run-out-before-the-reset",
        "which-assistant-should-get-this-task",
        "claude-code-notifications-not-working",
        "prompt-cache-cost",
        "cursor-copilot-antigravity-limits",
        "monitor-coding-agents-without-config-writes",
        "macos-agent-notch-apps-compared",
    ]

    /// Every `.html` file under `site/`, as paths relative to it.
    static func pages() throws -> [String] {
        let enumerator = try #require(FileManager.default.enumerator(atPath: site.path))
        return enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".html") }.sorted()
    }

    static func text(_ page: String) throws -> String {
        try String(contentsOf: site.appendingPathComponent(page), encoding: .utf8)
    }

    /// The `content` of `<meta property|name="key" content="…">`, or nil.
    static func meta(_ key: String, in html: String) -> String? {
        for attribute in ["property", "name"] {
            let prefix = "<meta \(attribute)=\"\(key)\" content=\""
            guard let start = html.range(of: prefix) else { continue }
            let rest = html[start.upperBound...]
            if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
        }
        return nil
    }

    static func canonical(in html: String) -> String? {
        guard let start = html.range(of: "<link rel=\"canonical\" href=\"") else { return nil }
        let rest = html[start.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    /// The canonical URL a page at `page` should name: the folder itself for an index, the file otherwise.
    static func expectedCanonical(_ page: String) -> String {
        if page == "index.html" { return host }
        if page.hasSuffix("/index.html") { return host + String(page.dropLast("index.html".count)) }
        return host + page
    }

    @Test func everyGuideIsDatedStampedAndCarriesTheHeadItNeedsToBeFound() throws {
        for slug in Self.guides {
            let page = "guides/\(slug).html"
            let html = try Self.text(page)
            let url = Self.expectedCanonical(page)
            #expect(Self.canonical(in: html) == url, "\(page): canonical")
            #expect(Self.meta("og:url", in: html) == url, "\(page): og:url is the canonical URL")
            #expect(Self.meta("og:type", in: html) == "article", "\(page): shared as an article")
            #expect(Self.meta("article:published_time", in: html) == Self.published, "\(page): published date")
            for key in ["description", "og:title", "og:description", "og:image"] {
                #expect(!(Self.meta(key, in: html) ?? "").isEmpty, "\(page): \(key)")
            }
            let title = try #require(SiteParity.element("title", in: html), "\(page): a <title>")
            let h1 = try #require(SiteParity.element("h1", in: html), "\(page): an <h1>")
            #expect(title.hasPrefix(SiteParity.plain(h1)), "\(page): the title is the question the page answers")
            #expect(html.components(separatedBy: "<h1").count == 2, "\(page): one <h1>")
            #expect(html.contains("<time datetime=\"\(Self.published)\">"), "\(page): dated")
            #expect(html.contains(Self.stamp), "\(page): stamped with the version it was checked against")
            #expect(html.contains("href=\"index.html\""), "\(page): links back to the guides")
            #expect(html.contains("href=\"../style.css\""), "\(page): the site's one stylesheet, and no other")
        }
    }

    @Test func theIndexListsEveryGuideAndNothingElse() throws {
        let index = try Self.text("guides/index.html")
        for slug in Self.guides {
            #expect(index.contains("href=\"\(slug).html\""), "guides/index.html lists \(slug)")
        }
        let onDisk = try Self.pages().filter { $0.hasPrefix("guides/") && $0 != "guides/index.html" }
        #expect(Set(onDisk) == Set(Self.guides.map { "guides/\($0).html" }), "a guide on disk that the list does not name, or the other way round")
    }

    @Test func theSitemapNamesEveryPageAtItsCanonicalURLAndRobotsPointsAtIt() throws {
        let sitemap = try String(contentsOf: Self.site.appendingPathComponent("sitemap.xml"), encoding: .utf8)
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        let listed = sitemap.components(separatedBy: "<loc>").dropFirst().compactMap { $0.components(separatedBy: "</loc>").first }
        var expected: [String] = []
        for page in try Self.pages() {
            let html = try Self.text(page)
            let url = try #require(Self.canonical(in: html), "\(page) names a canonical URL")
            #expect(url == Self.expectedCanonical(page), "\(page): canonical \(url)")
            expected.append(url)
        }
        #expect(Set(listed) == Set(expected), "sitemap.xml lists exactly the pages on disk")
        #expect(listed.count == Set(listed).count, "no page listed twice")
        let robots = try String(contentsOf: Self.site.appendingPathComponent("robots.txt"), encoding: .utf8)
        #expect(robots.contains("Sitemap: \(Self.host)sitemap.xml"))
    }

    /// No analytics, by decision (2026-09-07, the note at the head of index.html): a site selling an app on the
    /// promise that nothing of yours reaches a server of ours does not measure its own readers. The one script on the
    /// site is index.html's inline Windows check, which makes no request; nothing else runs a line of script.
    @Test func noPageLoadsAScriptOrATracker() throws {
        // Hosts in a tag's attributes, not words in the prose: the comparison guide names Mixpanel because another app
        // uses it, and saying so is the point of the page.
        let trackers = ["googletagmanager", "google-analytics", "plausible", "_vercel/insights", "va.vercel-scripts",
                        "segment.com", "mixpanel", "hotjar", "clarity.ms", "posthog"]
        for page in try Self.pages() {
            let tags = Self.tags(in: try Self.text(page)).map { $0.lowercased() }
            for tracker in trackers {
                #expect(!tags.contains { $0.contains(tracker) }, "\(page) loads \(tracker)")
            }
            let scripts = tags.filter { $0.hasPrefix("<script") }
            #expect(!scripts.contains { $0.contains(" src=") }, "\(page) loads an external script")
            if page != "index.html" {
                #expect(scripts.isEmpty, "\(page) runs a script")
            }
        }
        // And the one inline script does what its comment says: no request, no cookie, no storage.
        let index = try Self.text("index.html")
        let script = try #require(SiteParity.element("script", in: index))
        for call in ["fetch(", "XMLHttpRequest", "sendBeacon", "document.cookie", "localStorage", "sessionStorage", "new Image"] {
            #expect(!script.contains(call), "index.html's script uses \(call)")
        }
    }

    /// Every opening tag in the page, comments left out.
    static func tags(in html: String) -> [String] {
        let text = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        var found: [String] = []
        var from = text.startIndex
        while let tag = text.range(of: "<[a-zA-Z][^>]*>", options: .regularExpression, range: from..<text.endIndex) {
            found.append(String(text[tag]))
            from = tag.upperBound
        }
        return found
    }

    /// Every page has the way in to the guides and the way past its own header: the Guides link in the header, and a
    /// skip link to a `main` that exists.
    @Test func everyPageLinksTheGuidesAndCanSkipItsHeader() throws {
        for page in try Self.pages() {
            let html = try Self.text(page)
            let nav = try #require(SiteParity.element("nav", in: html), "\(page): a header nav")
            let guides = page.hasPrefix("guides/") ? "href=\"index.html\"" : "href=\"guides/index.html\""
            #expect(nav.contains(guides) && nav.contains(">Guides</a>"), "\(page): the header links the guides")
            #expect(html.contains("<a class=\"skip\" href=\"#main\">"), "\(page): a skip link")
            #expect(html.range(of: "<main[^>]*id=\"main\"", options: .regularExpression) != nil, "\(page): the skip link's target")
        }
    }
}

/// The Icon Composer document under `packaging/AppIcon.icon`: written by hand (scripts/make-icon-layers.swift draws the
/// layers, icon.json is authored in the repository), compiled only by CI's actool. Nothing here can run actool, so the
/// check is the one a hand-authored document most needs: that every image it names is in `Assets/`, that the layer
/// images are the 1024-pixel PNGs Apple asks for, and that the shape of the file is the one shipping apps' documents
/// share. A typo in an image name would otherwise surface as a failed release build after notarisation.
@Suite struct TahoeIconDocument {
    static let document = ClaudeCodePlugin.root.appendingPathComponent("packaging/AppIcon.icon")

    @Test func everyLayerImageTheDocumentNamesExists() throws {
        let icon = try ClaudeCodePlugin.object("packaging/AppIcon.icon/icon.json")
        let groups = try #require(icon["groups"] as? [[String: Any]])
        #expect((1...4).contains(groups.count), "Icon Composer allows one to four groups")
        var named: [String] = []
        for group in groups {
            let layers = try #require(group["layers"] as? [[String: Any]])
            for layer in layers {
                named.append(try #require(layer["image-name"] as? String))
                for special in layer["image-name-specializations"] as? [[String: Any]] ?? [] {
                    named.append(try #require(special["value"] as? String))
                }
            }
        }
        #expect(!named.isEmpty)
        let assets = Self.document.appendingPathComponent("Assets")
        for name in named {
            let file = assets.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: file.path), "\(name) is named by icon.json and missing from Assets/")
            #expect(name.hasSuffix(".png"), "\(name): the layers are PNGs, since an SVG layer gets no glass material")
        }
        let shipped = try FileManager.default.contentsOfDirectory(atPath: assets.path).filter { !$0.hasPrefix(".") }
        #expect(Set(shipped) == Set(named), "every file in Assets/ is a layer the document names, and the other way round")
    }

    @Test func theLayersAreSquare1024PixelImagesWithAlpha() throws {
        let assets = Self.document.appendingPathComponent("Assets")
        for name in try FileManager.default.contentsOfDirectory(atPath: assets.path) where name.hasSuffix(".png") {
            let image = try #require(NSImage(contentsOf: assets.appendingPathComponent(name)), "\(name) decodes")
            let rep = try #require(image.representations.first as? NSBitmapImageRep, "\(name) is a bitmap")
            let side = 1024
            #expect(rep.pixelsWide == side && rep.pixelsHigh == side, "\(name) is \(rep.pixelsWide)×\(rep.pixelsHigh), not \(side)×\(side)")
            #expect(rep.hasAlpha, "\(name) has an alpha channel: the tile is the document's fill, not the layer's")
        }
    }

    @Test func theDocumentIsMacOSOnlyAndNamedForTheAsset() throws {
        let icon = try ClaudeCodePlugin.object("packaging/AppIcon.icon/icon.json")
        let platforms = try #require(icon["supported-platforms"] as? [String: Any])
        #expect(platforms["squares"] as? String == "shared")
        #expect(platforms["circles"] == nil, "no watch face for a Mac app")
        #expect(icon["fill"] != nil, "the tile is the fill; without one the icon has no background")
        // build.sh compiles it with `--app-icon AppIcon` and names CFBundleIconName the same; the document's name is
        // the asset's name, so it has to be AppIcon.icon.
        #expect(Self.document.lastPathComponent == "AppIcon.icon")
    }
}

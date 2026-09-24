import AppKit
import Foundation
import Testing
@testable import Notchmeter

/// The documents the repository ships beside the app: the Claude Code plugin manifest under `.claude-plugin/`, and
/// the README's first screen and Terms paragraph, which `site/` mirrors by hand. Each is read off `#filePath`, the way
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
        let manifest = try Self.object(".claude-plugin/plugin.json")
        #expect(manifest["name"] as? String == "notchmeter")
        #expect(manifest["license"] as? String == "MIT")
        // The version is the app's, so a release that bumps scripts/Info.plist and forgets this file fails here.
        let shipped = try Self.bundleVersion()
        #expect(manifest["version"] as? String == shipped)

        let skills = try #require(manifest["skills"] as? String, "skills is one path, the folder the README names")
        #expect(skills.hasPrefix("./"), "a plugin path is relative to the plugin root and starts with ./")
        let skillFile = Self.root.appendingPathComponent(skills).appendingPathComponent("notchmeter/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: skillFile.path), "\(skills) holds notchmeter/SKILL.md")
        let skill = try String(contentsOf: skillFile, encoding: .utf8)
        #expect(skill.hasPrefix("---\nname: notchmeter\n"), "the skill's frontmatter names it after the plugin")
    }

    @Test func theManifestsMCPServerIsTheOneSettingsShows() throws {
        let manifest = try Self.object(".claude-plugin/plugin.json")
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

    @Test func theMarketplaceListsThePluginAtTheRepositoryRoot() throws {
        let marketplace = try Self.object(".claude-plugin/marketplace.json")
        #expect(marketplace["name"] as? String == "notchmeter")
        let owner = try #require(marketplace["owner"] as? [String: Any])
        #expect((owner["name"] as? String)?.isEmpty == false)
        let plugins = try #require(marketplace["plugins"] as? [[String: Any]])
        let entry = try #require(plugins.first { $0["name"] as? String == "notchmeter" })
        let source = try #require(entry["source"] as? String, "the plugin is this repository, a relative source")
        #expect(source.hasPrefix("./"))
        let manifest = Self.root.appendingPathComponent(source).appendingPathComponent(".claude-plugin/plugin.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path), "the source folder holds the plugin manifest")
        let onlyOne = 1
        #expect(plugins.count == onlyOne)
    }
}

@Suite struct SiteParity {
    static let root = ClaudeCodePlugin.root

    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The README's first screen leads with the accuracy document; the site's hero carries the same line.
    static let hero = "Every figure on this panel is sourced, dated and tested"
    static let menuBar = "Your menu bar ran out of room three apps ago. This one doesn't take any."
    static let twoWay = "from the notch"
    static let platform = "macOS 15 or later"

    /// Anthropic's own words, quoted rather than paraphrased, in the README's Terms paragraph and on the site's Terms
    /// page: the credential sentence from Claude Code's "Authentication and credential use" and item 7 of the Consumer
    /// Terms' section 3. Read on 2026-09-20; a change to either page is a change to make in both files, by hand.
    static let credentialQuote = "developers may not collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must complete through Anthropic's own flow."
    static let automatedAccessQuote = "Except when you are accessing our Services via an Anthropic API Key or where we otherwise explicitly permit it, to access the Services through automated or non-human means, whether through a bot, script, or otherwise."

    @Test func theHeroLeadsWithTheAccuracyDocumentAndTheSiteRepeatsIt() throws {
        let readme = try Self.text("README.md")
        let index = try Self.text("site/index.html")
        let opening = readme.split(separator: "\n", omittingEmptySubsequences: true).prefix(2).joined(separator: "\n")
        #expect(opening.contains(Self.hero), "the README's first two lines carry the accuracy line")
        #expect(opening.contains("docs/accuracy.md"), "and link the document")
        for line in [Self.hero, Self.menuBar, Self.twoWay, Self.platform] {
            #expect(readme.contains(line), "README: \(line)")
            #expect(index.contains(line), "site/index.html: \(line)")
        }
        #expect(index.contains("docs/accuracy.md"), "the site links the same document")
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

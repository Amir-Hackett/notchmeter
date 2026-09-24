// Proves a generated appcast will verify on users' Macs: the archive's sparkle:edSignature must check out under the
// SUPublicEDKey the app ships, or every update would download and then be refused.
//   swift scripts/appcast-check.swift verify <archive> <appcast.xml> <public-key-base64> <enclosure-url> [--notes <format>] [--deltas <count>]
//       --notes markdown|plain-text|html also requires the enclosure's item to carry a non-empty <description>, with
//       sparkle:format naming that format (HTML carries no attribute, being Sparkle's default), so a release whose notes
//       were meant to be embedded cannot ship an item that shows the update alert an error instead.
//       --deltas <count> also requires the item to carry exactly that many delta enclosures, each served from beside
//       the archive's URL, each file lying beside the archive, and each signature checking out under the same key.
//   swift scripts/appcast-check.swift add-deltas <from-appcast.xml> <into-appcast.xml> <sparkle:version>
//       copies the <sparkle:deltas> of that build's item from one feed into the same build's item in the other, and
//       prints the file name of every delta it names, one a line. scripts/release.sh says why the deltas are made in
//       a feed of their own.
//   swift scripts/appcast-check.swift public-key      reads a `generate_keys -x` seed on stdin, prints its public key
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("appcast-check: " + message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "public-key":
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    guard let seed = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32 else {
        fail("expected the base64 of a 32-byte seed on stdin")
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "verify" where arguments.count >= 6:
    var expectedNotesFormat: String?
    var expectedDeltas: Int?
    var options = arguments[6...].makeIterator()
    while let option = options.next() {
        switch (option, options.next()) {
        case ("--notes", let format?) where ["markdown", "plain-text", "html"].contains(format):
            expectedNotesFormat = format
        case ("--deltas", let count?) where (Int(count) ?? -1) >= 0:
            expectedDeltas = Int(count)
        default:
            fail("verify takes --notes markdown|plain-text|html and --deltas <count>, not \(option)")
        }
    }
    let archive = URL(fileURLWithPath: arguments[2])
    let appcast = try XMLDocument(contentsOf: URL(fileURLWithPath: arguments[3]), options: [])
    guard let keyData = Data(base64Encoded: arguments[4]), keyData.count == 32 else {
        fail("the public key is not the base64 of 32 bytes; is SUPublicEDKey still the placeholder?")
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let enclosures = try appcast.nodes(forXPath: "//enclosure").compactMap { $0 as? XMLElement }
    guard let enclosure = enclosures.first(where: { $0.attribute(forName: "url")?.stringValue == arguments[5] }) else {
        fail("no <enclosure url=\"\(arguments[5])\"> in the appcast")
    }
    guard let signature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
        fail("the enclosure carries no sparkle:edSignature; generate_appcast signs only when the app's SUPublicEDKey is the public half of the signing key, and warns above when it is not")
    }
    let data = try Data(contentsOf: archive)
    if let length = enclosure.attribute(forName: "length")?.stringValue, length != String(data.count) {
        fail("the enclosure says \(length) bytes but \(archive.lastPathComponent) is \(data.count)")
    }
    guard publicKey.isValidSignature(signature, for: data) else {
        fail("the signature on \(archive.lastPathComponent) does not verify under the public key the app ships; the appcast was signed with a different Sparkle key")
    }
    if let format = expectedNotesFormat {
        let item = enclosure.parent as? XMLElement
        guard let description = item?.elements(forName: "description").first else {
            fail("the enclosure's <item> carries no <description>; the release notes were not embedded (generate_appcast needs --embed-release-notes and a notes file named after the archive)")
        }
        let text = description.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            fail("the enclosure's <item> carries an empty <description>; the release notes file was empty")
        }
        let attribute = description.attribute(forName: "sparkle:format")?.stringValue
        let actual = attribute ?? "html"
        guard actual == format else {
            fail("the <description> is \(actual) where \(format) release notes were supplied; the notes file's suffix and its contents disagree")
        }
        print("appcast-check: the item carries \(text.count) characters of \(format) release notes")
    }
    if let expected = expectedDeltas {
        // A delta is applied to the copy a user already has and checked with the public key that copy carries. The key
        // never changes (docs/release.md, "Sparkle signing key"), so the key the new build ships is the one every older
        // copy holds too, and a delta that fails it here would be refused on every Mac it was offered to.
        let item = enclosure.parent as? XMLElement
        let deltas = item?.elements(forName: "sparkle:deltas").first?.elements(forName: "enclosure") ?? []
        guard deltas.count == expected else {
            fail("the enclosure's <item> carries \(deltas.count) delta updates where \(expected) were made")
        }
        let base = URL(string: arguments[5])?.deletingLastPathComponent()
        for delta in deltas {
            guard let url = delta.attribute(forName: "url")?.stringValue.flatMap({ URL(string: $0) }) else {
                fail("a delta enclosure carries no url")
            }
            guard url.deletingLastPathComponent() == base else {
                fail("\(url.absoluteString) is not served from beside \(arguments[5]); it would be uploaded where the feed does not point")
            }
            guard delta.attribute(forName: "sparkle:deltaFrom")?.stringValue?.isEmpty == false else {
                fail("the delta \(url.lastPathComponent) names no sparkle:deltaFrom, so no installed copy would ever take it")
            }
            let file = archive.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent)
            guard let bytes = try? Data(contentsOf: file) else {
                fail("the feed names the delta \(url.lastPathComponent) and there is no \(file.path) to publish")
            }
            if let length = delta.attribute(forName: "length")?.stringValue, length != String(bytes.count) {
                fail("the delta enclosure says \(length) bytes but \(url.lastPathComponent) is \(bytes.count)")
            }
            guard let deltaSignature = delta.attribute(forName: "sparkle:edSignature")?.stringValue.flatMap({ Data(base64Encoded: $0) }),
                  publicKey.isValidSignature(deltaSignature, for: bytes) else {
                fail("the delta \(url.lastPathComponent) is unsigned, or signed with a key other than the one the app ships")
            }
        }
        print("appcast-check: \(deltas.count) delta update\(deltas.count == 1 ? " verifies" : "s verify") under the shipped public key")
    }
    print("appcast-check: \(archive.lastPathComponent) (\(data.count) bytes) verifies under the shipped public key")

case "add-deltas" where arguments.count == 5:
    // Read and written with the options generate_appcast itself uses, so the feed is laid out as generate_appcast would
    // lay it out and the next release's run has nothing to reformat.
    let readOptions: XMLNode.Options = [.nodeLoadExternalEntitiesNever, .nodePreserveCDATA, .nodePreserveWhitespace]
    let into = URL(fileURLWithPath: arguments[3])
    let intoData = try Data(contentsOf: into)
    // A signed feed carries its signature in a trailing comment over the exact bytes, and anything written after
    // generate_appcast voids it. This feed is not signed (no archive asks for it); if that ever changes, this has to
    // fail rather than publish a feed every installed copy refuses.
    if String(decoding: intoData, as: UTF8.self).contains("sparkle-signatures:") {
        fail("\(into.lastPathComponent) is a signed feed; adding the deltas after generate_appcast would break its signature")
    }
    let source = try XMLDocument(contentsOf: URL(fileURLWithPath: arguments[2]), options: readOptions)
    let target = try XMLDocument(data: intoData, options: readOptions)
    func item(in document: XMLDocument) throws -> XMLElement? {
        try document.nodes(forXPath: "/rss/channel/item").compactMap { $0 as? XMLElement }
            .first { $0.elements(forName: "sparkle:version").first?.stringValue == arguments[4] }
    }
    guard let from = try item(in: source) else { fail("no <item> for build \(arguments[4]) in \(arguments[2])") }
    guard let to = try item(in: target) else { fail("no <item> for build \(arguments[4]) in \(into.path)") }
    guard let deltas = from.elements(forName: "sparkle:deltas").first else { exit(0) }
    for existing in to.elements(forName: "sparkle:deltas").reversed() { to.removeChild(at: existing.index) }
    to.addChild(deltas.copy() as! XMLElement)
    try target.xmlData(options: [.nodeCompactEmptyElement, .nodePrettyPrint]).write(to: into)
    for enclosure in deltas.elements(forName: "enclosure") {
        if let name = enclosure.attribute(forName: "url")?.stringValue.flatMap({ URL(string: $0) })?.lastPathComponent {
            print(name)
        }
    }

default:
    fail("usage: verify <archive> <appcast.xml> <public-key-base64> <enclosure-url> [--notes markdown|plain-text|html] [--deltas <count>] | add-deltas <from-appcast.xml> <into-appcast.xml> <sparkle:version> | public-key")
}

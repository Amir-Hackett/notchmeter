// Proves a generated appcast will verify on users' Macs: the archive's sparkle:edSignature must check out under the
// SUPublicEDKey the app ships, or every update would download and then be refused.
//   swift scripts/appcast-check.swift verify <archive> <appcast.xml> <public-key-base64> <enclosure-url>
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

case "verify" where arguments.count == 6:
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
    print("appcast-check: \(archive.lastPathComponent) (\(data.count) bytes) verifies under the shipped public key")

default:
    fail("usage: verify <archive> <appcast.xml> <public-key-base64> <enclosure-url> | public-key")
}

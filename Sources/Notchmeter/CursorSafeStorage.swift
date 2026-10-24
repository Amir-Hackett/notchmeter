import CommonCrypto
import Foundation

/// Cursor moved its session token out of plain sight (seen 2026-10-24): `cursorAuth/accessToken` now holds
/// `cursor-safe-<id>:<n>:<base64>`, where the base64 is Electron safeStorage's macOS format, "v10" followed by
/// AES-128-CBC ciphertext under a key derived from the "Cursor Safe Storage" Keychain password. A value without
/// the prefix is the plain JWT older builds wrote and passes through untouched.
enum CursorSafeStorage {
    static let prefix = "cursor-safe-"
    static let keychainService = "Cursor Safe Storage"

    static func isWrapped(_ value: String) -> Bool { value.hasPrefix(prefix) }

    /// The plain token inside a wrapped value, or nil when it does not decrypt. `password` is only asked for
    /// when the value is wrapped, so a plain JWT never touches the Keychain.
    static func unwrap(_ value: String, password: () throws -> Data) throws -> String? {
        guard isWrapped(value) else { return value }
        guard let payload = value.dropFirst(prefix.count).split(separator: ":", maxSplits: 2).last,
              let sealed = base64(String(payload)), sealed.starts(with: Data("v10".utf8))
        else { return nil }
        let key = try deriveKey(password: password())
        guard let plain = decrypt(sealed.dropFirst(3), key: key) else { return nil }
        return String(data: plain, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Chromium's macOS key: PBKDF2-SHA1 over the Keychain password, salt "saltysalt", 1003 rounds, 16 bytes.
    static func deriveKey(password: Data) -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        _ = key.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     out.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
            }
        }
        return key
    }

    /// AES-128-CBC with PKCS#7 padding and an IV of sixteen spaces, as Chromium writes it.
    static func crypt(_ operation: CCOperation, _ input: Data, key: Data) -> Data? {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, iv, inp.baseAddress, input.count,
                            out.baseAddress, out.count, &written)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }

    static func decrypt(_ ciphertext: Data, key: Data) -> Data? { crypt(CCOperation(kCCDecrypt), Data(ciphertext), key: key) }

    /// Standard or URL-safe base64, padded or not.
    private static func base64(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}

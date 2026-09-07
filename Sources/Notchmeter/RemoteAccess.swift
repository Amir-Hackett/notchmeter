import Foundation
import Security
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "remote")

/// Reaching the local API from another device on the network — a phone, a tablet, a second Mac.
///
/// The API is loopback-only and unauthenticated by default, which is safe precisely because nothing off this Mac can
/// open the socket. Binding it to the network removes that guarantee, so the two changes travel together and neither
/// works without the other: the listener binds beyond loopback only while remote access is on, and every request that
/// did not arrive over loopback must carry `Authorization: Bearer <token>`.
///
/// The token is Notchmeter's own, generated here, 32 random bytes in base64url, and kept in the Keychain rather than
/// in `defaults` so it does not land in a preferences file or a diagnostics dump. It is never a vendor credential, so
/// the app still borrows every usage token it reads and stores none.
///
/// This is deliberately not a public-internet story. There is no relay, no account, nothing of yours leaves this Mac
/// to a third party: pair the phone over the LAN, or over a private network like Tailscale where both devices already
/// trust each other. The token is the second lock, not the first.
enum RemoteAccess {
    static let keychainService = "Notchmeter remote access"

    /// A fresh token: 32 bytes from the system CSPRNG, base64url, no padding.
    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The stored token, or nil when remote access has never been switched on.
    static func token() -> String? {
        guard let data = try? Keychain.genericPassword(service: keychainService, prompt: false),
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    /// The stored token, generating and saving one on first use. nil when the Keychain refuses the write, which is
    /// the one case where remote access must stay off rather than fall back to no authentication.
    @discardableResult
    static func ensureToken() -> String? {
        if let existing = token() { return existing }
        let token = newToken()
        do {
            try Keychain.set(Data(token.utf8), service: keychainService)
            log.notice("generated a remote-access token")
            return token
        } catch {
            log.error("could not store the remote-access token: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Replaces the token, invalidating every device already paired.
    @discardableResult
    static func rotateToken() -> String? {
        try? Keychain.remove(service: keychainService)
        return ensureToken()
    }

    static func forgetToken() {
        try? Keychain.remove(service: keychainService)
    }

    /// Compares in time that does not depend on how much of the token matched, so a wrong guess cannot be improved
    /// by measuring the answer. Length is compared first and leaks only the length.
    static func matches(_ candidate: String, token: String) -> Bool {
        let a = Array(candidate.utf8), b = Array(token.utf8)
        guard !b.isEmpty, a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// The bearer token in an `Authorization` header, or nil when the header is missing or is not a bearer.
    static func bearer(in header: String?) -> String? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.count > 7 else { return nil }
        guard header.prefix(7).lowercased() == "bearer " else { return nil }
        let token = header.dropFirst(7).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Every address this Mac can be reached on, for the Settings row that tells the user what to type into the
    /// phone. IPv4 only, loopback and link-local excluded, sorted so the list does not reshuffle between reads.
    static func lanAddresses() -> [String] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard !text.hasPrefix("169.254."), !text.isEmpty else { continue }
            addresses.append(text)
        }
        return Array(Set(addresses)).sorted()
    }
}

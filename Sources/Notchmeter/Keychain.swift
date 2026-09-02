import Foundation
import NotchmeterShims
import Security

enum KeychainError: Error, Equatable {
    case notFound
    case denied(OSStatus)
    case other(OSStatus)
}

enum Keychain {
    /// Whether reads may raise the Keychain's access dialog for this process. Off, a locked item fails with
    /// errSecInteractionNotAllowed instead of asking. Goes through the C shim because the underlying call is
    /// deprecated with no replacement and Swift has no way to silence that warning.
    static func setPromptsAllowed(_ allowed: Bool) {
        notchmeter_keychain_set_prompts_allowed(allowed)
    }

    /// Reads a generic-password item. The first read of another app's item makes macOS ask the user;
    /// "Always Allow" keeps it quiet afterwards, "Allow" asks again next time.
    static func genericPassword(service: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.other(status) }
            return data
        case errSecItemNotFound:
            throw KeychainError.notFound
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            throw KeychainError.denied(status)
        default:
            throw KeychainError.other(status)
        }
    }

    static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}

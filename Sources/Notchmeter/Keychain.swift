import Foundation
import NotchmeterShims
import os
import Security

enum KeychainError: Error, Equatable {
    case notFound
    case denied(OSStatus)
    case other(OSStatus)
}

/// When the Keychain's access dialog may be raised for Claude Code's login. Claude Code recreates its item on every
/// token refresh, which wipes the "Always Allow" the user gave, so a background read that could ask would raise the
/// dialog over whatever the user is doing every few days. A timer never asks; a click on the ring or Refresh may.
enum KeychainPromptPolicy: String, CaseIterable, Codable, Sendable {
    /// The dialog may appear when the user asks for a read (the ring, Refresh, the toggle), never from a timer.
    case refreshOnly
    /// Never: the reads that need the dialog fall back to the status line, the credentials file or the last reading.
    case never

    var title: String {
        switch self {
        case .refreshOnly: L("On Refresh only")
        case .never: L("Never")
        }
    }

    /// Whether a read may raise the dialog: only an interactive read under the permissive policy.
    func mayPrompt(interactive: Bool) -> Bool {
        self == .refreshOnly && interactive
    }
}

enum Keychain {
    private struct Access {
        var policy = KeychainPromptPolicy.refreshOnly
        var promptsAllowed = true
    }

    private static let access = OSAllocatedUnfairLock(initialState: Access())

    /// Whether reads may raise the Keychain's access dialog for this process. Off, a locked item fails with
    /// errSecInteractionNotAllowed instead of asking. Goes through the C shim because the underlying call is
    /// deprecated with no replacement and Swift has no way to silence that warning.
    static func setPromptsAllowed(_ allowed: Bool) {
        access.withLock { $0.promptsAllowed = allowed }
        notchmeter_keychain_set_prompts_allowed(allowed)
    }

    static func setPolicy(_ policy: KeychainPromptPolicy) {
        access.withLock { $0.policy = policy }
    }

    /// Whether a read may raise the dialog: only one the user asked for (Refresh, the ring, the Assistants toggle),
    /// under the permissive policy, with the process-wide switch on. `interactive` travels with the read that asked
    /// for it, through `UsageProvider.fetch(interactive:)`. It used to be a third field in `Access`, set by
    /// `refreshAll` and cleared by a `defer` in `refresh`, and a process-wide flag cannot say which read armed it:
    /// a Refresh pressed while a timer read was mid-fetch was thrown away by the in-flight guard, and that read's
    /// `defer` then cleared the flag the Refresh had set, so the one read allowed to ask never happened. Worse, a
    /// Refresh that returned early at a guard above the `defer` left the flag set for good, and the next timer read
    /// raised the dialog over the user's work, the exact thing the policy exists to prevent.
    static func mayPrompt(interactive: Bool) -> Bool {
        access.withLock { $0.promptsAllowed && $0.policy.mayPrompt(interactive: interactive) }
    }

    /// Reads a generic-password item. The first read of another app's item makes macOS ask the user;
    /// "Always Allow" keeps it quiet afterwards, "Allow" asks again next time. With `prompt` false the process-wide
    /// dialog switch is held off around the call, so a locked item fails with errSecInteractionNotAllowed.
    static func genericPassword(service: String, prompt: Bool = true) throws -> Data {
        let allowed = access.withLock { $0.promptsAllowed }
        if !prompt, allowed { notchmeter_keychain_set_prompts_allowed(false) }
        defer { if !prompt, allowed { notchmeter_keychain_set_prompts_allowed(true) } }
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

    /// The same item through Apple's own `security` tool over a pipe. Claude Code writes the item with that tool,
    /// so it is already in the item's access list and never raises the dialog; the token travels the pipe and is
    /// never logged or printed. nil when the tool finds no item or is refused.
    static func genericPasswordViaSecurityTool(service: String, timeout: TimeInterval = 4) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let box = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            box.withLock { $0 = data }
            done.leave()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, var data = box.withLock({ $0 }) else { return nil }
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
        return data.isEmpty ? nil : data
    }

    static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}

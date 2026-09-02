import Foundation
import Testing
@testable import Notchmeter

/// The Keychain prompt loop: a timed read never raises the dialog whatever the item's access list says; the
/// credential sources fall through in order; an API-key account is a calm state, not a fault.
@Suite struct KeychainPromptRules {
    init() { Localization.use(language: "en") }

    let credentials = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-test","expiresAt":1900000000000,"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#.utf8)

    @Test func thePolicyDecidesWhenADialogMayAppear() {
        #expect(!KeychainPromptPolicy.refreshOnly.mayPrompt(interactive: false))
        #expect(KeychainPromptPolicy.refreshOnly.mayPrompt(interactive: true))
        #expect(!KeychainPromptPolicy.never.mayPrompt(interactive: false))
        #expect(!KeychainPromptPolicy.never.mayPrompt(interactive: true))
    }

    @Test func aRewrittenItemNeverPromptsFromATimer() throws {
        // The item's access list no longer names the app: the silent read is denied every time.
        var prompted: [Bool] = []
        let denied: (Bool) throws -> Data = { prompt in
            prompted.append(prompt)
            throw KeychainError.denied(errSecInteractionNotAllowed)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-keychain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Timer read, the security tool answers: no prompt, the token comes from the tool.
        let viaTool = try ClaudeProvider.resolveCredentials(configDir: dir, mayPrompt: false, environment: [:], keychain: denied, securityTool: { self.credentials })
        #expect(viaTool.accessToken == "sk-ant-oat01-test")
        #expect(prompted == [false])
        // Timer read, the tool fails too, no file, no variable: "needs your OK", still no prompt.
        prompted = []
        #expect(throws: ProviderError.self) {
            try ClaudeProvider.resolveCredentials(configDir: dir, mayPrompt: false, environment: [:], keychain: denied, securityTool: { nil })
        }
        #expect(prompted == [false])
        do {
            _ = try ClaudeProvider.resolveCredentials(configDir: dir, mayPrompt: false, environment: [:], keychain: denied, securityTool: { nil })
        } catch let error as ProviderError {
            #expect(error.needsAttention)
            #expect(error.message.contains("needs your OK"))
        }
        // An interactive read under the permissive policy asks once, after the tool failed.
        prompted = []
        _ = try? ClaudeProvider.resolveCredentials(configDir: dir, mayPrompt: true, environment: [:], keychain: denied, securityTool: { nil })
        #expect(prompted == [false, true])
    }

    @Test func fallsThroughToTheConfigDirFileTheHomeFileAndTheVariable() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-creds-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let notFound: (Bool) throws -> Data = { _ in throw KeychainError.notFound }
        try credentials.write(to: dir.appendingPathComponent(".credentials.json"))
        let fromFile = try ClaudeProvider.resolveCredentials(configDir: dir, mayPrompt: false, environment: [:], keychain: notFound, securityTool: { nil })
        #expect(fromFile.subscriptionType == "max")
        try fm.removeItem(at: dir.appendingPathComponent(".credentials.json"))
        let fromVariable = try ClaudeProvider.resolveCredentials(configDir: dir, mayPrompt: false, environment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-env", "TERM": "x"],
                                                                 keychain: notFound, securityTool: { nil })
        #expect(fromVariable.accessToken == "sk-ant-oat01-env")
        #expect(fromVariable.expiresAt == nil)
        #expect(ClaudeProvider.credentialFiles(configDir: dir).count == 2)
        #expect(ClaudeProvider.credentialFiles(configDir: Paths.home.appendingPathComponent(".claude")).count == 1)
        #expect(ClaudeProvider.defaultConfigDir(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc", "TERM": "x"]).path == "/tmp/cc")
        #expect(ClaudeProvider.defaultConfigDir(environment: ["TERM": "x"]) == Paths.home.appendingPathComponent(".claude"))
    }

    @Test func anAPIKeyAccountIsCalmNotAFault() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-apikey-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let notFound: (Bool) throws -> Data = { _ in throw KeychainError.notFound }
        let claudeJSON = dir.appendingPathComponent("claude.json")
        #expect(ClaudeProvider.authMode(environment: ["ANTHROPIC_API_KEY": "sk-ant-api03-x", "TERM": "x"], configDir: dir, claudeJSON: claudeJSON) == .apiKey)
        try Data(#"{"apiKeyHelper":"/usr/local/bin/key.sh"}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        #expect(ClaudeProvider.authMode(environment: ["TERM": "x"], configDir: dir, claudeJSON: claudeJSON) == .apiKey)
        try fm.removeItem(at: dir.appendingPathComponent("settings.json"))
        #expect(ClaudeProvider.authMode(environment: ["TERM": "x"], configDir: dir, claudeJSON: claudeJSON) == .none)
        try Data(#"{"oauthAccount":{"emailAddress":"a@b.c"}}"#.utf8).write(to: claudeJSON)
        #expect(ClaudeProvider.authMode(environment: ["TERM": "x"], configDir: dir, claudeJSON: claudeJSON) == .oauth)
        try Data(#"{"hasCompletedOnboarding":true}"#.utf8).write(to: claudeJSON)
        #expect(ClaudeProvider.authMode(environment: ["TERM": "x"], configDir: dir, claudeJSON: claudeJSON) == .apiKey)

        do {
            _ = try ClaudeProvider.resolveCredentials(configDir: dir, mayPrompt: false, environment: ["ANTHROPIC_API_KEY": "sk-ant-api03-x", "TERM": "x"], keychain: notFound, securityTool: { nil })
            Issue.record("expected a throw")
        } catch let error as ProviderError {
            #expect(error.isCalm)
            #expect(!error.needsAttention)
            #expect(error.message.contains("API key"))
        }
        do {
            _ = try ClaudeProvider.resolveCredentials(configDir: dir, mayPrompt: false, environment: ["TERM": "x"], keychain: notFound, securityTool: { nil })
            Issue.record("expected a throw")
        } catch let error as ProviderError {
            #expect(error.needsAttention)
        }
    }
}

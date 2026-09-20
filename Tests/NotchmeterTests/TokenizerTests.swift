import Foundation
import Testing
@testable import Notchmeter

/// Which side of Anthropic's 4.6/4.7 tokenizer boundary a model name falls on: the rule behind the switch-models
/// caveat and the Cost card's $/MTok caption. A name is placed from a version it carries, or from the Fable and
/// Mythos family names, and never from a guess.
@Suite struct TokenizerGenerations {
    @Test func versionedClaudeIdsArePlacedByTheirVersion() {
        #expect(Tokenizer.generation(of: "claude-sonnet-4-7") == .current)
        #expect(Tokenizer.generation(of: "claude-opus-4-8") == .current)
        #expect(Tokenizer.generation(of: "claude-opus-5") == .current)
        #expect(Tokenizer.generation(of: "claude-sonnet-5") == .current)
        #expect(Tokenizer.generation(of: "claude-opus-4-6") == .legacy)
        #expect(Tokenizer.generation(of: "claude-sonnet-4-5-20250929") == .legacy)
        #expect(Tokenizer.generation(of: "claude-haiku-4-5") == .legacy)
        #expect(Tokenizer.generation(of: "claude-opus-4-1") == .legacy)
        #expect(Tokenizer.generation(of: "claude-sonnet-4-20250514") == .legacy)
        #expect(Tokenizer.generation(of: "claude-3-7-sonnet") == .legacy)
        #expect(Tokenizer.generation(of: "claude-3-5-haiku") == .legacy)
        // The cloud forms Claude Code records are read through the same normaliser the pricing table uses.
        #expect(Tokenizer.generation(of: "us.anthropic.claude-opus-4-6-v1@20260101") == .legacy)
        #expect(Tokenizer.generation(of: "anthropic.claude-sonnet-4-7") == .current)
    }

    @Test func fableAndMythosAreAlwaysOnTheNewerSide() {
        #expect(Tokenizer.generation(of: "claude-fable-5-1") == .current)
        #expect(Tokenizer.generation(of: "claude-mythos-5") == .current)
        #expect(Tokenizer.generation(of: "Fable") == .current)
        #expect(Tokenizer.generation(of: "Mythos") == .current)
    }

    /// The vendor's per-model window labels can be bare family names; those carry no version and are not placed,
    /// and a model that is not Claude's is never placed however its version reads.
    @Test func aNameWithNoVersionOrNoClaudeFamilyIsNotPlaced() {
        #expect(Tokenizer.generation(of: "Opus") == nil)
        #expect(Tokenizer.generation(of: "Sonnet") == nil)
        #expect(Tokenizer.generation(of: "Opus 4.6") == .legacy)
        #expect(Tokenizer.generation(of: "Sonnet 4.7") == .current)
        #expect(Tokenizer.generation(of: "Gemini Pro") == nil)
        #expect(Tokenizer.generation(of: "gemini-2.5-pro") == nil)
        #expect(Tokenizer.generation(of: "GPT-5.3-Codex-Spark") == nil)
        #expect(Tokenizer.generation(of: "auto") == nil)
        #expect(Tokenizer.generation(of: "") == nil)
    }

    @Test func aStraddleNeedsBothSidesPlaced() {
        #expect(Tokenizer.straddle("Fable", "Sonnet 4.6"))
        #expect(Tokenizer.straddle("claude-opus-4-6", "claude-sonnet-4-7"))
        #expect(!Tokenizer.straddle("claude-opus-4-6", "claude-sonnet-4-5"))
        #expect(!Tokenizer.straddle("Fable", "Sonnet"))
        #expect(!Tokenizer.straddle("Fable", nil))
        #expect(!Tokenizer.straddle("Gemini Pro", "Gemini Flash"))
    }

    /// The caption names the costliest newer-side model, and only while an older-side one is in the range too.
    @Test func theNewerLeaderIsTheCostliestModelAcrossTheLine() {
        let mixed = ["claude-sonnet-4-5": 30.0, "claude-fable-5-1": 10.0, "claude-opus-4-8": 12.0]
        #expect(Tokenizer.newerLeader(in: mixed) == "claude-opus-4-8")
        #expect(Tokenizer.newerLeader(in: ["claude-sonnet-4-5": 30, "claude-opus-4-6": 12]) == nil)
        #expect(Tokenizer.newerLeader(in: ["claude-fable-5-1": 30, "claude-opus-4-8": 12]) == nil)
        // A model that cannot be placed neither counts as the older side nor blocks the caption.
        #expect(Tokenizer.newerLeader(in: ["Sonnet": 30, "claude-fable-5-1": 10]) == nil)
        #expect(Tokenizer.newerLeader(in: ["claude-sonnet-4-5": 30, "claude-fable-5-1": 10, "auto": 50]) == "claude-fable-5-1")
        #expect(Tokenizer.newerLeader(in: [:]) == nil)
    }
}

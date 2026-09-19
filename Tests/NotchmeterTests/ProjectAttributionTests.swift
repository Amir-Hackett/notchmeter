import Foundation
import Testing
@testable import Notchmeter

/// A git worktree's spend belongs to the repository it was cut from. Until 0.6.0 every agent worktree was its own
/// project on the Cost card's "Top:" line, beside the repository the work was for. The fixture is a real tree in a
/// temp folder: a plain repository, a worktree under its `.claude/worktrees`, one elsewhere on disk, one whose
/// `.git` file is gone, a submodule, and a bare folder that is no checkout at all.
@Suite struct ProjectAttribution {
    struct Fixture {
        let dir: URL
        let repo: URL
        let claudeWorktree: URL
        let elsewhere: URL
        let removed: URL
        let relative: URL
        let submodule: URL
        let plain: URL

        init() throws {
            let fm = FileManager.default
            dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-projects-\(UUID().uuidString)")
            repo = dir.appendingPathComponent("repo")
            try fm.createDirectory(at: repo.appendingPathComponent(".git/worktrees/wf_1"), withIntermediateDirectories: true)
            try fm.createDirectory(at: repo.appendingPathComponent("Sources"), withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: repo.appendingPathComponent(".git/HEAD"))
            // (a) + (b): Claude Code's own shape, with the .git file git writes.
            claudeWorktree = repo.appendingPathComponent(".claude/worktrees/wf_1")
            try fm.createDirectory(at: claudeWorktree.appendingPathComponent("Sources/Notchmeter"), withIntermediateDirectories: true)
            try Data("gitdir: \(repo.path)/.git/worktrees/wf_1\n".utf8).write(to: claudeWorktree.appendingPathComponent(".git"))
            // (a) alone: a worktree anywhere else on disk.
            elsewhere = dir.appendingPathComponent("elsewhere/wt")
            try fm.createDirectory(at: elsewhere.appendingPathComponent("deep/er"), withIntermediateDirectories: true)
            try Data("gitdir: \(repo.path)/.git/worktrees/wt\n".utf8).write(to: elsewhere.appendingPathComponent(".git"))
            // (b) alone: the worktree was removed after the transcript was written, so only the path is left.
            removed = dir.appendingPathComponent("other/.claude/worktrees/gone")
            try fm.createDirectory(at: removed, withIntermediateDirectories: true)
            // git may write the pointer relative to the worktree.
            relative = dir.appendingPathComponent("rel")
            try fm.createDirectory(at: relative, withIntermediateDirectories: true)
            try Data("gitdir: ../repo/.git/worktrees/rel\n".utf8).write(to: relative.appendingPathComponent(".git"))
            // A submodule's .git is a file too, pointing somewhere that is no worktree.
            submodule = repo.appendingPathComponent("vendor/sub")
            try fm.createDirectory(at: submodule, withIntermediateDirectories: true)
            try Data("gitdir: ../../.git/modules/sub\n".utf8).write(to: submodule.appendingPathComponent(".git"))
            plain = dir.appendingPathComponent("plain")
            try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    @Test func aWorktreeIsAttributedToItsRepositoryAndEverythingElseKeepsItsOwnName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = "repo"
        #expect(ProjectName.ofPath(fixture.repo.path) == repository)
        #expect(ProjectName.ofPath(fixture.claudeWorktree.path) == repository)
        #expect(ProjectName.ofPath(fixture.claudeWorktree.appendingPathComponent("Sources/Notchmeter").path) == repository,
                "a cwd inside the worktree walks up to it")
        #expect(ProjectName.ofPath(fixture.elsewhere.path) == repository)
        #expect(ProjectName.ofPath(fixture.elsewhere.appendingPathComponent("deep/er").path) == repository)
        #expect(ProjectName.ofPath(fixture.relative.path) == repository, "a relative gitdir resolves against the worktree")
        #expect(ProjectName.ofPath(fixture.removed.path) == "other", "the .claude/worktrees shape holds once the .git file is gone")
        #expect(ProjectName.ofPath(fixture.removed.appendingPathComponent("src").path) == "other")
        #expect(ProjectName.ofPath(fixture.plain.path) == "plain")
        #expect(ProjectName.ofPath(fixture.submodule.path) == "sub", "a .git file that is not a worktree pointer changes nothing")
        #expect(ProjectName.ofPath(fixture.repo.appendingPathComponent("Sources").path) == "Sources",
                "a plain repository's subfolders keep the names they always had")
        #expect(ProjectName.ofPath("/") == nil)
        #expect(ProjectName.claudeWorktreeRepository(of: URL(fileURLWithPath: "/.claude/worktrees/x")) == nil, "no repository before .claude")
        #expect(ProjectName.claudeWorktreeRepository(of: URL(fileURLWithPath: "/Users/me/repo/.claude/worktrees")) == nil, "no worktree named")
    }

    @Test func theResolverAsksTheFilesystemOncePerDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let resolver = ProjectName.Resolver()
        let deep = fixture.elsewhere.appendingPathComponent("deep/er").path
        let repository = "repo"
        #expect(resolver.name(ofPath: deep) == repository)
        try FileManager.default.removeItem(at: fixture.elsewhere.appendingPathComponent(".git"))
        #expect(resolver.name(ofPath: deep) == repository, "the answer is remembered for the scan")
        #expect(resolver.name(ofPath: fixture.elsewhere.appendingPathComponent("deep").path) == repository,
                "a sibling cwd stops at an ancestor already answered")
        #expect(ProjectName.ofPath(deep) == "er", "a fresh resolver sees the file is gone")
    }

    @Test func theEncodedFolderNameFoldsAClaudeWorktreeToo() {
        let notchmeter = "notchmeter"
        #expect(ClaudeCostScanner.projectName(fromFolder: "-Users-amirhackett-Developer-notchmeter--claude-worktrees-wf_2d9a98ce-1f7-3") == notchmeter)
        #expect(ClaudeCostScanner.projectName(fromFolder: "-Users-amirhackett-Developer-notchmeter") == notchmeter)
        #expect(ClaudeCostScanner.projectName(fromFolder: "-Users-amirhackett--pixel-agents-doer-worktrees-20260821") == "20260821",
                "another tool's worktree folder is not the shape and is left as it was")
        #expect(ClaudeCostScanner.projectName(fromFolder: "-claude-worktrees-x") == "x", "nothing before the shape to fold onto")
    }

    @Test func everyScannerAndHookFoldsTheWorktreeTheSameWay() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cwd = fixture.elsewhere.appendingPathComponent("deep").path
        let repository = "repo"
        let claude = """
        {"type":"assistant","timestamp":"2026-09-19T14:40:00.000Z","requestId":"r1","cwd":"\(cwd)","message":{"id":"m1","model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":10}}}
        """
        let claudeProjects = ClaudeCostScanner.parseFile(Data(claude.utf8), project: "fallback").map(\.project)
        #expect(claudeProjects == [repository])
        let codex = """
        {"timestamp":"2026-09-19T14:00:00.000Z","type":"turn_context","payload":{"cwd":"\(cwd)","model":"gpt-5.3-codex"}}
        {"timestamp":"2026-09-19T14:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}
        """
        let codexProjects = CodexCostScanner.parseFile(Data(codex.utf8)).map(\.project)
        #expect(codexProjects == [repository])
        let hook = try #require(Hook.message(from: Data("{\"hook_event_name\":\"Stop\",\"cwd\":\"\(cwd)\"}".utf8)))
        #expect(hook.project == repository)
        let codexHook = try #require(Hook.message(from: Data("{\"hook_event_name\":\"Stop\",\"cwd\":\"\(cwd)\"}".utf8), tool: .codex))
        #expect(codexHook.project == repository)
        let statusline = try #require(Statusline.message(from: Data("{\"session_id\":\"s\",\"cwd\":\"\(cwd)\"}".utf8)))
        #expect(statusline.project == repository)
    }
}

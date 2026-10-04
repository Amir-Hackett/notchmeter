import Foundation
import Testing
@testable import Notchmeter

/// Cursor's task list, replayed from its transcript (CursorPlans): the lines are shaped as Cursor writes them, an
/// assistant message whose content holds a `tool_use` named `TodoWrite`.
@Suite struct CursorPlanFollowing {
    func line(_ input: String, name: String = "TodoWrite") -> String {
        #"{"role":"assistant","message":{"content":[{"type":"text","text":"Updating the list."},{"type":"tool_use","name":"\#(name)","input":\#(input)}]}}"# + "\n"
    }

    func lines(_ plan: TodoPlan) -> [String] { plan.items.map { "\($0.status.rawValue) \($0.content ?? "-")" } }

    @Test func aWholeListThenMergesByID() {
        var follower = CursorPlanFollower()
        let write = line(#"{"merge":false,"todos":[{"id":"a","content":"Create docker-compose.yml","status":"in_progress"},{"id":"b","content":"Create .gitignore","status":"pending"},{"id":"c","content":"Write the README","status":"pending"}]}"#)
        let changed1 = follower.feed(Data(write.utf8))
        #expect(changed1)
        #expect(lines(follower.plan) == ["in_progress Create docker-compose.yml", "pending Create .gitignore", "pending Write the README"])
        let merge = line(#"{"merge":true,"todos":[{"id":"a","status":"completed"},{"id":"b","content":"Create the .gitignore","status":"in_progress"}]}"#)
        let changed2 = follower.feed(Data(merge.utf8))
        #expect(changed2)
        #expect(lines(follower.plan) == ["completed Create docker-compose.yml", "in_progress Create the .gitignore", "pending Write the README"],
                "a merge changes the items it names, keeps a missing field, and leaves the rest")
        let cancel = line(#"{"merge":true,"todos":[{"id":"c","status":"cancelled"},{"id":"d","content":"Push it","status":"pending"}]}"#)
        let changed3 = follower.feed(Data(cancel.utf8))
        #expect(changed3)
        #expect(lines(follower.plan) == ["completed Create docker-compose.yml", "in_progress Create the .gitignore", "cancelled Write the README", "pending Push it"],
                "a cancelled item stays, crossed out; a new id joins the list")
        #expect(follower.plan.total == 3)
        let replace = line(#"{"merge":false,"todos":[{"id":"x","content":"Start over","status":"pending"},{"id":"y","content":"Old idea","status":"cancelled"}]}"#)
        let changed4 = follower.feed(Data(replace.utf8))
        #expect(changed4)
        #expect(lines(follower.plan) == ["pending Start over", "cancelled Old idea"])
    }

    @Test func aLineStillBeingWrittenWaitsForItsNewline() {
        var follower = CursorPlanFollower()
        let write = Data(line(#"{"merge":false,"todos":[{"id":"a","content":"One","status":"pending"},{"id":"b","content":"Two","status":"pending"}]}"#).utf8)
        let cut = write.count / 2
        let changed5 = follower.feed(write.prefix(cut))
        #expect(!changed5)
        #expect(follower.plan.total == 0)
        let changed6 = follower.feed(write.suffix(from: cut))
        #expect(changed6)
        #expect(follower.plan.total == 2)
        let other = #"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"Shell","input":{"command":"ls"}}]}}"# + "\n"
        let changed7 = follower.feed(Data(other.utf8))
        #expect(!changed7, "a line without the tool changes nothing")
    }

    @Test func aCallThroughCallDynamicToolIsReadToo() {
        var follower = CursorPlanFollower()
        let wrapped = line(#"{"namespace":"cursor","toolName":"TodoWrite","arguments":{"merge":false,"todos":[{"id":"1","content":"Read the card","status":"completed"},{"id":"2","content":"Group the rows","status":"in_progress"}]}}"#, name: "CallDynamicTool")
        let changed8 = follower.feed(Data(wrapped.utf8))
        #expect(changed8)
        #expect(lines(follower.plan) == ["completed Read the card", "in_progress Group the rows"])
        let asString = line(#"{"namespace":"cursor","toolName":"TodoWrite","arguments":"{\"merge\":true,\"todos\":[{\"id\":\"2\",\"status\":\"completed\"}]}"}"#, name: "CallDynamicTool")
        let changed9 = follower.feed(Data(asString.utf8))
        #expect(changed9)
        #expect(follower.plan.done == 2)
        let elsewhere = line(#"{"namespace":"cursor","toolName":"WebSearch","arguments":{"todos":[{"id":"9","content":"x","status":"pending"}]}}"#, name: "CallDynamicTool")
        let changed10 = follower.feed(Data(elsewhere.utf8))
        #expect(!changed10)
        let otherNamespace = line(#"{"namespace":"user-tools","toolName":"TodoWrite","arguments":{"merge":false,"todos":[{"id":"9","content":"Not Cursor","status":"pending"}]}}"#, name: "CallDynamicTool")
        let changed11 = follower.feed(Data(otherNamespace.utf8))
        #expect(!changed11, "a TodoWrite outside the cursor namespace is not this list")
    }

    @Test func aCreatePlanSeedsPendingTasksAndThePlanFileSuppliesStatuses() throws {
        var follower = CursorPlanFollower()
        let created = line(#"{"name":"NBSCTe holiday IVR","overview":"Publish a holiday greeting.","todos":[{"id":"pick-number","content":"Pick a number"},{"id":"publish-calendar","content":"Publish the calendar"}]}"#, name: "CreatePlan")
        let seeded = follower.feed(Data(created.utf8))
        #expect(seeded)
        #expect(lines(follower.plan) == ["pending Pick a number", "pending Publish the calendar"])
        #expect(follower.plan.total == 2)
        #expect(follower.plan.done == 0)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-plan-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".cursor/plans")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("nbscte_holiday_ivr_ec1e8ed4.plan.md")
        let body = """
        ---
        name: NBSCTe holiday IVR
        overview: Publish a holiday greeting.
        todos:
          - id: pick-number
            content: Pick a number
            status: completed
          - id: publish-calendar
            content: Publish the calendar
            status: in_progress
        isProject: false
        ---

        # The plan body is not the task list.
        """
        try Data(body.utf8).write(to: file)
        let matched = try #require(CursorPlanFiles.match(name: follower.planName, ids: Set(follower.items.map(\.id)), home: home))
        #expect(matched == file.standardizedFileURL.resolvingSymlinksInPath())
        let overlaid = follower.readPlanFile(matched)
        #expect(overlaid)
        #expect(lines(follower.plan) == ["completed Pick a number", "in_progress Publish the calendar"])
        #expect(follower.plan.done == 1)
        #expect(follower.plan.total == 2)
        let weak = folder.appendingPathComponent("same_name_aaaaaaaa.plan.md")
        try Data("---\nname: NBSCTe holiday IVR\ntodos:\n  - id: other\n    content: Something else\n    status: pending\n---\n".utf8).write(to: weak)
        #expect(CursorPlanFiles.match(name: "NBSCTe holiday IVR", ids: ["other"], home: home) == weak.standardizedFileURL.resolvingSymlinksInPath())
        #expect(CursorPlanFiles.match(name: "NBSCTe holiday IVR", ids: ["unrelated"], home: home) == nil, "a shared name with no shared task is not this conversation")
        let outside = home.appendingPathComponent("secret.plan.md")
        try Data("---\nname: x\ntodos:\n  - id: pick-number\n    content: a\n    status: pending\n  - id: publish-calendar\n    content: b\n    status: pending\n---\n".utf8).write(to: outside)
        #expect(CursorPlanFiles.allowed(outside.path, home: home) == nil)
    }

    @Test func aFileIsFollowedFromWhereTheLastReadEnded() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-plans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".cursor/projects/Users-me-app/agent-transcripts/c1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("c1.jsonl")
        try Data(line(#"{"merge":false,"todos":[{"id":"a","content":"One","status":"in_progress"},{"id":"b","content":"Two","status":"pending"}]}"#).utf8).write(to: file)
        var follower = CursorPlanFollower()
        let changed11 = follower.read(file)
        #expect(changed11)
        let first = follower.offset
        let changed12 = follower.read(file)
        #expect(!changed12, "nothing added, nothing read")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(#"{"merge":true,"todos":[{"id":"a","status":"completed"},{"id":"b","status":"in_progress"}]}"#).utf8))
        try handle.close()
        let changed13 = follower.read(file)
        #expect(changed13)
        #expect(follower.offset > first)
        #expect(follower.plan.done == 1)
        #expect(CursorPlans.transcript(file.path, home: home) == file.standardizedFileURL)
    }

    @Test func onlyCursorsOwnTranscriptsAreEverRead() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(CursorPlans.transcript("/Users/me/.cursor/projects/p/agent-transcripts/c/c.jsonl", home: home) != nil)
        #expect(CursorPlans.transcript("/Users/me/.cursor/projects/p/agent-transcripts/../../../../.ssh/id_rsa.jsonl", home: home) == nil)
        #expect(CursorPlans.transcript("/Users/me/.ssh/known_hosts", home: home) == nil)
        #expect(CursorPlans.transcript("/Users/me/.cursor/projects/p/notes.jsonl", home: home) == nil, "a transcript lives under agent-transcripts")
        #expect(CursorPlans.transcript("/tmp/.cursor/projects/p/agent-transcripts/c.jsonl", home: home) == nil, "and in this account's home")
        #expect(CursorPlans.transcript(nil, home: home) == nil)
    }

    @Test func aLinkInTheTranscriptsFolderCannotLeadOutOfIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".cursor/projects/p/agent-transcripts/c")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = home.appendingPathComponent("secret.jsonl")
        try Data("{}\n".utf8).write(to: outside)
        let link = folder.appendingPathComponent("c.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(CursorPlans.transcript(link.path, home: home) == nil, "a link to a file outside ~/.cursor/projects is refused")
        let real = folder.appendingPathComponent("d.jsonl")
        try Data("{}\n".utf8).write(to: real)
        #expect(CursorPlans.transcript(real.path, home: home) != nil)
    }

    @Test func theHookPassesTheTranscriptAlong() throws {
        let path = Paths.home.appendingPathComponent(".cursor/projects/p/agent-transcripts/c/c.jsonl").path
        let json = #"{"hook_event_name":"afterAgentResponse","conversation_id":"c","transcript_path":"\#(path)","text":"done"}"#
        let message = try #require(Hook.message(from: Data(json.utf8), tool: .cursor, event: nil, environment: [:], branch: { _ in nil }, requestID: "r"))
        #expect(message.transcriptPath == path)
        #expect(Hook.Message(userInfo: message.userInfo)?.transcriptPath == path, "it survives the socket")
        let elsewhere = try #require(Hook.message(from: Data(#"{"hook_event_name":"stop","conversation_id":"c","status":"completed","transcript_path":"/etc/passwd"}"#.utf8),
                                                  tool: .cursor, event: nil, environment: [:], branch: { _ in nil }, requestID: "r"))
        #expect(elsewhere.transcriptPath == nil)
    }

    @Test func aSecondPlanInTheSameChatStartsFromItsOwnList() throws {
        // The first plan's name and file are the first plan's: a later CreatePlan with no name must not be matched
        // to the old file, nor have the old file's tasks laid over its list.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-second-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("first_1a2b3c4d.plan.md")
        try "---\nname: first\ntodos:\n  - id: a\n    content: One\n    status: completed\n  - id: b\n    content: Two\n    status: completed\n---\n"
            .write(to: file, atomically: true, encoding: .utf8)

        var follower = CursorPlanFollower()
        func line(_ input: String) -> Data {
            Data(#"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"CreatePlan","input":\#(input)}]}}"#.utf8 + [0x0A])
        }
        _ = follower.feed(line(#"{"name":"first","todos":[{"id":"a","content":"One"},{"id":"b","content":"Two"}]}"#))
        let overlaid = follower.readPlanFile(file)
        #expect(overlaid)
        #expect(follower.planFile == file.path && follower.planName == "first")
        #expect(follower.plan.done == 2)

        _ = follower.feed(line(#"{"todos":[{"id":"a","content":"Something else"},{"id":"z","content":"New"}]}"#))
        #expect(follower.planName == nil, "a plan with no name does not keep the last plan's")
        #expect(follower.planFile == nil, "nor its file")
        #expect(follower.plan.done == 0 && follower.plan.total == 2)
        #expect(follower.items.map(\.id) == ["a", "z"])
        #expect(follower.plansCreated == 2, "the store tells a new plan from the one it knew by this")

        // The row drops the last plan's file and its built mark with it: View Plan and Build are not the old plan's.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let key = SessionTracker.key(tool: .cursor, session: "c1", host: nil)
        var tracker = SessionTracker()
        var build = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor)
        build.planFile = file.path
        build.planBuild = true
        _ = tracker.apply(build, now: t0)
        #expect(tracker.sessions[key]?.planFile == file.path && tracker.sessions[key]?.planBuilt == true)
        let before = try #require(tracker.sessions[key])
        tracker.cursorPlan(key, todos: follower.plan, planFile: nil, replaced: true)
        let after = try #require(tracker.sessions[key])
        #expect(after.planFile == nil, "the new plan's file is not known yet, and the old one's is not it")
        #expect(after.planBuilt == false)
        #expect(after.todos?.total == 2)
        #expect(after.lastEvent == before.lastEvent && after.state == before.state, "a reading of files is no event: the chat's clock and state stay")
    }

    @Test func thePlanFileSpeaksOnlyForTheTasksTheListHas() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("p_1a2b3c4d.plan.md")
        try "---\nname: p\ntodos:\n  - id: a\n    content: One\n    status: completed\n  - id: b\n    content: Two\n    status: completed\n  - id: extra\n    content: Added in the editor\n    status: pending\n---\n"
            .write(to: file, atomically: true, encoding: .utf8)
        func line(_ name: String, _ input: String) -> Data {
            Data(#"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"\#(name)","input":\#(input)}]}}"#.utf8 + [0x0A])
        }
        var follower = CursorPlanFollower()
        _ = follower.feed(line("CreatePlan", #"{"name":"p","todos":[{"id":"a","content":"One"},{"id":"b","content":"Two"}]}"#))
        _ = follower.readPlanFile(file)
        #expect(follower.items.map(\.id) == ["a", "b"], "a task only the file has is not added to a list that has moved on from it")
        #expect(follower.plan.done == 2)

        // Later work in the same chat: a whole new list with none of the plan's tasks. The plan's tasks must not
        // come back from its file on the next read, and the plan is no longer this list's.
        _ = follower.feed(line("TodoWrite", #"{"merge":false,"todos":[{"id":"x","content":"Other","status":"in_progress"},{"id":"y","content":"Work","status":"pending"}]}"#))
        #expect(follower.planFile == nil && follower.planName == nil)
        #expect(follower.plansCreated == 2)
        _ = follower.readPlanFile(file)
        #expect(follower.items.map(\.id) == ["x", "y"], "were the file merged in, the row would read x, y, a, b")

        // A list with nothing in it yet takes the file's.
        var empty = CursorPlanFollower()
        _ = empty.readPlanFile(file)
        #expect(empty.items.map(\.id) == ["a", "b", "extra"])

        // A whole new list that keeps one of the plan's tasks is still the plan's.
        var same = CursorPlanFollower()
        _ = same.feed(line("CreatePlan", #"{"name":"p","todos":[{"id":"a","content":"One"},{"id":"b","content":"Two"}]}"#))
        _ = same.feed(line("TodoWrite", #"{"merge":false,"todos":[{"id":"a","content":"One","status":"in_progress"},{"id":"c","content":"Three","status":"pending"}]}"#))
        #expect(same.planName == "p" && same.plansCreated == 1)
    }

    @Test func aLastRecordWithNoNewlineIsReadAndARewrittenTranscriptStartsOver() throws {
        // Cursor's earlier builds ended a transcript without a newline; the last record was the CreatePlan in one.
        let created = #"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"CreatePlan","input":{"name":"p","todos":[{"id":"a","content":"One"}]}}]}}"#
        var follower = CursorPlanFollower()
        let whole = follower.feed(Data(("{\"role\":\"user\"}\n" + created).utf8))
        #expect(whole, "a whole record at the end needs no newline to be read")
        #expect(follower.planName == "p" && follower.plan.total == 1)
        let again = follower.feed(Data("\n".utf8))
        #expect(!again, "and it is not read a second time when the newline does come")
        #expect(follower.plansCreated == 1)
        var half = CursorPlanFollower()
        let early = half.feed(Data(created.dropLast(20).utf8))
        #expect(!early, "a record still being written is not")
        let finished = half.feed(Data((String(created.suffix(20)) + "\n").utf8))
        #expect(finished)

        // A transcript rewritten shorter is read again from the start, its plan and its count with it.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-shrink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("c.jsonl")
        try Data((String(repeating: "{\"role\":\"user\"}\n", count: 20) + created + "\n").utf8).write(to: url)
        var read = CursorPlanFollower()
        _ = read.read(url)
        #expect(read.plansCreated == 1)
        try Data((created + "\n").utf8).write(to: url)
        _ = read.read(url)
        #expect(read.plansCreated == 1 && read.planName == "p", "the same plan read again is not another plan")
        try Data("{\"role\":\"user\"}\n".utf8).write(to: url)
        _ = read.read(url)
        #expect(read.planName == nil && read.plan.total == 0, "and a rewrite to no plan leaves none")
    }

    @Test func thePlanFileIsReadByItsIndentation() throws {
        let text = [
            "---",
            "name: \"Caf\\u00e9 plan\"",
            "overview: |",
            "  - id: not-a-task",
            "    status: completed",
            "todos:",
            "  - id: a",
            "    content: >",
            "      - id: also-not-a-task",
            "      status: cancelled",
            "    status: completed # done by hand",
            "  - id: b",
            "    content: Second",
            "    status: in_progress",
            "status: cancelled",
            "isProject: false",
            "---",
        ].joined(separator: "\r\n")
        let call = try #require(CursorPlanFiles.call(parsing: text), "a file with Windows line endings is read")
        #expect(call.name == "Café plan", "a double-quoted scalar's escapes are read")
        #expect(call.todos.map(\.id) == ["a", "b"], "a `- ` inside a block scalar is its text, not a task")
        #expect(call.todos.map(\.status) == [.completed, .inProgress], "a comment after a status is no part of it, and a top-level key after the list is not the last task's")
        #expect(call.todos[0].content == nil, "a block scalar's words are on the lines below, which are not read")

        // Items written flush with `todos:` are the same list.
        let flush = "---\nname: p\ntodos:\n- id: a\n  status: pending\n- id: b\n  status: completed\n---\n"
        #expect(try #require(CursorPlanFiles.call(parsing: flush)).todos.map(\.status) == [.pending, .completed])
    }

    @Test func twoPlansOfOneNameAreToldApartByWhenTheyWereWritten() throws {
        // Seen live on 2026-10-03: "three echoes" made twice, in two chats, with the same task ids. The new chat's
        // row took the old plan's file, read 3/3 done and offered no Build.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-twins-\(UUID().uuidString)").resolvingSymlinksInPath()
        let plans = home.appendingPathComponent(".cursor/plans")
        try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let began = Date(timeIntervalSince1970: 1_800_000_000)
        func write(_ file: String, status: String, modified: Date) throws -> URL {
            let url = plans.appendingPathComponent(file)
            try "---\nname: three echoes\ntodos:\n  - id: echo-one\n    content: one\n    status: \(status)\n  - id: echo-two\n    content: two\n    status: \(status)\n---\n"
                .write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url.resolvingSymlinksInPath()
        }
        let old = try write("three_echoes_fb726162.plan.md", status: "completed", modified: began.addingTimeInterval(-3600))
        let new = try write("three_echoes_f5e37547.plan.md", status: "pending", modified: began.addingTimeInterval(20))
        let ids: Set<String> = ["echo-one", "echo-two"]

        #expect(CursorPlanFiles.match(name: "three echoes", ids: ids, since: began, home: home) == new, "the old plan was last written before this chat began")
        #expect(CursorPlanFiles.match(name: "three echoes", ids: ids, since: began.addingTimeInterval(60), home: home) == nil,
                "a chat that began after both were written made neither")

        // Two that match equally well, with nothing to tell them apart, are two chats' plans made side by side: no
        // transcript names its plan's file, so neither is taken, rather than one chat's row showing the other's plan.
        #expect(CursorPlanFiles.match(name: "three echoes", ids: ids, home: home) == nil, "with no date to go by the two are a tie, and a tie is not guessed")
        #expect(CursorPlanFiles.match(name: "three echoes", ids: ids, since: began.addingTimeInterval(-7200), home: home) == nil,
                "nor when both were written during the chat")
        // A plan the transcript named is matched by that name: a file of another name sharing both ids is not it.
        let other = plans.appendingPathComponent("another_9c9c9c9c.plan.md")
        try "---\nname: another\ntodos:\n  - id: echo-one\n    content: one\n    status: pending\n  - id: echo-two\n    content: two\n    status: pending\n---\n"
            .write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: began.addingTimeInterval(30)], ofItemAtPath: other.path)
        #expect(CursorPlanFiles.match(name: "three echoes", ids: ids, since: began, home: home) == new)

        try FileManager.default.removeItem(at: new)
        #expect(CursorPlanFiles.match(name: "three echoes", ids: ids, since: began.addingTimeInterval(40), home: home) == nil, "never the other chat's plan for want of this one's")
        #expect(CursorPlanFiles.match(name: "three echoes", ids: ids, since: began.addingTimeInterval(-7200), home: home) == old, "one match by name is the match")
        #expect(CursorPlanFiles.match(name: "renamed since", ids: ids, since: began.addingTimeInterval(-7200), home: home) == nil,
                "two plans that share `tests` and `verify` are not one when the transcript names its plan")
        // With no name to go by (a Build in a chat that did not make the plan), two tasks in common are needed.
        try FileManager.default.removeItem(at: old)
        #expect(CursorPlanFiles.match(name: nil, ids: ids, since: began, home: home) == other.resolvingSymlinksInPath())
        #expect(CursorPlanFiles.match(name: nil, ids: ["echo-one"], since: began, home: home) == nil)
    }

    @Test func aPlanFilesQuotedScalarsAreReadWithoutTheirQuotes() throws {
        // Cursor writes `content: "Run: echo one"`; YAML allows single quotes as well, a quote inside doubled.
        let text = [
            "---",
            "name: 'it''s a plan'",
            "todos:",
            "  - id: 'pick-number'",
            #"    content: "Run: echo \"one\"""#,
            "    status: 'completed'",
            #"  - id: "second""#,
            "    content: 'Say ''hi'''",
            #"    status: "in_progress""#,
            "---",
        ].joined(separator: "\n")
        let call = try #require(CursorPlanFiles.call(parsing: text))
        #expect(call.name == "it's a plan")
        #expect(call.todos.map(\.id) == ["pick-number", "second"])
        #expect(call.todos.map(\.status) == [.completed, .inProgress], "a quoted status is still a status")
        #expect(call.todos.map(\.content) == [#"Run: echo "one""#, "Say 'hi'"])
    }
}

import Foundation

/// Cursor's task list, read from the conversation's own transcript (0.9.13). Cursor's hooks never fire for its to-do
/// tool: with `preToolUse` and `postToolUse` registered unmatched on Cursor 3.23.12 (2026-10-02), both fired for
/// `Shell` and `Read` and for neither of two `TodoWrite` calls made between them. But every hook payload names the
/// conversation's transcript (`transcript_path`), and the transcript records each `TodoWrite` call whole, as an
/// assistant message's `tool_use` with its input: `{merge, todos: [{id, content, status}]}`, status `pending`,
/// `in_progress`, `completed` or `cancelled`. `merge: false` replaces the list; `merge: true` updates the items it
/// names by id, a missing field left as it was, and leaves the rest. A cancelled step stays on the list, crossed out
/// and out of the count (TodoPlan.Status.cancelled). The calls are replayed here in that way, so the
/// row shows the list Cursor holds.
///
/// A transcript is followed, not reread: each read starts where the last one ended and parses only the lines that
/// mention a plan tool, so a long conversation costs a read of what was added since the last hook event. A line still
/// being written is kept until its newline arrives. A call may also come wrapped as `CallDynamicTool` in the
/// `cursor` namespace (`{namespace, toolName, arguments}`); both `TodoWrite` and `CreatePlan` are read. `CreatePlan`
/// seeds the list as pending. Statuses Cursor later writes into `~/.cursor/plans/*.plan.md` overlay that list.
struct CursorPlanFollower: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var id: String
        var content: String?
        var status: TodoPlan.Status
    }

    private(set) var offset: UInt64 = 0
    private var partial = Data()
    private(set) var items: [Item] = []
    /// The name from the latest `CreatePlan`, used to find the plan file Cursor wrote beside it.
    private(set) var planName: String?
    /// The plan file whose statuses last overlayed this list, when one matched.
    private(set) var planFile: String?
    /// How many times the transcript has started a list that is not the last plan's (a `CreatePlan`, or a whole
    /// new list sharing none of its tasks), so the store can tell that the row's plan is no longer the one it knew.
    private(set) var plansCreated = 0

    /// The list as the row draws it; an empty one once every item is gone.
    var plan: TodoPlan { TodoPlan(items: items.map { TodoPlan.Item(id: $0.id, content: $0.content, status: $0.status) }) }

    /// Reads what was added to `url` since the last read; true when the list changed. A file that shrank (rewritten)
    /// is read again from the start.
    mutating func read(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            // Rewritten: everything read from it is read again, the plan's name, file and count included, so a
            // transcript that comes back with the same plan is not taken for one that made another.
            offset = 0
            partial = Data()
            items = []
            planName = nil
            planFile = nil
            plansCreated = 0
        }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return false }
        offset += UInt64(data.count)
        return feed(data)
    }

    /// Takes bytes in transcript order; true when the list changed.
    mutating func feed(_ data: Data) -> Bool {
        var buffer = partial + data
        guard let lastNewline = buffer.lastIndex(of: 0x0A) else {
            partial = buffer
            return false
        }
        partial = buffer[buffer.index(after: lastNewline)...]
        buffer = buffer[..<lastNewline]
        let before = (items, planName, planFile, plansCreated)
        for line in buffer.split(separator: 0x0A) where CursorPlans.mentionsPlanTool(Data(line)) {
            for call in CursorPlans.calls(in: Data(line)) { apply(call) }
        }
        takeWholeTail()
        return (items, planName, planFile, plansCreated) != before
    }

    /// Cursor's earlier builds ended a transcript on a record with no newline after it (five of eleven from April
    /// 2026 on one Mac, one of them the `CreatePlan` itself). A tail that is a whole JSON object is such a record,
    /// not a line still being written, which cannot parse; it is read now and not again.
    private mutating func takeWholeTail() {
        guard !partial.isEmpty, CursorPlans.mentionsPlanTool(Data(partial)),
              (try? JSONSerialization.jsonObject(with: Data(partial))) != nil else { return }
        for call in CursorPlans.calls(in: Data(partial)) { apply(call) }
        partial = Data()
    }

    /// Overlays the plan file Cursor keeps for this conversation: its status and words for each task the list
    /// already has. A task only the file has is not added, since the list may have moved on (a later `TodoWrite`
    /// that replaced it would otherwise get the plan's tasks appended on every read); a list with nothing in it
    /// yet takes the file's. True when the list changed.
    mutating func readPlanFile(_ url: URL) -> Bool {
        guard let call = CursorPlanFiles.call(in: url) else { return false }
        let before = (items, planFile)
        if items.isEmpty {
            apply(call)
        } else {
            for todo in call.todos {
                guard let id = todo.id, let index = items.firstIndex(where: { $0.id == id }) else { continue }
                if let content = todo.content { items[index].content = content }
                if let status = todo.status { items[index].status = status.plan }
            }
        }
        planFile = url.path
        return (items, planFile) != before
    }

    private mutating func apply(_ call: CursorPlans.Call) {
        if call.created {
            // Another plan: the last one's name and file are the last one's, and its file must not overlay this list.
            planName = call.name.flatMap { $0.isEmpty ? nil : $0 }
            planFile = nil
            plansCreated += 1
            items = call.todos.compactMap { todo in
                guard let id = todo.id else { return nil }
                return Item(id: id, content: todo.content, status: todo.status?.plan ?? .pending)
            }
        } else if !call.merge {
            let replacement = call.todos.compactMap { todo -> Item? in
                guard let id = todo.id, let status = todo.status else { return nil }
                return Item(id: id, content: todo.content, status: status.plan)
            }
            // A whole new list with none of the plan's tasks in it is other work: the plan's name and file are no
            // longer this list's, and the row's View Plan and Build go with them.
            let known = Set(items.map(\.id))
            if planName != nil || planFile != nil, !known.isEmpty, !replacement.contains(where: { known.contains($0.id) }) {
                planName = nil
                planFile = nil
                plansCreated += 1
            }
            items = replacement
        } else {
            for todo in call.todos {
                guard let id = todo.id else { continue }
                if let index = items.firstIndex(where: { $0.id == id }) {
                    if let content = todo.content { items[index].content = content }
                    if let status = todo.status { items[index].status = status.plan }
                } else if let status = todo.status {
                    items.append(Item(id: id, content: todo.content, status: status.plan))
                }
            }
        }
        if items.count > Hook.todoLimit { items = Array(items.prefix(Hook.todoLimit)) }
    }
}

enum CursorPlans {
    /// The tool's name as the transcript records it.
    static let toolName = "TodoWrite"
    static let marker = Data(toolName.utf8)

    enum Status: String, Sendable {
        case pending, inProgress = "in_progress", completed, cancelled

        var plan: TodoPlan.Status {
            switch self {
            case .pending: .pending
            case .inProgress: .inProgress
            case .completed: .completed
            case .cancelled: .cancelled
            }
        }
    }

    struct Todo: Sendable {
        var id: String?
        var content: String?
        var status: Status?
    }

    struct Call: Sendable {
        var merge: Bool
        /// `CreatePlan` seeds a list. Its todos have ids and content, and no status until Cursor writes the plan file.
        var created = false
        var name: String?
        var todos: [Todo]
    }

    static let createName = "CreatePlan"

    /// True when a transcript line can carry a plan call. Checked before JSON parsing so ordinary lines stay cheap.
    static func mentionsPlanTool(_ line: Data) -> Bool {
        line.range(of: marker) != nil || line.range(of: Data(createName.utf8)) != nil
    }

    /// The plan calls one transcript line holds, in order. `TodoWrite` carries `{merge, todos}`. `CreatePlan`
    /// carries `{name, todos}` and is a new list. A `CallDynamicTool` wrapper counts only in the `cursor` namespace.
    static func calls(in line: Data) -> [Call] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { item in
            guard item["type"] as? String == "tool_use" else { return nil }
            var input = item["input"] as? [String: Any]
            var name = item["name"] as? String
            if name == "CallDynamicTool" {
                guard input?["namespace"] as? String == "cursor" else { return nil }
                name = input?["toolName"] as? String
                let arguments = input?["arguments"]
                input = (arguments as? [String: Any])
                    ?? (arguments as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            }
            guard let input, let todos = input["todos"] as? [[String: Any]] else { return nil }
            let parsed = todos.map { todo in
                Todo(id: (todo["id"] as? String).flatMap { $0.isEmpty || $0.count > Hook.taskIDLimit ? nil : $0 },
                     content: Hook.title(fromPrompt: todo["content"]),
                     status: (todo["status"] as? String).flatMap(Status.init(rawValue:)))
            }
            if name == createName {
                return Call(merge: false, created: true, name: input["name"] as? String, todos: parsed)
            }
            guard name == toolName else { return nil }
            return Call(merge: input["merge"] as? Bool ?? false, todos: parsed)
        }
    }

    /// The transcript a payload names, only when it is one of Cursor's own: a `.jsonl` under
    /// `~/.cursor/projects/<project>/agent-transcripts/`, with no `..` in it and checked after every symbolic link on
    /// the way is followed, so a payload, or a link left in that folder, can never point the app at any other file.
    static func transcript(_ path: String?, home: URL = Paths.home) -> URL? {
        guard let path, path.hasSuffix(".jsonl"), !path.contains("/../"), !path.hasSuffix("/..") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let root = home.appendingPathComponent(".cursor/projects").standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(root), url.path.contains("/agent-transcripts/") else { return nil }
        return url
    }
}

/// Cursor's plan file, `~/.cursor/plans/<slug>_<id>.plan.md`. The transcript's `CreatePlan` has no statuses. This
/// file does, in YAML frontmatter, and it is the list the plan UI draws. Only that frontmatter is read, and only
/// a file that stays inside `~/.cursor/plans` after every symlink is followed.
enum CursorPlanFiles {
    static func directory(home: URL = Paths.home) -> URL {
        home.appendingPathComponent(".cursor/plans")
    }

    /// The plan file a payload or a directory listing names, or nil when it is not one of Cursor's own.
    static func allowed(_ path: String, home: URL = Paths.home) -> URL? {
        guard path.hasSuffix(".plan.md"), !path.contains("/../"), !path.hasSuffix("/..") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let root = directory(home: home).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(root) else { return nil }
        return url
    }

    /// The plan file whose tasks are this conversation's. A shared name is not enough: at least one task id must
    /// match as well, and two ids match when the name does not. Two chats can make a plan of the same name with
    /// the same task ids (seen 2026-10-03: "three echoes" twice, and the new chat's row took the old plan's file
    /// and read 3/3 done), so a file last written before the conversation began (`since`, its transcript's
    /// creation) is another conversation's. Two files that match equally well after that are two chats' plans
    /// made side by side, and nothing in a transcript says which is whose (it never names its plan's file), so
    /// neither is taken: the row keeps the list its transcript gives it and offers no View Plan or Build, which is
    /// better than another chat's statuses and another chat's plan behind the buttons.
    static func match(name: String?, ids: Set<String>, since: Date? = nil, home: URL = Paths.home) -> URL? {
        guard !ids.isEmpty || name != nil else { return nil }
        let folder = directory(home: home)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var best: (url: URL, score: Int)?
        var tied = false
        for file in files where file.lastPathComponent.hasSuffix(".plan.md") {
            guard let url = allowed(file.path, home: home) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let since, modified < since { continue }
            guard let call = call(in: url) else { continue }
            let fileIDs = Set(call.todos.compactMap(\.id))
            let overlap = fileIDs.intersection(ids).count
            let nameMatch = name != nil && call.name == name
            // A plan the transcript named is matched by that name and a task; only a list with no name to go by
            // (a Build in a chat that did not make the plan) is matched on two tasks alone, so two plans that
            // happen to share `tests` and `verify` are not one.
            guard name == nil ? overlap >= 2 : (nameMatch && overlap >= 1) else { continue }
            let score = overlap + (nameMatch ? 100 : 0)
            if let current = best, score <= current.score {
                if score == current.score { tied = true }
                continue
            }
            best = (url, score)
            tied = false
        }
        return tied ? nil : best?.url
    }

    /// The frontmatter as a merge onto the transcript's list: statuses and any content the file now carries.
    static func call(in url: URL) -> CursorPlans.Call? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return call(parsing: text)
    }

    /// Reads the frontmatter's `name` and its `todos`, each task's `id`, `content` and `status`, by the shape
    /// Cursor writes: `todos:` at the top level, a `- ` item per task, its fields two columns in. Indentation
    /// decides what a line is, so a `- ` inside a block scalar, a field's wrapped continuation or a top-level key
    /// after the list (`isProject:`) is never taken for a task or one of its fields.
    static func call(parsing text: String) -> CursorPlans.Call? {
        // By any line ending: "\r\n" is one Character in Swift, so a split on "\n" alone leaves a Windows file one line.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              close > open else { return nil }
        var name: String?
        var todos: [CursorPlans.Todo] = []
        var id: String?
        var content: String?
        var status: String?
        var inTodos = false
        var inTodo = false
        var itemIndent: Int?
        func take() {
            defer { id = nil; content = nil; status = nil; inTodo = false }
            guard inTodo, let id, !id.isEmpty, id.count <= Hook.taskIDLimit else { return }
            todos.append(CursorPlans.Todo(id: id, content: Hook.title(fromPrompt: content),
                                           status: status.flatMap(CursorPlans.Status.init(rawValue:))))
        }
        func set(_ line: String) {
            if let value = field("id", in: line) { id = value }
            else if let value = field("content", in: line) { content = value }
            else if let value = field("status", in: line) { status = value }
        }
        for raw in lines[(open + 1)..<close] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            if indent == 0, !line.hasPrefix("- ") {
                // A top-level key: the list of tasks runs from `todos:` to the next one.
                take()
                inTodos = line.hasPrefix("todos:")
                itemIndent = nil
                if let value = field("name", in: line) { name = value }
                continue
            }
            guard inTodos else { continue }
            if line.hasPrefix("- "), itemIndent == nil || indent == itemIndent {
                take()
                itemIndent = indent
                inTodo = true
                set(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if inTodo, let itemIndent, indent == itemIndent + 2 {
                set(line)
            }
        }
        take()
        guard !todos.isEmpty else { return nil }
        return CursorPlans.Call(merge: true, name: name, todos: todos)
    }

    /// One `key: value` line's value as YAML means it: a double-quoted scalar with its escapes read (Cursor writes
    /// `content: "Run: echo one"`), a single-quoted one with a doubled quote read as one, a plain one without a
    /// trailing comment. A block scalar (`|`, `>`) has its words on the lines below, which are not read, so it is
    /// no value here.
    private static func field(_ key: String, in line: String) -> String? {
        let prefix = key + ":"
        guard line.hasPrefix(prefix) else { return nil }
        var value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            // A double-quoted YAML scalar's escapes are JSON's for everything Cursor writes (\", \\, \n, \uXXXX).
            if let decoded = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) as? String {
                value = decoded
            } else {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
        } else if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        } else {
            if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
            if value.hasPrefix("|") || value.hasPrefix(">") { return nil }
        }
        return value.isEmpty ? nil : value
    }
}

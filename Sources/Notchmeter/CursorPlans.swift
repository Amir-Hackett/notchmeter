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
    /// How many plans the transcript has made so far, so the store can tell a new plan from the one it knew.
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
            offset = 0
            partial = Data()
            items = []
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
        return (items, planName, planFile, plansCreated) != before
    }

    /// Overlays statuses from the plan file Cursor keeps for this conversation. True when the list changed.
    mutating func readPlanFile(_ url: URL) -> Bool {
        guard let call = CursorPlanFiles.call(in: url) else { return false }
        let before = (items, planFile)
        apply(call)
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
            items = call.todos.compactMap { todo in
                guard let id = todo.id, let status = todo.status else { return nil }
                return Item(id: id, content: todo.content, status: status.plan)
            }
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
            guard (nameMatch && overlap >= 1) || overlap >= 2 else { continue }
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

    static func call(parsing text: String) -> CursorPlans.Call? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              close > open else { return nil }
        var name: String?
        var todos: [CursorPlans.Todo] = []
        var id: String?
        var content: String?
        var status: String?
        var inTodo = false
        func take() {
            defer { id = nil; content = nil; status = nil; inTodo = false }
            guard let id, !id.isEmpty, id.count <= Hook.taskIDLimit else { return }
            todos.append(CursorPlans.Todo(id: id, content: Hook.title(fromPrompt: content),
                                           status: status.flatMap(CursorPlans.Status.init(rawValue:))))
        }
        for raw in lines[(open + 1)..<close] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") {
                take()
                inTodo = true
                id = field("id", in: String(line.dropFirst(2)))
                continue
            }
            if inTodo {
                if let value = field("id", in: line) { id = value }
                else if let value = field("content", in: line) { content = value }
                else if let value = field("status", in: line) { status = value }
                continue
            }
            if let value = field("name", in: line) { name = value }
        }
        take()
        guard !todos.isEmpty else { return nil }
        return CursorPlans.Call(merge: true, name: name, todos: todos)
    }

    private static func field(_ key: String, in line: String) -> String? {
        let prefix = key + ":"
        guard line.hasPrefix(prefix) else { return nil }
        var value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        // YAML's two quoted scalars: Cursor writes `content: "Run: echo one"`, and a serializer may as well write
        // 'single quotes', where a quote inside is doubled.
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        } else if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value.isEmpty ? nil : value
    }
}

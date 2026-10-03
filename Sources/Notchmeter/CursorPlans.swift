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
/// mention the tool, so a long conversation costs a read of what was added since the last hook event. A line still
/// being written is kept until its newline arrives. A call may also come wrapped as `CallDynamicTool`, Cursor's way of
/// reaching a tool outside its built-in set (`{namespace, toolName, arguments}`); both are read.
struct CursorPlanFollower: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var id: String
        var content: String?
        var status: TodoPlan.Status
    }

    private(set) var offset: UInt64 = 0
    private var partial = Data()
    private(set) var items: [Item] = []

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
        let before = items
        for line in buffer.split(separator: 0x0A) where line.range(of: CursorPlans.marker) != nil {
            for call in CursorPlans.calls(in: Data(line)) { apply(call) }
        }
        return items != before
    }

    private mutating func apply(_ call: CursorPlans.Call) {
        if !call.merge {
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
        var todos: [Todo]
    }

    /// The `TodoWrite` calls one transcript line holds, in order: each `tool_use` content item named `TodoWrite`, or
    /// `CallDynamicTool` naming it, whose input carries a `todos` array. A call with no `merge` replaces the list,
    /// which is what a list written whole means.
    static func calls(in line: Data) -> [Call] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { item in
            guard item["type"] as? String == "tool_use" else { return nil }
            var input = item["input"] as? [String: Any]
            if item["name"] as? String == "CallDynamicTool" {
                guard input?["toolName"] as? String == toolName else { return nil }
                let arguments = input?["arguments"]
                input = (arguments as? [String: Any])
                    ?? (arguments as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            } else if item["name"] as? String != toolName {
                return nil
            }
            guard let input, let todos = input["todos"] as? [[String: Any]] else { return nil }
            return Call(merge: input["merge"] as? Bool ?? false, todos: todos.map { todo in
                Todo(id: (todo["id"] as? String).flatMap { $0.isEmpty || $0.count > Hook.taskIDLimit ? nil : $0 },
                     content: Hook.title(fromPrompt: todo["content"]),
                     status: (todo["status"] as? String).flatMap(Status.init(rawValue:)))
            })
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

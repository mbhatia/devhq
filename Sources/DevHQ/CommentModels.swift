import Foundation

enum CommentThreadState: String, Codable, Equatable {
    case draft
    case open
    case resolved
}

enum CommentMessageState: String, Codable, Equatable {
    case draft
    case open
    case resolved
}

enum CommentAuthor: String, Codable, Equatable {
    case user
    case agent

    var label: String {
        self == .agent ? "agent" : "you"
    }
}

struct CommentPosition: Codable, Equatable, Hashable {
    var line: Int
    var col: Int
}

struct CommentRange: Codable, Equatable, Hashable {
    var start: CommentPosition
    var end: CommentPosition
}

struct CommentMessage: Equatable {
    var author: CommentAuthor
    var body: String
    var state: CommentMessageState?
    var createdAt: String?
    var updatedAt: String?
    var id: String?
    var agentID: String?

    init(
        author: CommentAuthor,
        body: String,
        state: CommentMessageState?,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        id: String? = nil,
        agentID: String? = nil
    ) {
        self.author = author
        self.body = body
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.id = id
        self.agentID = agentID
    }
}

extension CommentMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case author
        case body
        case state
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case id
        case agentID = "agent_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let author = try container.decodeIfPresent(String.self, forKey: .author)
        self.author = author == CommentAuthor.agent.rawValue ? .agent : .user
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state)
            .flatMap(CommentMessageState.init(rawValue:))
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(author, forKey: .author)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(agentID, forKey: .agentID)
    }
}

/// One review comment thread anchored to a file range. The serialized form is
/// byte-compatible with DevHQ v1's `comments.lua` JSONL records so the reply
/// CLI and v1 interoperate on the same files.
struct CommentThread: Equatable, Identifiable {
    var id: String
    var worktree: String
    var file: String
    var commit: String
    var state: CommentThreadState
    var range: CommentRange
    var messages: [CommentMessage]
    var createdAt: String?
    var updatedAt: String?
}

extension CommentThread: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case worktree
        case file
        case commit
        case state
        case range
        case messages
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case body
        case replies
    }

    private struct LegacyReply: Decodable {
        let author: String?
        let body: String?
        let state: String?
        let createdAt: String?
        let updatedAt: String?

        private enum CodingKeys: String, CodingKey {
            case author
            case body
            case state
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        worktree = try container.decodeIfPresent(String.self, forKey: .worktree) ?? ""
        file = try container.decodeIfPresent(String.self, forKey: .file) ?? ""
        commit = try container.decodeIfPresent(String.self, forKey: .commit) ?? "uncommitted"
        state = try container.decodeIfPresent(String.self, forKey: .state)
            .flatMap(CommentThreadState.init(rawValue:)) ?? .draft
        range = try container.decodeIfPresent(CommentRange.self, forKey: .range)
            ?? CommentRange(
                start: CommentPosition(line: 1, col: 1),
                end: CommentPosition(line: 1, col: 1)
            )
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)

        if let messages = try container.decodeIfPresent([CommentMessage].self, forKey: .messages) {
            self.messages = messages
        } else {
            // Legacy v1 shape: a top-level `body` plus a `replies` array.
            var migrated: [CommentMessage] = []
            if let body = try container.decodeIfPresent(String.self, forKey: .body), !body.isEmpty {
                migrated.append(
                    CommentMessage(
                        author: .user,
                        body: body,
                        state: state == .draft ? .draft : .open,
                        createdAt: createdAt,
                        updatedAt: updatedAt
                    )
                )
            }
            let replies = (try? container.decodeIfPresent([LegacyReply].self, forKey: .replies))
                .flatMap { $0 } ?? []
            for reply in replies {
                migrated.append(
                    CommentMessage(
                        author: reply.author == CommentAuthor.agent.rawValue ? .agent : .user,
                        body: reply.body ?? "",
                        state: reply.state.flatMap(CommentMessageState.init(rawValue:)) ?? .open,
                        createdAt: reply.createdAt,
                        updatedAt: reply.updatedAt
                    )
                )
            }
            messages = migrated
        }
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(worktree, forKey: .worktree)
        try container.encode(file, forKey: .file)
        try container.encode(commit, forKey: .commit)
        try container.encode(state, forKey: .state)
        try container.encode(range, forKey: .range)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

extension CommentThread {
    /// Mirrors v1 `normalize_thread`: guarantees at least one message and
    /// consistent per-message states.
    mutating func normalize() {
        if messages.isEmpty {
            messages = [
                CommentMessage(
                    author: .user,
                    body: "",
                    state: .draft,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            ]
        }
        for index in messages.indices {
            if messages[index].state == nil {
                messages[index].state = state == .draft ? .draft : .open
            }
            if state == .resolved, messages[index].state == .open {
                messages[index].state = .resolved
            }
        }
    }

    var firstMessage: CommentMessage {
        messages.first ?? CommentMessage(author: .user, body: "", state: .draft)
    }

    var hasDraftMessage: Bool {
        messages.contains { $0.state == .draft && !$0.body.isEmpty }
    }

    /// Promotes every draft message (and the thread) to `open`. Mirrors v1
    /// `mark_messages_open`.
    mutating func markMessagesOpen(now: String) {
        var changed = false
        for index in messages.indices where messages[index].state == .draft {
            messages[index].state = .open
            messages[index].updatedAt = now
            changed = true
        }
        if changed { state = .open }
        updatedAt = now
    }

    /// Resolves the thread and every open message. Mirrors v1 `resolve_thread`.
    mutating func resolve(now: String) {
        state = .resolved
        updatedAt = now
        for index in messages.indices where messages[index].state == .open {
            messages[index].state = .resolved
            messages[index].updatedAt = now
        }
    }

    /// `file:line:col <first 60 chars of the first message>` as used by the
    /// resolve picker. Mirrors v1 `comment_label`.
    var label: String {
        var text = firstMessage.body
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if text.count > 60 {
            text = String(text.prefix(57)) + "..."
        }
        return "\(file):\(range.start.line):\(range.start.col) \(text)"
    }
}

enum CommentClock {
    /// UTC ISO-8601 timestamps without fractional seconds, matching v1's
    /// `os.date("!%Y-%m-%dT%H:%M:%SZ")`.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

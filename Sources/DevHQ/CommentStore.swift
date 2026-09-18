import Foundation

/// Persists review comment threads as JSONL files in the DevHQ workspace
/// state directory (`<config>/ws`). The first line of each file is a meta
/// record naming the worktree; each following line is one thread. The layout
/// and encoding are byte-compatible with DevHQ v1's `comments.lua`.
struct CommentStore {
    private struct Meta: Codable {
        let type: String
        let worktree: String
    }

    let wsDirectory: URL

    private let fileManager: FileManager

    init(
        configDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        let configDirectory = configDirectory
            ?? LuaPluginHost.defaultConfigDirectory(environment: environment)
        self.wsDirectory = configDirectory.appendingPathComponent("ws", isDirectory: true)
        self.fileManager = fileManager
    }

    private static let fileNameMarker = "-devhq-comments-"
    private static let fileNameSuffix = ".jsonl"

    static func fileName(worktreeBasename: String, index: Int) -> String {
        worktreeBasename + fileNameMarker + String(index) + fileNameSuffix
    }

    /// The numeric suffix of a comments file that belongs to a worktree with
    /// the given basename, or nil when the name does not match.
    static func index(ofFileName name: String, worktreeBasename: String) -> Int? {
        let prefix = worktreeBasename + fileNameMarker
        guard name.hasPrefix(prefix), name.hasSuffix(fileNameSuffix) else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(fileNameSuffix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    private static func isCommentsFileName(_ name: String) -> Bool {
        guard name.hasSuffix(fileNameSuffix),
              let markerRange = name.range(of: fileNameMarker, options: .backwards) else {
            return false
        }
        let digits = name[markerRange.upperBound...].dropLast(fileNameSuffix.count)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// Every comments file in the workspace directory, regardless of worktree.
    func allCommentsFileURLs() -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: wsDirectory.path)) ?? []
        return names.filter(Self.isCommentsFileName)
            .sorted()
            .map { wsDirectory.appendingPathComponent($0, isDirectory: false) }
    }

    /// The worktree path recorded in a file's first meta line, if any.
    func metaWorktreePath(of fileURL: URL) -> String? {
        guard let line = firstLine(of: fileURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: Data(line.utf8)),
              meta.type == "meta" else {
            return nil
        }
        return meta.worktree
    }

    /// Finds the comments file whose meta worktree matches, or allocates the
    /// lowest unused index for the worktree's basename. Mirrors v1
    /// `comments_file_for`.
    func commentsFileURL(forWorktreePath path: String) -> URL {
        let basename = (path as NSString).lastPathComponent
        var used = Set<Int>()
        let names = (try? fileManager.contentsOfDirectory(atPath: wsDirectory.path)) ?? []
        for name in names {
            guard let index = Self.index(ofFileName: name, worktreeBasename: basename) else {
                continue
            }
            used.insert(index)
            let candidate = wsDirectory.appendingPathComponent(name, isDirectory: false)
            if metaWorktreePath(of: candidate) == path {
                return candidate
            }
        }

        var index = 1
        while used.contains(index) { index += 1 }
        return wsDirectory.appendingPathComponent(
            Self.fileName(worktreeBasename: basename, index: index),
            isDirectory: false
        )
    }

    /// Loads every thread in a file. Lines that are not valid thread records
    /// are skipped, matching v1's tolerant loader. When `worktreePath` is
    /// given it overrides each thread's stored worktree.
    func loadThreads(from fileURL: URL, worktreePath: String? = nil) -> [CommentThread] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return Self.parseThreads(data, worktreePath: worktreePath)
    }

    static func parseThreads(_ data: Data, worktreePath: String? = nil) -> [CommentThread] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { line -> CommentThread? in
                guard !line.isEmpty,
                      var thread = try? decoder.decode(CommentThread.self, from: Data(line)) else {
                    return nil
                }
                if let worktreePath { thread.worktree = worktreePath }
                return thread
            }
    }

    /// Serializes a meta line plus one line per thread. Keys are sorted and
    /// slashes unescaped to stay byte-compatible with v1's encoder.
    static func serialize(_ threads: [CommentThread], worktreePath: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var contents = try encoder.encode(Meta(type: "meta", worktree: worktreePath))
        contents.append(UInt8(ascii: "\n"))
        for thread in threads {
            contents.append(try encoder.encode(thread))
            contents.append(UInt8(ascii: "\n"))
        }
        return contents
    }

    /// Writes atomically: the contents land in a temporary sibling that then
    /// replaces the destination, matching the v1 CLI's tmp+rename discipline.
    func save(_ threads: [CommentThread], worktreePath: String, to fileURL: URL) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = try Self.serialize(threads, worktreePath: worktreePath)
        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".tmp", isDirectory: false)
        try contents.write(to: temporaryURL)
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    func modificationDate(of fileURL: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    private func firstLine(of fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first else {
            return nil
        }
        return String(decoding: line, as: UTF8.self)
    }
}

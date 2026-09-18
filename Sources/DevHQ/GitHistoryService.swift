import Darwin
import Dispatch
import Foundation

/// One commit in the branch history between the resolved parent merge base
/// and HEAD.
public struct GitHistoryCommit: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let shortHash: String
    public let date: String
    public let author: String
    public let subject: String

    public init(hash: String, shortHash: String, date: String, author: String, subject: String) {
        self.hash = hash
        self.shortHash = shortHash
        self.date = date
        self.author = author
        self.subject = subject
    }

    public var label: String { "\(subject) - \(shortHash) - \(date)" }
}

/// Git-backed branch history provider for the Git History pane.
///
/// Every query runs off the main actor, mirroring `GitQueryService`. The
/// commit list spans `<merge-base>..HEAD`, where the merge base comes from
/// the same parent-branch resolution ladder the file filters use.
public actor GitHistoryService {
    /// Git's well-known empty tree, used as the diff base for a root commit.
    static let emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    public init() {}

    public func branchHistory(in repositoryURL: URL) async throws -> [GitHistoryCommit] {
        try await Task.detached(priority: .userInitiated) {
            let state = try GitQueryService.parentState(in: repositoryURL)
            guard case let .resolved(_, mergeBase) = state else {
                if case let .noParent(message) = state {
                    throw GitQueryError.noParent(message)
                }
                throw GitQueryError.noParent("No parent branch is available for this branch.")
            }
            let data = try GitQueryService.runGit(
                ["log", "--date=short", "--format=%H%x1f%h%x1f%ad%x1f%an%x1f%s", "\(mergeBase)..HEAD"],
                in: repositoryURL
            )
            return Self.parseBranchHistory(data)
        }.value
    }

    /// Lists the files changed by a commit relative to its first parent,
    /// including rename detection and per-file addition/deletion counts.
    public func commitFiles(in repositoryURL: URL, commit: String) async throws -> [GitFileChange] {
        try await Task.detached(priority: .userInitiated) {
            let base = Self.parentReference(of: commit, in: repositoryURL)
            let nameStatus = try GitQueryService.runGit(
                ["diff", "--name-status", "-z", "--find-renames", "--find-copies", base, commit, "--"],
                in: repositoryURL
            )
            let numstat = (try? GitQueryService.runGit(
                ["diff", "--numstat", "-z", "--find-renames", "--find-copies", base, commit, "--"],
                in: repositoryURL
            )) ?? Data()
            return Self.parseCommitFiles(nameStatus: nameStatus, numstat: numstat)
        }.value
    }

    /// The full `git log -1` output for a commit, used as its rich tooltip.
    public func commitLog(in repositoryURL: URL, commit: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let data = try GitQueryService.runGit(
                ["log", "-1", "--no-color", commit],
                in: repositoryURL
            )
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    /// The file content as of a commit. A deleted file falls back to the
    /// commit's first parent under the file's pre-deletion path.
    public func fileContent(
        in repositoryURL: URL,
        commit: String,
        change: GitFileChange
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            do {
                return try GitQueryService.runGit(
                    ["show", "\(commit):\(change.path)"],
                    in: repositoryURL
                )
            } catch {
                guard change.kind == .deleted else {
                    throw GitQueryError.blobNotFound(path: change.path, revision: commit)
                }
                let parent = Self.parentReference(of: commit, in: repositoryURL)
                let fallbackPath = change.oldPath ?? change.path
                do {
                    return try GitQueryService.runGit(
                        ["show", "\(parent):\(fallbackPath)"],
                        in: repositoryURL
                    )
                } catch {
                    throw GitQueryError.blobNotFound(path: fallbackPath, revision: parent)
                }
            }
        }.value
    }

    static func parentReference(of commit: String, in repositoryURL: URL) -> String {
        let hasParent = (try? GitQueryService.runGit(
            ["rev-parse", "--verify", "--quiet", "\(commit)^^{commit}"],
            in: repositoryURL
        )) != nil
        return hasParent ? "\(commit)^" : emptyTreeHash
    }

    static func parseBranchHistory(_ data: Data) -> [GitHistoryCommit] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let fields = line
                    .split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false)
                    .map(String.init)
                guard fields.count == 5, !fields[0].isEmpty else { return nil }
                return GitHistoryCommit(
                    hash: fields[0],
                    shortHash: fields[1],
                    date: fields[2],
                    author: fields[3],
                    subject: fields[4]
                )
            }
    }

    /// Merges `--name-status -z` and `--numstat -z` outputs into an ordered
    /// file list, preserving git's ordering and rename old paths.
    static func parseCommitFiles(nameStatus: Data, numstat: Data) -> [GitFileChange] {
        let counts = parseNumstat(numstat)
        let fields = nulFields(nameStatus)
        var files: [GitFileChange] = []
        var index = 0
        while index < fields.count {
            let status = fields[index]
            index += 1
            guard !status.isEmpty, index < fields.count else { break }
            let code = status.first.map(String.init) ?? ""
            let oldPath: String?
            let path: String
            if code == "R" || code == "C" {
                guard index + 1 < fields.count else { break }
                oldPath = fields[index]
                path = fields[index + 1]
                index += 2
            } else {
                oldPath = nil
                path = fields[index]
                index += 1
            }
            let count = counts[path]
            files.append(GitFileChange(
                path: path,
                oldPath: oldPath ?? count?.oldPath,
                kind: changeKind(for: code),
                additions: count?.additions,
                deletions: count?.deletions,
                isBinary: count?.isBinary ?? false
            ))
        }
        return files
    }

    private struct Count {
        let oldPath: String?
        let additions: Int?
        let deletions: Int?
        let isBinary: Bool
    }

    private static func parseNumstat(_ data: Data) -> [String: Count] {
        let fields = nulFields(data)
        var index = 0
        var result: [String: Count] = [:]
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard !field.isEmpty else { continue }
            let columns = field
                .split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard columns.count == 3 else { continue }
            let isBinary = columns[0] == "-" || columns[1] == "-"
            let additions = isBinary ? nil : Int(columns[0])
            let deletions = isBinary ? nil : Int(columns[1])
            if columns[2].isEmpty, index + 1 < fields.count {
                let oldPath = fields[index]
                let newPath = fields[index + 1]
                index += 2
                result[newPath] = Count(
                    oldPath: oldPath,
                    additions: additions,
                    deletions: deletions,
                    isBinary: isBinary
                )
            } else {
                result[columns[2]] = Count(
                    oldPath: nil,
                    additions: additions,
                    deletions: deletions,
                    isBinary: isBinary
                )
            }
        }
        return result
    }

    private static func changeKind(for code: String) -> GitChangeKind {
        switch code {
        case "A": .added
        case "M": .modified
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .conflicted
        default: .unknown
        }
    }

    private static func nulFields(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    /// The reference files whose changes invalidate the branch history:
    /// the worktree `HEAD`, the shared `packed-refs`, and the current branch
    /// ref together with its parent directory (ref updates are written by
    /// renaming a lock file into place, which only the directory observes).
    static func referenceWatchPaths(in repositoryURL: URL) -> [URL] {
        guard let output = try? GitQueryService.runGit(
            ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
            in: repositoryURL
        ) else { return [] }
        let lines = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard lines.count >= 2 else { return [] }
        let gitDirectory = URL(fileURLWithPath: lines[0], isDirectory: true)
        let commonDirectory = URL(fileURLWithPath: lines[1], isDirectory: true)

        var paths = [
            gitDirectory.appendingPathComponent("HEAD"),
            gitDirectory,
            commonDirectory.appendingPathComponent("packed-refs"),
            commonDirectory,
        ]
        if let head = try? GitQueryService.runGit(
            ["symbolic-ref", "--quiet", "HEAD"],
            in: repositoryURL
        ) {
            let reference = String(decoding: head, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !reference.isEmpty, !reference.contains("..") {
                let referenceURL = commonDirectory.appendingPathComponent(reference)
                paths.append(referenceURL)
                paths.append(referenceURL.deletingLastPathComponent())
            }
        }
        return paths
    }
}

/// Watches a fixed set of Git reference paths for the history pane.
///
/// Follows the `RepositoryWatcher` DispatchSource/debounce pattern, but takes
/// explicit paths because branch refs live outside the directories that
/// watcher observes. Sources are rebuilt after every event since git replaces
/// these files by renaming a lock file into place.
final class GitHistoryRefWatcher {
    private let paths: [URL]
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueValue = UUID()
    private let debounceInterval: DispatchTimeInterval
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pendingChange: DispatchWorkItem?
    private var isCancelled = false

    init(
        paths: [URL],
        debounceInterval: DispatchTimeInterval = .milliseconds(150),
        queue: DispatchQueue = DispatchQueue(label: "devhq.git-history-watcher"),
        onChange: @escaping () -> Void
    ) {
        self.paths = paths.map { $0.standardizedFileURL }
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: queueValue)
        onQueue { installSources() }
    }

    deinit {
        cancel()
    }

    func cancel() {
        onQueue {
            guard !isCancelled else { return }
            pendingChange?.cancel()
            pendingChange = nil
            isCancelled = true
            let oldSources = sources
            sources.removeAll()
            oldSources.forEach { $0.cancel() }
        }
    }

    private func installSources() {
        var replacements: [DispatchSourceFileSystemObject] = []
        for url in paths {
            guard let source = makeSource(for: url) else { continue }
            replacements.append(source)
        }
        let oldSources = sources
        sources = replacements
        oldSources.forEach { $0.cancel() }
        sources.forEach { $0.resume() }
    }

    private func makeSource(for url: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: queue
        )
        source.setCancelHandler {
            close(descriptor)
        }
        source.setEventHandler { [weak self] in
            self?.scheduleChange()
        }
        return source
    }

    /// Serializes an incoming source event. Internal visibility also permits
    /// a deterministic test without depending on filesystem timing.
    func scheduleChange() {
        guard DispatchQueue.getSpecific(key: queueKey) == queueValue else {
            queue.async { [weak self] in self?.scheduleChange() }
            return
        }
        guard !isCancelled else { return }
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isCancelled else { return }
            // A checkout or ref update replaces the watched files.
            self.installSources()
            self.onChange()
        }
        pendingChange = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func onQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            return operation()
        }
        return queue.sync(execute: operation)
    }
}

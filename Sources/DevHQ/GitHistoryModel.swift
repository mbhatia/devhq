import Combine
import Foundation

/// State for the Git History pane, which swaps in for the file explorer tree.
///
/// The commit list spans `<merge-base>..HEAD` for the active worktree.
/// Expanding a commit lazily lists its files; selecting a file opens a
/// read-only snapshot of the file at that commit through the workspace.
@MainActor
final class GitHistoryModel: ObservableObject {
    enum Item {
        case commit(GitHistoryCommit)
        case file(commit: GitHistoryCommit, change: GitFileChange)
        case info(String)
    }

    typealias Node = TreeNode<String, Item>

    let tree = TreeModel<String, Item>(initiallyExpandedLevels: 0)
    @Published private(set) var isActive = false
    @Published private(set) var isLoading = false
    @Published private(set) var selectedNodeID: String?
    /// Full `git log -1` output per commit hash, loaded lazily for tooltips.
    @Published private(set) var commitLogs: [String: String] = [:]

    private let service: GitHistoryService
    private(set) weak var workspace: WorkspaceModel?
    private(set) var repositoryURL: URL?
    private var commits: [GitHistoryCommit]?
    private var statusMessage: String?
    private var filesByCommit: [String: [GitFileChange]] = [:]
    private var fileErrorsByCommit: [String: String] = [:]
    private var pendingFileCommits: Set<String> = []
    private var pendingLogCommits: Set<String> = []
    /// Renewed whenever the repository or cache generation changes so stale
    /// asynchronous results are dropped.
    private var generation = UUID()
    private var historyTask: Task<Void, Never>?
    private var openSnapshotTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var watcher: GitHistoryRefWatcher?
    private var rootURLObservation: AnyCancellable?

    init(service: GitHistoryService = GitHistoryService()) {
        self.service = service
    }

    /// Binds the model to the workspace so the history follows the active
    /// worktree and snapshots open as editor tabs.
    func attach(to workspace: WorkspaceModel) {
        self.workspace = workspace
        repositoryURL = workspace.rootURL
        rootURLObservation = workspace.$rootURL.sink { [weak self] url in
            Task { @MainActor [weak self] in
                self?.repositoryDidChange(url)
            }
        }
    }

    /// Swaps the file explorer between the file tree and the history view.
    func toggle() {
        if isActive {
            isActive = false
            stopWatching()
            historyTask?.cancel()
            openSnapshotTask?.cancel()
            isLoading = false
        } else {
            isActive = true
            resetCaches()
            reload()
            startWatching()
        }
    }

    func toggleNode(_ node: Node) {
        guard case .commit(let commit) = node.value else { return }
        tree.toggle(node)
        if tree.isExpanded(node) {
            loadFiles(for: commit)
        }
    }

    func select(_ node: Node, persistently: Bool) {
        guard case let .file(commit, change) = node.value else { return }
        selectedNodeID = node.id
        open(change, in: commit, asPreview: !persistently)
    }

    func commitTooltip(for commit: GitHistoryCommit) -> String {
        commitLogs[commit.hash] ?? "\(commit.hash)\n\(commit.author)"
    }

    func fileTooltip(for change: GitFileChange) -> String {
        if let oldPath = change.oldPath, oldPath != change.path {
            return "\(oldPath) -> \(change.path)"
        }
        return change.path
    }

    /// Asynchronously upgrades a commit's tooltip to its full log message.
    func requestCommitLog(for commit: GitHistoryCommit) {
        guard let repositoryURL,
              commitLogs[commit.hash] == nil,
              pendingLogCommits.insert(commit.hash).inserted else { return }
        let generation = generation
        let service = service
        Task { [weak self] in
            let text: String
            do {
                text = try await service.commitLog(in: repositoryURL, commit: commit.hash)
            } catch {
                text = "\(commit.hash)\n\(commit.author)"
            }
            guard let self, self.generation == generation else { return }
            self.pendingLogCommits.remove(commit.hash)
            self.commitLogs[commit.hash] = text
        }
    }

    private func repositoryDidChange(_ url: URL?) {
        guard repositoryURL != url else { return }
        repositoryURL = url
        resetCaches()
        commits = nil
        statusMessage = nil
        guard isActive else { return }
        reload()
        startWatching()
    }

    /// Reloads after an external ref change, clearing caches so commit file
    /// lists and logs reflect the new state.
    private func referencesDidChange() {
        guard isActive else { return }
        resetCaches()
        reload()
        // The current branch may have changed, so watch its new ref.
        startWatching()
    }

    private func resetCaches() {
        generation = UUID()
        historyTask?.cancel()
        openSnapshotTask?.cancel()
        filesByCommit = [:]
        fileErrorsByCommit = [:]
        pendingFileCommits = []
        pendingLogCommits = []
        commitLogs = [:]
        selectedNodeID = nil
    }

    private func reload() {
        guard let repositoryURL else {
            commits = nil
            statusMessage = "No git history"
            isLoading = false
            rebuildTree()
            return
        }
        let generation = generation
        let service = service
        isLoading = true
        rebuildTree()
        historyTask = Task { [weak self] in
            do {
                let commits = try await service.branchHistory(in: repositoryURL)
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.commits = commits
                self.statusMessage = nil
                self.isLoading = false
                self.rebuildTree()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.commits = nil
                self.statusMessage = error.localizedDescription
                self.isLoading = false
                self.rebuildTree()
            }
        }
    }

    private func loadFiles(for commit: GitHistoryCommit) {
        guard let repositoryURL,
              filesByCommit[commit.hash] == nil,
              pendingFileCommits.insert(commit.hash).inserted else { return }
        let generation = generation
        let service = service
        Task { [weak self] in
            var files: [GitFileChange] = []
            var failure: String?
            do {
                files = try await service.commitFiles(in: repositoryURL, commit: commit.hash)
            } catch {
                failure = error.localizedDescription
            }
            guard let self, self.generation == generation else { return }
            self.pendingFileCommits.remove(commit.hash)
            self.filesByCommit[commit.hash] = files
            self.fileErrorsByCommit[commit.hash] = failure
            self.rebuildTree()
        }
    }

    private func open(_ change: GitFileChange, in commit: GitHistoryCommit, asPreview: Bool) {
        guard let workspace, let repositoryURL else { return }
        openSnapshotTask?.cancel()
        let generation = generation
        let service = service
        openSnapshotTask = Task { [weak self] in
            do {
                let data = try await service.fileContent(
                    in: repositoryURL,
                    commit: commit.hash,
                    change: change
                )
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                guard let text = String(data: data, encoding: .utf8) else {
                    workspace.errorMessage = "Cannot preview binary snapshot \(change.path)."
                    return
                }
                workspace.openGitHistorySnapshot(
                    repositoryURL: repositoryURL,
                    commit: commit,
                    change: change,
                    text: text,
                    asPreview: asPreview
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                workspace.errorMessage =
                    "Could not open \(change.path) at \(commit.shortHash): \(error.localizedDescription)"
            }
        }
    }

    private func startWatching() {
        stopWatching()
        guard let repositoryURL else { return }
        let generation = generation
        watcherTask = Task.detached(priority: .utility) { [weak self] in
            let paths = GitHistoryService.referenceWatchPaths(in: repositoryURL)
            await MainActor.run { [weak self] in
                guard let self, self.isActive, self.generation == generation else { return }
                self.watcher = GitHistoryRefWatcher(paths: paths) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.referencesDidChange()
                    }
                }
            }
        }
    }

    private func stopWatching() {
        watcherTask?.cancel()
        watcherTask = nil
        watcher?.cancel()
        watcher = nil
    }

    private func rebuildTree() {
        let expanded = tree.expandedIDs
        let roots: [Node]
        if let commits {
            if commits.isEmpty {
                roots = [Node(id: "info:empty", value: .info("No git history"), children: nil)]
            } else {
                roots = commits.map { commit in
                    Node(
                        id: commit.hash,
                        value: .commit(commit),
                        children: fileNodes(for: commit)
                    )
                }
            }
        } else if let statusMessage {
            roots = [Node(id: "info:status", value: .info(statusMessage), children: nil)]
        } else {
            roots = []
        }
        tree.replaceRoots(roots, initiallyExpandedLevels: 0)
        tree.restoreExpandedIDs(expanded)
    }

    private func fileNodes(for commit: GitHistoryCommit) -> [Node] {
        guard let files = filesByCommit[commit.hash] else {
            return [Node(id: "loading:\(commit.hash)", value: .info("Loading…"), children: nil)]
        }
        if let failure = fileErrorsByCommit[commit.hash] {
            return [Node(id: "error:\(commit.hash)", value: .info(failure), children: nil)]
        }
        guard !files.isEmpty else {
            return [Node(id: "empty:\(commit.hash)", value: .info("No files changed"), children: nil)]
        }
        return files.map { change in
            Node(
                id: "\(commit.hash):\(change.path)",
                value: .file(commit: commit, change: change),
                children: nil
            )
        }
    }
}

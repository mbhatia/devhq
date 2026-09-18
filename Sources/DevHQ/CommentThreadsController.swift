import AppKit
import Combine
import Foundation

struct ReviewCommentError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

/// Synchronous Git helpers for comment anchoring and snapshots. Every call is
/// a short single-file query, matching v1's `git.commit_for_file` usage.
enum CommentGit {
    /// "uncommitted" when the file has local changes (or no HEAD exists),
    /// otherwise the current HEAD SHA.
    static func commitForFile(worktreePath: String, relativePath: String) -> String {
        if let status = run(["status", "--porcelain", "--", relativePath], in: worktreePath),
           !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "uncommitted"
        }
        return headCommit(worktreePath: worktreePath) ?? "uncommitted"
    }

    static func headCommit(worktreePath: String) -> String? {
        guard let output = run(["rev-parse", "HEAD"], in: worktreePath) else { return nil }
        let commit = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }

    static func fileContent(atCommit commit: String, relativePath: String, worktreePath: String) -> String? {
        run(["show", "\(commit):\(relativePath)"], in: worktreePath)
    }

    private static func run(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Owns the review comment threads for the active worktree: lazy per-worktree
/// loading, persistence through `CommentStore`, overlay bookkeeping, and the
/// external-change watcher.
@MainActor
final class CommentThreadsController: ObservableObject {
    /// The controller wired into the running app, reachable from editor views
    /// without threading it through every intermediate initializer.
    private(set) static weak var active: CommentThreadsController?

    @Published private(set) var threads: [CommentThread] = []
    @Published var isSidebarVisible = false

    let workspace: WorkspaceModel
    private(set) weak var agentManager: AgentManager?
    private let store: CommentStore
    private(set) var loadedWorktreePath: String?
    private(set) var stateFileURL: URL?
    private var loadedModificationDate: Date?
    private var watchTimer: Timer?
    private var rootObservation: AnyCancellable?
    private var coordinatorsByDocument: [UUID: WeakCommentCoordinator] = [:]
    private(set) var openOverlayCount = 0
    private var pendingCaret: (documentID: UUID, line: Int, col: Int)?

    init(
        workspace: WorkspaceModel,
        agentManager: AgentManager? = nil,
        store: CommentStore = CommentStore()
    ) {
        self.workspace = workspace
        self.agentManager = agentManager
        self.store = store
        rootObservation = workspace.$rootURL
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.ensureLoaded() }
    }

    deinit {
        watchTimer?.invalidate()
    }

    func makeActive() {
        Self.active = self
    }

    // MARK: - Loading and persistence

    func ensureLoaded() {
        guard let path = workspace.rootURL?.path else {
            loadedWorktreePath = nil
            stateFileURL = nil
            loadedModificationDate = nil
            if !threads.isEmpty { threads = [] }
            return
        }
        if path != loadedWorktreePath {
            load(worktreePath: path)
        }
    }

    private func load(worktreePath: String) {
        loadedWorktreePath = worktreePath
        let fileURL = store.commentsFileURL(forWorktreePath: worktreePath)
        stateFileURL = fileURL
        loadedModificationDate = store.modificationDate(of: fileURL)
        threads = store.loadThreads(from: fileURL, worktreePath: worktreePath)
        refreshCoordinators()
    }

    private func save() {
        guard let worktreePath = loadedWorktreePath else { return }
        let fileURL = stateFileURL ?? store.commentsFileURL(forWorktreePath: worktreePath)
        stateFileURL = fileURL
        do {
            try store.save(threads, worktreePath: worktreePath, to: fileURL)
            loadedModificationDate = store.modificationDate(of: fileURL)
        } catch {
            workspace.errorMessage =
                "Could not save review comments: \(error.localizedDescription)"
        }
        refreshCoordinators()
    }

    // MARK: - External-change watcher

    func startWatching(interval: TimeInterval = 1.0) {
        guard watchTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForExternalChanges()
            }
        }
        timer.tolerance = interval / 4
        watchTimer = timer
    }

    /// Reloads the JSONL when its on-disk state changed, unless an overlay is
    /// open. Mirrors v1's poll thread.
    func checkForExternalChanges() {
        ensureLoaded()
        guard openOverlayCount == 0,
              let worktreePath = loadedWorktreePath,
              let fileURL = stateFileURL else { return }
        let modificationDate = store.modificationDate(of: fileURL)
        if modificationDate != loadedModificationDate {
            load(worktreePath: worktreePath)
        }
    }

    // MARK: - Queries

    func thread(id: String) -> CommentThread? {
        threads.first { $0.id == id }
    }

    /// Threads for the sidebar: every thread in the active worktree, sorted by
    /// file then start line.
    var sortedThreads: [CommentThread] {
        threads.sorted {
            if $0.file != $1.file { return $0.file < $1.file }
            return $0.range.start.line < $1.range.start.line
        }
    }

    /// Threads anchored in the given document, used for gutter markers.
    /// Documents outside the active worktree have none.
    func threads(forDocumentURL url: URL) -> [CommentThread] {
        ensureLoaded()
        guard let root = workspace.rootURL,
              let relativePath = Self.relativePath(for: url, in: root) else {
            return []
        }
        return threads.filter { $0.file == relativePath }
    }

    func postableThreads() -> [CommentThread] {
        ensureLoaded()
        return threads.filter(\.hasDraftMessage)
    }

    func openThreads() -> [CommentThread] {
        ensureLoaded()
        return threads.filter { $0.state == .open }
    }

    // MARK: - Creation

    /// Creates a draft thread on the current selection of the active editor
    /// document, shows the review sidebar, and opens the inline overlay.
    func addComment() throws {
        ensureLoaded()
        guard let document = workspace.selectedDocument else {
            throw ReviewCommentError("No active document")
        }
        guard let root = workspace.rootURL,
              !document.isReadOnly,
              let relativePath = Self.relativePath(for: document.url, in: root) else {
            throw ReviewCommentError("Document is not inside the current worktree")
        }
        guard let range = coordinatorsByDocument[document.id]?.value?.selectedRange(),
              range.start != range.end else {
            throw ReviewCommentError("Select text before adding a comment")
        }

        let thread = addThread(relativePath: relativePath, range: range)
        coordinatorsByDocument[document.id]?.value?.openOverlay(threadID: thread.id, created: true)
    }

    /// Appends and persists a new draft thread. Split from `addComment()` so
    /// the storage semantics stay testable without an editor.
    @discardableResult
    func addThread(relativePath: String, range: CommentRange, date: Date = Date()) -> CommentThread {
        ensureLoaded()
        let worktreePath = loadedWorktreePath ?? workspace.rootURL?.path ?? ""
        let now = CommentClock.timestamp(date)
        let thread = CommentThread(
            id: "\(Int(date.timeIntervalSince1970)):\(relativePath):\(range.start.line):\(range.start.col)",
            worktree: worktreePath,
            file: relativePath,
            commit: CommentGit.commitForFile(
                worktreePath: worktreePath,
                relativePath: relativePath
            ),
            state: .draft,
            range: range,
            messages: [
                CommentMessage(
                    author: .user,
                    body: "",
                    state: .draft,
                    createdAt: now,
                    updatedAt: now
                )
            ],
            createdAt: now,
            updatedAt: now
        )
        threads.append(thread)
        save()
        isSidebarVisible = true
        return thread
    }

    func removeThread(id: String) {
        guard threads.contains(where: { $0.id == id }) else { return }
        threads.removeAll { $0.id == id }
        save()
    }

    // MARK: - Overlay actions

    /// Save semantics: a draft thread's input replaces the first message body
    /// and the thread stays draft; on an existing thread a non-empty input
    /// appends a draft user message, reopening a resolved thread.
    func commitOverlay(threadID: String, input: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        let now = CommentClock.timestamp()
        if threads[index].state == .draft {
            threads[index].messages[0].body = input
            threads[index].messages[0].updatedAt = now
        } else if !input.isEmpty {
            threads[index].messages.append(
                CommentMessage(
                    author: .user,
                    body: input,
                    state: .draft,
                    createdAt: now,
                    updatedAt: now
                )
            )
            if threads[index].state == .resolved {
                threads[index].state = .open
            }
            threads[index].updatedAt = now
        }
        save()
    }

    /// Cancelling a just-created thread with empty input deletes it.
    func cancelOverlay(threadID: String, created: Bool, input: String) {
        if created, input.isEmpty {
            removeThread(id: threadID)
        }
    }

    func resolveThread(id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].resolve(now: CommentClock.timestamp())
        save()
    }

    /// Promotes every posted draft message to open. Called after a successful
    /// post.
    func markPosted(threadIDs: [String]) {
        let ids = Set(threadIDs)
        let now = CommentClock.timestamp()
        for index in threads.indices where ids.contains(threads[index].id) {
            threads[index].markMessagesOpen(now: now)
        }
        save()
    }

    func overlayWillOpen() {
        openOverlayCount += 1
    }

    func overlayDidClose() {
        openOverlayCount = max(0, openOverlayCount - 1)
    }

    // MARK: - Sidebar navigation

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    /// Opens the thread's file and moves the caret to the range start. When the
    /// thread was anchored at a commit that is neither "uncommitted" nor the
    /// current HEAD, a read-only snapshot of `git show <commit>:<path>` opens
    /// instead.
    func openThread(_ thread: CommentThread) {
        guard let root = workspace.rootURL else { return }
        let line = thread.range.start.line
        let col = thread.range.start.col
        let head = CommentGit.headCommit(worktreePath: root.path)
        if thread.commit != "uncommitted", let head, thread.commit != head {
            openSnapshot(of: thread, worktreePath: root.path, line: line, col: col)
            return
        }
        workspace.openFile(root.appendingPathComponent(thread.file))
        if let document = workspace.selectedDocument {
            requestCaret(documentID: document.id, line: line, col: col)
        }
    }

    private func openSnapshot(
        of thread: CommentThread,
        worktreePath: String,
        line: Int,
        col: Int
    ) {
        let commit = thread.commit
        let relativePath = thread.file
        Task { [weak self] in
            let content = await Task.detached(priority: .userInitiated) {
                CommentGit.fileContent(
                    atCommit: commit,
                    relativePath: relativePath,
                    worktreePath: worktreePath
                )
            }.value
            guard let self else { return }
            guard let content else {
                self.workspace.errorMessage =
                    "Cannot load \(relativePath) at \(commit.prefix(8))."
                return
            }
            let basename = (relativePath as NSString).lastPathComponent
            let document = self.workspace.openReadOnlyTab(
                title: "\(commit.prefix(8))@\(basename)",
                text: content
            )
            self.requestCaret(documentID: document.id, line: line, col: col)
        }
    }

    // MARK: - Posting

    struct PostTarget {
        static let textLabel = "text"

        let label: String
        let session: TerminalSession?
    }

    func postTargets() -> [PostTarget] {
        var targets = [PostTarget(label: PostTarget.textLabel, session: nil)]
        if let agentManager, let root = workspace.rootURL {
            for record in agentManager.records(for: root) {
                guard let session = agentManager.session(for: record.key),
                      !session.hasExited else { continue }
                targets.append(
                    PostTarget(label: "\(record.profile): \(record.name)", session: session)
                )
            }
        }
        return targets
    }

    func post(_ threads: [CommentThread], to target: PostTarget) throws {
        guard let worktreePath = loadedWorktreePath ?? workspace.rootURL?.path else { return }
        let blob = Self.blob(for: threads, worktreePath: worktreePath, cliInvocation: Self.cliInvocation())
        if let session = target.session {
            guard !session.hasExited else {
                throw ReviewCommentError("Agent is no longer active: \(target.label)")
            }
            session.send(text: blob + "\n")
            workspace.select(session)
        } else {
            _ = workspace.openReadOnlyTab(title: "Review Comments", text: blob)
        }
        markPosted(threadIDs: threads.map(\.id))
    }

    /// The posted blob: a header, one block per thread, and a footer telling
    /// the agent how to reply through the CLI. Mirrors v1 `blob_for`.
    nonisolated static func blob(
        for threads: [CommentThread],
        worktreePath: String,
        cliInvocation: String
    ) -> String {
        var out = ["Review comments for \(worktreePath)", ""]
        for thread in threads {
            out.append("comment \(thread.id)")
            out.append(
                "  \(thread.file):\(thread.range.start.line):\(thread.range.start.col)"
                    + "-\(thread.range.end.line):\(thread.range.end.col) [\(thread.commit)]"
            )
            for message in thread.messages {
                out.append("  \(message.author.label): \(message.body)")
            }
            out.append("")
        }
        out.append("To respond to a comment, run the DevHQ review CLI with the comment id shown above:")
        out.append("  \(cliInvocation) review reply <comment-id> --message \"your reply\"")
        out.append("This appends your reply to that thread; the reviewer sees it in the DevHQ review sidebar.")
        return out.joined(separator: "\n")
    }

    nonisolated static func cliInvocation(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String? = nil
    ) -> String {
        let executable = executablePath
            ?? Bundle.main.executablePath
            ?? CommandLine.arguments.first
            ?? "devhq"
        let quoted = shellQuote(executable)
        if let configDirectory = environment["DEVHQ_CONFIG_DIR"], !configDirectory.isEmpty {
            return "DEVHQ_CONFIG_DIR=\(shellQuote(configDirectory)) \(quoted)"
        }
        return quoted
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Editor coordination

    func register(coordinator: CommentEditorCoordinator, documentID: UUID) {
        coordinatorsByDocument[documentID] = WeakCommentCoordinator(coordinator)
        coordinatorsByDocument = coordinatorsByDocument.filter { $0.value.value != nil }
        if let caret = pendingCaret, caret.documentID == documentID {
            pendingCaret = nil
            coordinator.moveCaret(line: caret.line, col: caret.col)
        }
    }

    func unregister(coordinator: CommentEditorCoordinator, documentID: UUID) {
        if coordinatorsByDocument[documentID]?.value === coordinator {
            coordinatorsByDocument[documentID] = nil
        }
    }

    func consumePendingCaret(for documentID: UUID) -> (line: Int, col: Int)? {
        guard let caret = pendingCaret, caret.documentID == documentID else { return nil }
        pendingCaret = nil
        return (caret.line, caret.col)
    }

    private func requestCaret(documentID: UUID, line: Int, col: Int) {
        pendingCaret = (documentID, line, col)
        if let coordinator = coordinatorsByDocument[documentID]?.value, coordinator.isReady {
            pendingCaret = nil
            coordinator.moveCaret(line: line, col: col)
        }
    }

    private func refreshCoordinators() {
        for box in coordinatorsByDocument.values {
            box.value?.refreshMarkers()
        }
    }

    nonisolated static func relativePath(for url: URL, in rootURL: URL) -> String? {
        let rootComponents = rootURL.standardizedFileURL
            .resolvingSymlinksInPath().pathComponents
        let fileComponents = url.standardizedFileURL
            .resolvingSymlinksInPath().pathComponents
        guard fileComponents.starts(with: rootComponents),
              fileComponents.count > rootComponents.count else { return nil }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

private struct WeakCommentCoordinator {
    weak var value: CommentEditorCoordinator?

    init(_ value: CommentEditorCoordinator) {
        self.value = value
    }
}

// MARK: - Command registration

/// Pickers used by the review commands. Injectable so tests can drive the
/// choices without AppKit modals.
struct ReviewCommentPickers {
    var choose: (_ title: String, _ message: String, _ options: [String]) -> String?

    static let appKit = ReviewCommentPickers { title, message, options in
        MainActor.assumeIsolated {
            presentListAlert(title: title, message: message, options: options)
        }
    }

    @MainActor
    private static func presentListAlert(
        title: String,
        message: String,
        options: [String]
    ) -> String? {
        guard !options.isEmpty else { return nil }
        let controller = AgentProfileListController(profileNames: options)
        let rowHeight: CGFloat = 22
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 420, height: rowHeight))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("option"))
        column.width = 420
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.dataSource = controller
        table.delegate = controller
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 420, height: min(220, max(66, CGFloat(options.count) * rowHeight + 4)))
        )
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = table

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = table
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return controller.selectedProfile(in: table)
    }
}

@MainActor
func registerReviewCommentCommands(
    in commandManager: CommandManager,
    workspace: WorkspaceModel,
    comments: CommentThreadsController,
    pickers: ReviewCommentPickers = .appKit
) throws {
    let workspaceAvailable: RegisteredCommand.Predicate = { _ in
        workspace.rootURL != nil
    }

    try commandManager.add(
        id: "devhq:add-comment",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: workspaceAvailable
    ) { _ in
        try comments.addComment()
    }

    try commandManager.add(
        id: "devhq:resolve-comment",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: workspaceAvailable
    ) { _ in
        let open = comments.openThreads()
        guard !open.isEmpty else {
            throw ReviewCommentError("No open comments")
        }
        guard let selection = pickers.choose(
            "Resolve Comment",
            "Choose the comment thread to resolve.",
            open.map(\.label)
        ), let thread = open.first(where: { $0.label == selection }) else { return }
        comments.resolveThread(id: thread.id)
    }

    try commandManager.add(
        id: "devhq:post-all-comments",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: workspaceAvailable
    ) { _ in
        let postable = comments.postableThreads()
        guard !postable.isEmpty else {
            throw ReviewCommentError("No draft comments to post")
        }
        let targets = comments.postTargets()
        guard let selection = pickers.choose(
            "Post Comments",
            "Choose where the draft comments should go.",
            targets.map(\.label)
        ), let target = targets.first(where: { $0.label == selection }) else { return }
        try comments.post(postable, to: target)
    }

    try commandManager.add(
        id: "devhq:toggle-review-sidebar",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: workspaceAvailable
    ) { _ in
        comments.toggleSidebar()
    }
}

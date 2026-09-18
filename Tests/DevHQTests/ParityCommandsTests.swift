import Foundation
import XCTest
@testable import DevHQ

private final class ParityTestDiscoverer: GitWorktreeDiscovering {
    /// When set, discovery always returns this repository; otherwise a
    /// single-worktree repository is synthesized for the requested URL.
    var fixedRepository: GitRepositoryInfo?
    private(set) var discoveredURLs: [URL] = []

    init(fixedRepository: GitRepositoryInfo? = nil) {
        self.fixedRepository = fixedRepository
    }

    func discover(at url: URL) throws -> GitRepositoryInfo {
        discoveredURLs.append(url.standardizedFileURL)
        if let fixedRepository { return fixedRepository }
        return GitRepositoryInfo(
            rootURL: url,
            name: url.lastPathComponent,
            gitDirectoryURL: url.appendingPathComponent(".git", isDirectory: true),
            worktrees: [GitWorktreeInfo(name: "main", url: url, isMain: true)]
        )
    }
}

private final class ParityTestWatcher: RepositoryWatching {
    func cancel() {}
}

private final class ParityTestWorktreeManager: GitWorktreeManaging {
    var created: (repository: URL, branch: String, destination: URL)?
    var deleted: (repository: URL, worktree: URL)?

    func createWorktree(
        in repositoryURL: URL,
        branchName: String,
        at worktreeURL: URL
    ) throws -> GitWorktreeInfo {
        created = (repositoryURL, branchName, worktreeURL)
        return GitWorktreeInfo(name: branchName, url: worktreeURL, isMain: false)
    }

    func deleteWorktree(in repositoryURL: URL, at worktreeURL: URL) throws {
        deleted = (repositoryURL, worktreeURL)
    }
}

final class ParityCommandsTests: XCTestCase {
    @MainActor
    func testRegistrationDefinesExpectedIdentifiersScopesAndAvailability() throws {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let explorer = makeExplorer()
        let manager = CommandManager()
        let drawer = TerminalDrawerModel()
        let sidebar = SidebarVisibilityModel()
        try registerCommandParityCommands(
            in: manager,
            workspace: workspace,
            worktreeExplorer: explorer,
            settings: EditorSettings(),
            worktreeManager: ParityTestWorktreeManager(),
            terminalDrawer: drawer,
            sidebarVisibility: sidebar,
            prompts: cancellingPrompts()
        )

        XCTAssertEqual(Set(manager.commandsByID.keys), [
            "devhq:scan-all-repos", "devhq:create-worktree", "devhq:delete-worktree",
            "devhq:toggle-sidebar", "terminal:toggle-drawer", "terminal:spawn-command",
            "terminal:clear", "terminal:scroll-up", "terminal:scroll-down"
        ])
        XCTAssertEqual(
            manager.commandsByID["devhq:scan-all-repos"]?.title,
            "devhq: scan all repos"
        )
        XCTAssertEqual(
            manager.commandsByID["terminal:toggle-drawer"]?.title,
            "terminal: toggle drawer"
        )
        for id in [
            "devhq:scan-all-repos", "devhq:create-worktree", "devhq:delete-worktree",
            "devhq:toggle-sidebar", "terminal:toggle-drawer", "terminal:spawn-command"
        ] {
            XCTAssertEqual(
                manager.commandsByID[id]?.viewKinds,
                Set(CommandViewKind.allCases),
                id
            )
        }
        for id in ["terminal:clear", "terminal:scroll-up", "terminal:scroll-down"] {
            XCTAssertEqual(manager.commandsByID[id]?.viewKinds, [.terminal], id)
        }

        // Without a workspace, repositories, or terminals only the prompts
        // that need nothing are available.
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .worktree)).map(\.id),
            ["devhq:scan-all-repos", "devhq:toggle-sidebar"]
        )
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .terminal)).map(\.id),
            ["devhq:scan-all-repos", "devhq:toggle-sidebar"]
        )
    }

    @MainActor
    func testScanAllReposAddsFoundRepositoriesAndSkipsAlreadyAddedOnes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = root.appendingPathComponent("alpha", isDirectory: true)
        let gamma = root.appendingPathComponent("beta/gamma", isDirectory: true)
        for repo in [alpha, gamma] {
            try FileManager.default.createDirectory(
                at: repo.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let explorer = makeExplorer()
        try explorer.addRepository(alpha)
        let manager = CommandManager()
        var prompts = cancellingPrompts()
        prompts.scanDirectoryURL = { root }
        try registerParityCommands(
            manager: manager,
            workspace: workspace,
            explorer: explorer,
            prompts: prompts
        )

        try manager.execute(id: "devhq:scan-all-repos", in: CommandContext(view: .worktree))
        await waitUntil { workspace.errorMessage != nil }

        XCTAssertEqual(
            Set(explorer.repositories.map(\.name)),
            ["alpha", "gamma"]
        )
        XCTAssertEqual(workspace.errorMessage, "Added 1 repository.")
        XCTAssertNil(explorer.errorMessage)
    }

    @MainActor
    func testScanAllReposRejectsNonDirectoryTargets() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        let explorer = makeExplorer()
        let manager = CommandManager()
        var prompts = cancellingPrompts()
        prompts.scanDirectoryURL = { file }
        try registerParityCommands(
            manager: manager,
            workspace: WorkspaceModel(arguments: ["DevHQ"]),
            explorer: explorer,
            prompts: prompts
        )

        XCTAssertThrowsError(
            try manager.execute(id: "devhq:scan-all-repos", in: CommandContext(view: .file))
        ) { error in
            XCTAssertEqual(error as? RepoScannerError, .notADirectory(file))
        }
        XCTAssertTrue(explorer.repositories.isEmpty)
    }

    @MainActor
    func testCreateWorktreeTargetsSingleOrSelectedRepositoryAndValidatesInput() throws {
        let fixture = try makeWorktreeFixture(includeLinkedWorktree: false)
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let explorer = makeExplorer(
            discoverer: ParityTestDiscoverer(fixedRepository: fixture.repository)
        )
        try explorer.addRepository(fixture.main)
        let settings = EditorSettings()
        settings.gitWorktreePath = "trees"
        let worktreeManager = ParityTestWorktreeManager()
        let manager = CommandManager()
        var prompts = cancellingPrompts()
        var branchName: String? = "feature/palette"
        prompts.worktreeBranchName = { branchName }
        try registerParityCommands(
            manager: manager,
            workspace: WorkspaceModel(arguments: ["DevHQ"]),
            explorer: explorer,
            settings: settings,
            worktreeManager: worktreeManager,
            prompts: prompts
        )

        // The single repository is targeted without an explorer selection.
        XCTAssertNil(explorer.selectedWorktreeID)
        try manager.execute(id: "devhq:create-worktree", in: CommandContext(view: .worktree))
        XCTAssertEqual(worktreeManager.created?.repository, fixture.main)
        XCTAssertEqual(worktreeManager.created?.branch, "feature/palette")
        XCTAssertEqual(
            worktreeManager.created?.destination.path,
            fixture.main.appendingPathComponent("trees/feature/palette").path
        )

        // Empty branch names are refused.
        worktreeManager.created = nil
        branchName = ""
        XCTAssertThrowsError(
            try manager.execute(id: "devhq:create-worktree", in: CommandContext(view: .file))
        ) { error in
            XCTAssertEqual(error as? CommandParityError, .emptyBranchName)
        }
        XCTAssertNil(worktreeManager.created)

        // Cancelling the prompt is a silent no-op.
        branchName = nil
        try manager.execute(id: "devhq:create-worktree", in: CommandContext(view: .document))
        XCTAssertNil(worktreeManager.created)
    }

    @MainActor
    func testCreateWorktreeRejectsRemoteRepositoriesBeforePrompting() throws {
        let fixture = try makeWorktreeFixture(includeLinkedWorktree: false, remote: true)
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let explorer = makeExplorer(
            discoverer: ParityTestDiscoverer(fixedRepository: fixture.repository)
        )
        try explorer.addRepository(fixture.main)
        let worktreeManager = ParityTestWorktreeManager()
        let manager = CommandManager()
        var prompts = cancellingPrompts()
        var promptCalls = 0
        prompts.worktreeBranchName = {
            promptCalls += 1
            return "feature/remote"
        }
        try registerParityCommands(
            manager: manager,
            workspace: WorkspaceModel(arguments: ["DevHQ"]),
            explorer: explorer,
            worktreeManager: worktreeManager,
            prompts: prompts
        )

        XCTAssertThrowsError(
            try manager.execute(id: "devhq:create-worktree", in: CommandContext(view: .worktree))
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Remote repositories do not support local worktree creation."
            )
        }
        XCTAssertEqual(promptCalls, 0)
        XCTAssertNil(worktreeManager.created)
    }

    @MainActor
    func testDeleteWorktreeActsOnSelectedRowAndRefusesMainWorktree() throws {
        let fixture = try makeWorktreeFixture(includeLinkedWorktree: true)
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let explorer = makeExplorer(
            discoverer: ParityTestDiscoverer(fixedRepository: fixture.repository)
        )
        try explorer.addRepository(fixture.main)
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let worktreeManager = ParityTestWorktreeManager()
        let manager = CommandManager()
        try registerParityCommands(
            manager: manager,
            workspace: workspace,
            explorer: explorer,
            worktreeManager: worktreeManager,
            prompts: cancellingPrompts()
        )

        // Without a selected worktree the command is unavailable.
        XCTAssertThrowsError(
            try manager.execute(id: "devhq:delete-worktree", in: CommandContext(view: .worktree))
        ) { error in
            XCTAssertEqual(
                error as? CommandManagerError,
                .commandUnavailable("devhq:delete-worktree")
            )
        }

        // The main worktree row is refused.
        explorer.syncSelection(with: fixture.main)
        XCTAssertThrowsError(
            try manager.execute(id: "devhq:delete-worktree", in: CommandContext(view: .worktree))
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The main worktree cannot be deleted."
            )
        }
        XCTAssertNil(worktreeManager.deleted)

        // The selected linked worktree row is deleted.
        explorer.syncSelection(with: fixture.linked)
        try manager.execute(id: "devhq:delete-worktree", in: CommandContext(view: .file))
        XCTAssertEqual(worktreeManager.deleted?.repository, fixture.main)
        XCTAssertEqual(worktreeManager.deleted?.worktree, fixture.linked)
    }

    @MainActor
    func testDeleteWorktreeRejectsRemoteRepositories() throws {
        let fixture = try makeWorktreeFixture(includeLinkedWorktree: true, remote: true)
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let explorer = makeExplorer(
            discoverer: ParityTestDiscoverer(fixedRepository: fixture.repository)
        )
        try explorer.addRepository(fixture.main)
        let worktreeManager = ParityTestWorktreeManager()
        let manager = CommandManager()
        try registerParityCommands(
            manager: manager,
            workspace: WorkspaceModel(arguments: ["DevHQ"]),
            explorer: explorer,
            worktreeManager: worktreeManager,
            prompts: cancellingPrompts()
        )
        explorer.syncSelection(with: fixture.linked)

        XCTAssertThrowsError(
            try manager.execute(id: "devhq:delete-worktree", in: CommandContext(view: .worktree))
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Remote repositories do not support local worktree deletion."
            )
        }
        XCTAssertNil(worktreeManager.deleted)
    }

    @MainActor
    func testToggleSidebarFlipsWorktreeExplorerVisibility() throws {
        let sidebar = SidebarVisibilityModel()
        let manager = CommandManager()
        try registerParityCommands(
            manager: manager,
            workspace: WorkspaceModel(arguments: ["DevHQ"]),
            explorer: makeExplorer(),
            sidebar: sidebar,
            prompts: cancellingPrompts()
        )

        XCTAssertTrue(sidebar.isWorktreeExplorerVisible)
        try manager.execute(id: "devhq:toggle-sidebar", in: CommandContext(view: .worktree))
        XCTAssertFalse(sidebar.isWorktreeExplorerVisible)
        try manager.execute(id: "devhq:toggle-sidebar", in: CommandContext(view: .terminal))
        XCTAssertTrue(sidebar.isWorktreeExplorerVisible)
    }

    @MainActor
    func testToggleDrawerCommandCreatesShowsAndCollapsesTheDrawer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let drawer = TerminalDrawerModel { workingDirectory in
            try TerminalSession(rootURL: workingDirectory, command: ["/bin/cat"])
        }
        defer { drawer.terminate() }
        let manager = CommandManager()
        try registerParityCommands(
            manager: manager,
            workspace: workspace,
            explorer: makeExplorer(),
            drawer: drawer,
            prompts: cancellingPrompts()
        )

        // Unavailable without a workspace or an existing drawer session.
        XCTAssertThrowsError(
            try manager.execute(id: "terminal:toggle-drawer", in: CommandContext(view: .file))
        ) { error in
            XCTAssertEqual(
                error as? CommandManagerError,
                .commandUnavailable("terminal:toggle-drawer")
            )
        }

        workspace.openWorkspace(root)
        try manager.execute(id: "terminal:toggle-drawer", in: CommandContext(view: .file))
        XCTAssertTrue(drawer.isVisible)
        let session = try XCTUnwrap(drawer.session)

        try manager.execute(id: "terminal:toggle-drawer", in: CommandContext(view: .terminal))
        XCTAssertFalse(drawer.isVisible)
        XCTAssertEqual(drawer.session?.id, session.id)

        try manager.execute(id: "terminal:toggle-drawer", in: CommandContext(view: .worktree))
        XCTAssertTrue(drawer.isVisible)
        XCTAssertEqual(drawer.session?.id, session.id)
    }

    @MainActor
    func testSpawnCommandArgvAndTabCreation() throws {
        XCTAssertEqual(
            WorkspaceModel.shellCommandArguments(
                shellCommand: "echo done",
                environment: [:],
                processEnvironment: ["SHELL": "/bin/zsh"]
            ),
            ["/usr/bin/env", "/bin/zsh", "-l", "-c", "echo done"]
        )

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        defer { workspace.closeAllTerminals() }
        let manager = CommandManager()
        var prompts = cancellingPrompts()
        var shellCommand: String? = "printf spawned"
        prompts.shellCommand = { shellCommand }
        try registerParityCommands(
            manager: manager,
            workspace: workspace,
            explorer: makeExplorer(),
            prompts: prompts
        )

        // Unavailable without a workspace.
        XCTAssertThrowsError(
            try manager.execute(id: "terminal:spawn-command", in: CommandContext(view: .file))
        ) { error in
            XCTAssertEqual(
                error as? CommandManagerError,
                .commandUnavailable("terminal:spawn-command")
            )
        }

        workspace.openWorkspace(root)
        try manager.execute(id: "terminal:spawn-command", in: CommandContext(view: .file))
        XCTAssertEqual(workspace.terminalSessions.count, 1)
        XCTAssertEqual(workspace.selectedTerminal?.id, workspace.terminalSessions.first?.id)

        // The tab remains after the command exits.
        let session = try XCTUnwrap(workspace.selectedTerminal)
        let deadline = Date().addingTimeInterval(5)
        while session.exitStatus == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertNotNil(session.exitStatus)
        XCTAssertEqual(workspace.terminalSessions.count, 1)

        // Empty commands are refused; cancelling is a silent no-op.
        shellCommand = ""
        XCTAssertThrowsError(
            try manager.execute(id: "terminal:spawn-command", in: CommandContext(view: .file))
        ) { error in
            XCTAssertEqual(error as? CommandParityError, .emptyCommand)
        }
        shellCommand = nil
        try manager.execute(id: "terminal:spawn-command", in: CommandContext(view: .file))
        XCTAssertEqual(workspace.terminalSessions.count, 1)
    }

    @MainActor
    func testClearAndScrollActOnSelectedTerminalScrollback() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        defer { workspace.closeAllTerminals() }
        let manager = CommandManager()
        try registerParityCommands(
            manager: manager,
            workspace: workspace,
            explorer: makeExplorer(),
            prompts: cancellingPrompts()
        )

        // Unavailable without any terminal.
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .terminal))
                .map(\.id)
                .filter { $0.hasPrefix("terminal:clear") || $0.hasPrefix("terminal:scroll") },
            []
        )

        workspace.openWorkspace(root)
        let session = try workspace.newTerminal(command: [
            "/bin/sh", "-c",
            "i=1; while [ $i -le 60 ]; do echo line$i; i=$((i+1)); done; exec /bin/cat"
        ])
        let deadline = Date().addingTimeInterval(5)
        while session.snapshot.scrollbackCount == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertGreaterThan(session.snapshot.scrollbackCount, 0)

        let context = CommandContext(view: .terminal, terminalID: session.id)
        try manager.execute(id: "terminal:scroll-up", in: context)
        XCTAssertEqual(session.snapshot.scrollOffset, 3)
        try manager.execute(id: "terminal:scroll-down", in: context)
        XCTAssertEqual(session.snapshot.scrollOffset, 0)
        XCTAssertNoThrow(try manager.execute(id: "terminal:clear", in: context))
        XCTAssertNil(session.exitStatus)
    }

    @MainActor
    func testTerminalCommandsFallBackToTheVisibleDrawerSession() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(root)
        let drawer = TerminalDrawerModel { workingDirectory in
            try TerminalSession(rootURL: workingDirectory, command: ["/bin/cat"])
        }
        defer { drawer.terminate() }
        let manager = CommandManager()
        try registerParityCommands(
            manager: manager,
            workspace: workspace,
            explorer: makeExplorer(),
            drawer: drawer,
            prompts: cancellingPrompts()
        )
        try drawer.show(activeWorktree: root)

        let context = CommandContext(view: .terminal)
        XCTAssertTrue(
            try manager.commands(in: context).map(\.id).contains("terminal:clear")
        )
        XCTAssertNoThrow(try manager.execute(id: "terminal:clear", in: context))
        XCTAssertNoThrow(try manager.execute(id: "terminal:scroll-up", in: context))

        // A collapsed drawer is no longer a target.
        try drawer.toggle(activeWorktree: root)
        XCTAssertThrowsError(
            try manager.execute(id: "terminal:clear", in: context)
        ) { error in
            XCTAssertEqual(
                error as? CommandManagerError,
                .commandUnavailable("terminal:clear")
            )
        }
    }

    @MainActor
    private func registerParityCommands(
        manager: CommandManager,
        workspace: WorkspaceModel,
        explorer: WorktreeExplorerModel,
        settings: EditorSettings? = nil,
        worktreeManager: any GitWorktreeManaging = ParityTestWorktreeManager(),
        drawer: TerminalDrawerModel? = nil,
        sidebar: SidebarVisibilityModel? = nil,
        prompts: CommandParityPrompts
    ) throws {
        try registerCommandParityCommands(
            in: manager,
            workspace: workspace,
            worktreeExplorer: explorer,
            settings: settings ?? EditorSettings(),
            worktreeManager: worktreeManager,
            terminalDrawer: drawer ?? TerminalDrawerModel(),
            sidebarVisibility: sidebar ?? SidebarVisibilityModel(),
            prompts: prompts
        )
    }

    @MainActor
    private func makeExplorer(
        discoverer: any GitWorktreeDiscovering = ParityTestDiscoverer()
    ) -> WorktreeExplorerModel {
        WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { _, _ in },
            watcherFactory: { _, _ in ParityTestWatcher() },
            eventDelivery: { $0() }
        )
    }

    private func cancellingPrompts() -> CommandParityPrompts {
        CommandParityPrompts(
            scanDirectoryURL: { nil },
            worktreeBranchName: { nil },
            shellCommand: { nil }
        )
    }

    private func makeWorktreeFixture(
        includeLinkedWorktree: Bool,
        remote: Bool = false
    ) throws -> (container: URL, main: URL, linked: URL, repository: GitRepositoryInfo) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let main = container.appendingPathComponent("project", isDirectory: true)
        let linked = container.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        if includeLinkedWorktree {
            try FileManager.default.createDirectory(
                at: linked,
                withIntermediateDirectories: true
            )
        }
        let worktrees = [GitWorktreeInfo(name: "main", url: main, isMain: true)]
            + (includeLinkedWorktree
                ? [GitWorktreeInfo(name: "feature", url: linked, isMain: false)]
                : [])
        let repository = GitRepositoryInfo(
            rootURL: main,
            name: "project",
            gitDirectoryURL: main.appendingPathComponent(".git", isDirectory: true),
            worktrees: worktrees,
            remoteSource: remote
                ? try SSHRemoteRepositorySource(server: "example.com", remotePath: "/srv/project")
                : nil
        )
        return (container, main, linked, repository)
    }

    private func waitUntil(
        attempts: Int = 600,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if await MainActor.run(body: predicate) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

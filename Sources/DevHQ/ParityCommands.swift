import AppKit
import Foundation

/// Visibility of the worktree explorer sidebar (the leftmost pane). This is
/// intentionally not persisted; Lua's `treeview.visible` setting continues to
/// govern startup visibility of both sidebars.
@MainActor
final class SidebarVisibilityModel: ObservableObject {
    @Published var isWorktreeExplorerVisible = true

    func toggle() {
        isWorktreeExplorerVisible.toggle()
    }
}

enum CommandParityError: LocalizedError, Equatable {
    case noRepositorySelected
    case noWorktreeSelected
    case emptyBranchName
    case emptyCommand

    var errorDescription: String? {
        switch self {
        case .noRepositorySelected:
            "Select a repository in the worktree explorer first."
        case .noWorktreeSelected:
            "Select a worktree in the worktree explorer first."
        case .emptyBranchName:
            "Enter a branch name to create a worktree."
        case .emptyCommand:
            "Enter a shell command to spawn."
        }
    }
}

struct CommandParityPrompts {
    var scanDirectoryURL: @MainActor () -> URL?
    var worktreeBranchName: @MainActor () -> String?
    var shellCommand: @MainActor () -> String?

    static let appKit = CommandParityPrompts(
        scanDirectoryURL: {
            let panel = NSOpenPanel()
            panel.title = "Scan for Git Repositories"
            panel.prompt = "Scan"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url : nil
        },
        worktreeBranchName: {
            promptForWorktreeBranchName()
        },
        shellCommand: {
            let commandField = NSTextField(string: "")
            commandField.placeholderString = "make test"
            commandField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)

            let alert = NSAlert()
            alert.messageText = "Spawn Command"
            alert.informativeText = "Enter a shell command to run in a new terminal tab."
            alert.addButton(withTitle: "Run")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = commandField
            alert.window.initialFirstResponder = commandField

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    )
}

/// Registers the DevHQ v1 command-parity commands. Kept separate from
/// `registerBuiltInCommands` so the built-in registration surface stays
/// stable for concurrent feature branches.
@MainActor
func registerCommandParityCommands(
    in commandManager: CommandManager,
    workspace: WorkspaceModel,
    worktreeExplorer: WorktreeExplorerModel,
    settings: EditorSettings,
    worktreeManager: any GitWorktreeManaging,
    terminalDrawer: TerminalDrawerModel,
    sidebarVisibility: SidebarVisibilityModel,
    prompts: CommandParityPrompts? = nil
) throws {
    let prompts = prompts ?? .appKit

    try commandManager.add(
        id: "devhq:scan-all-repos",
        viewKinds: Set(CommandViewKind.allCases)
    ) { _ in
        guard let directory = prompts.scanDirectoryURL() else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw RepoScannerError.notADirectory(directory)
        }
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                (try? RepoScanner.scanRepositories(under: directory)) ?? []
            }.value
            var added = 0
            for url in found {
                await Task.yield()
                do {
                    try worktreeExplorer.addRepository(url)
                    added += 1
                } catch {
                    // Repositories that are already added, or fail discovery,
                    // are skipped; the scan itself keeps going like v1.
                    continue
                }
            }
            worktreeExplorer.clearError()
            worktreeExplorer.syncSelection(with: workspace.rootURL)
            let noun = added == 1 ? "repository" : "repositories"
            workspace.errorMessage = "Added \(added) \(noun)."
        }
    }

    try commandManager.add(
        id: "devhq:create-worktree",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: { _ in commandTargetRepository(in: worktreeExplorer) != nil }
    ) { _ in
        guard let repository = commandTargetRepository(in: worktreeExplorer) else {
            throw CommandParityError.noRepositorySelected
        }
        guard repository.remoteSource == nil else {
            throw ExplorerContextMenuError.cannotCreateRemoteWorktree
        }
        guard let branchName = prompts.worktreeBranchName() else { return }
        guard !branchName.isEmpty else {
            throw CommandParityError.emptyBranchName
        }
        try performCreateWorktree(
            repository: repository,
            branchName: branchName,
            settings: settings,
            worktreeManager: worktreeManager,
            worktreeExplorer: worktreeExplorer
        )
    }

    try commandManager.add(
        id: "devhq:delete-worktree",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: { _ in commandSelectedWorktree(in: worktreeExplorer) != nil }
    ) { _ in
        guard let (repository, worktree) = commandSelectedWorktree(in: worktreeExplorer) else {
            throw CommandParityError.noWorktreeSelected
        }
        try performDeleteWorktree(
            repository: repository,
            worktree: worktree,
            workspace: workspace,
            worktreeManager: worktreeManager,
            worktreeExplorer: worktreeExplorer
        )
    }

    try commandManager.add(
        id: "devhq:toggle-sidebar",
        viewKinds: Set(CommandViewKind.allCases)
    ) { _ in
        sidebarVisibility.toggle()
    }

    try commandManager.add(
        id: "terminal:toggle-drawer",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: { _ in workspace.rootURL != nil || terminalDrawer.session != nil }
    ) { _ in
        try terminalDrawer.toggle(activeWorktree: workspace.rootURL)
    }

    try commandManager.add(
        id: "terminal:spawn-command",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: { _ in workspace.rootURL != nil }
    ) { _ in
        guard let rootURL = workspace.rootURL else { return }
        guard let shellCommand = prompts.shellCommand() else { return }
        guard !shellCommand.isEmpty else {
            throw CommandParityError.emptyCommand
        }
        _ = try workspace.newTerminal(
            workingDirectory: rootURL,
            shellCommand: shellCommand,
            environment: [:]
        )
    }

    let targetTerminal: (CommandContext) -> TerminalSession? = { context in
        if let terminalID = context.terminalID,
           let terminal = workspace.terminalSessions.first(where: { $0.id == terminalID }) {
            return terminal
        }
        if let selected = workspace.selectedTerminal { return selected }
        return terminalDrawer.isVisible ? terminalDrawer.session : nil
    }
    let terminalAvailable: RegisteredCommand.Predicate = { context in
        targetTerminal(context) != nil
    }

    try commandManager.add(
        id: "terminal:clear",
        viewKinds: [.terminal],
        predicate: terminalAvailable
    ) { context in
        targetTerminal(context)?.send(text: "\u{0C}")
    }

    try commandManager.add(
        id: "terminal:scroll-up",
        viewKinds: [.terminal],
        predicate: terminalAvailable
    ) { context in
        targetTerminal(context)?.scroll(lines: 3)
    }

    try commandManager.add(
        id: "terminal:scroll-down",
        viewKinds: [.terminal],
        predicate: terminalAvailable
    ) { context in
        targetTerminal(context)?.scroll(lines: -3)
    }
}

@MainActor
func commandTargetRepository(in explorer: WorktreeExplorerModel) -> GitRepositoryInfo? {
    if let selectedWorktreeID = explorer.selectedWorktreeID,
       let repository = explorer.repositories.first(where: { repository in
           repository.worktrees.contains { $0.id == selectedWorktreeID }
       }) {
        return repository
    }
    return explorer.repositories.count == 1 ? explorer.repositories.first : nil
}

@MainActor
func commandSelectedWorktree(
    in explorer: WorktreeExplorerModel
) -> (GitRepositoryInfo, GitWorktreeInfo)? {
    guard let selectedWorktreeID = explorer.selectedWorktreeID else { return nil }
    return explorer.repositories.lazy.compactMap { repository in
        repository.worktrees.first { $0.id == selectedWorktreeID }
            .map { (repository, $0) }
    }.first
}

import Foundation
import SwiftUI

/// The bottom terminal drawer mirroring DevHQ v1's ghostty drawer: one login
/// shell session is reused across hide/show, hiding collapses the pane
/// without terminating the shell, and new spawns follow the active worktree.
@MainActor
final class TerminalDrawerModel: ObservableObject {
    static let defaultHeight: CGFloat = 300

    @Published private(set) var isVisible = false
    @Published private(set) var session: TerminalSession?

    private let makeSession: @MainActor (URL) throws -> TerminalSession

    init(
        makeSession: @escaping @MainActor (URL) throws -> TerminalSession = { rootURL in
            try TerminalSession(rootURL: rootURL)
        }
    ) {
        self.makeSession = makeSession
    }

    /// Hides the drawer when visible; otherwise shows it, spawning a login
    /// shell in the active worktree if no live drawer session exists yet.
    func toggle(activeWorktree: URL?) throws {
        if isVisible {
            isVisible = false
            return
        }
        try show(activeWorktree: activeWorktree)
    }

    func show(activeWorktree: URL?) throws {
        if session == nil || session?.hasExited == true {
            session?.close()
            session = nil
            guard let activeWorktree else {
                throw WorkspaceCommandOperationError.noWorkspace
            }
            let workingDirectory = activeWorktree
                .standardizedFileURL
                .resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: workingDirectory.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw WorkspaceCommandOperationError
                    .invalidTerminalWorkingDirectory(workingDirectory)
            }
            let created = try makeSession(workingDirectory)
            created.setActive(true)
            session = created
        }
        isVisible = true
    }

    /// Terminates the drawer shell for good, matching how other terminals are
    /// closed at application termination.
    func terminate() {
        session?.close()
        session = nil
        isVisible = false
    }
}

struct TerminalDrawerPane: View {
    @ObservedObject var drawer: TerminalDrawerModel
    @ObservedObject var settings: EditorSettings

    var body: some View {
        if let session = drawer.session {
            TerminalView(session: session, fontName: settings.terminalFontName)
                .id(session.id)
        }
    }
}

import Foundation
import XCTest
@testable import DevHQ

final class GitHistoryTests: XCTestCase {
    // MARK: - Parsing

    func testParseBranchHistoryParsesUnitSeparatedRecords() {
        let unit = "\u{1f}"
        let lines = [
            ["a1b2c3d4", "a1b2c3d", "2026-09-17", "Ada Lovelace", "feat: add - dashes \(unit) ok"],
            ["e5f6a7b8", "e5f6a7b", "2026-09-16", "Grace Hopper", ""],
            ["malformed-line"],
        ]
        let data = Data(
            lines.map { $0.joined(separator: unit) }.joined(separator: "\n").utf8
        )

        let commits = GitHistoryService.parseBranchHistory(data)

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].hash, "a1b2c3d4")
        XCTAssertEqual(commits[0].shortHash, "a1b2c3d")
        XCTAssertEqual(commits[0].date, "2026-09-17")
        XCTAssertEqual(commits[0].author, "Ada Lovelace")
        XCTAssertEqual(commits[0].subject, "feat: add - dashes \(unit) ok")
        XCTAssertEqual(
            commits[0].label,
            "feat: add - dashes \(unit) ok - a1b2c3d - 2026-09-17"
        )
        XCTAssertEqual(commits[1].subject, "")
    }

    func testParseCommitFilesMergesRenamesAndNumstatInOrder() {
        let nameStatus = Data(
            "R100\0old.txt\0new.txt\0M\0mod.txt\0A\0added.txt\0D\0gone.txt\0".utf8
        )
        let numstat = Data(
            "3\t1\t\0old.txt\0new.txt\02\t0\tmod.txt\0-\t-\tadded.txt\0".utf8
        )

        let files = GitHistoryService.parseCommitFiles(
            nameStatus: nameStatus,
            numstat: numstat
        )

        XCTAssertEqual(files.map(\.path), ["new.txt", "mod.txt", "added.txt", "gone.txt"])
        XCTAssertEqual(files[0].kind, .renamed)
        XCTAssertEqual(files[0].oldPath, "old.txt")
        XCTAssertEqual(files[0].additions, 3)
        XCTAssertEqual(files[0].deletions, 1)
        XCTAssertEqual(files[1].kind, .modified)
        XCTAssertEqual(files[1].additions, 2)
        XCTAssertEqual(files[1].deletions, 0)
        XCTAssertEqual(files[2].kind, .added)
        XCTAssertTrue(files[2].isBinary)
        XCTAssertNil(files[2].additions)
        XCTAssertEqual(files[3].kind, .deleted)
        XCTAssertNil(files[3].additions)
    }

    // MARK: - Branch history

    func testBranchHistoryListsFeatureCommitsNewestFirst() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try git(["checkout", "-b", "feature"], in: fixture.repository)
        try write("first\n", to: "first.txt", in: fixture.repository)
        try git(["add", "first.txt"], in: fixture.repository)
        try commit("feat: first", in: fixture.repository)
        let firstHash = try gitOutput(["rev-parse", "HEAD"], in: fixture.repository)
        try write("second\n", to: "second.txt", in: fixture.repository)
        try git(["add", "second.txt"], in: fixture.repository)
        try commit("feat: second", in: fixture.repository)
        let secondHash = try gitOutput(["rev-parse", "HEAD"], in: fixture.repository)

        let commits = try await GitHistoryService().branchHistory(in: fixture.repository)

        XCTAssertEqual(commits.map(\.hash), [secondHash, firstHash])
        XCTAssertEqual(commits.map(\.subject), ["feat: second", "feat: first"])
        XCTAssertEqual(commits[0].author, "DevHQ Tests")
        XCTAssertEqual(commits[0].shortHash, String(secondHash.prefix(7)))
        XCTAssertFalse(commits[0].date.isEmpty)
    }

    func testBranchHistoryWithoutParentThrowsNoParent() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try gitRaw(["init", "-b", "solo", repository.path])
        try git(["config", "user.email", "devhq@example.invalid"], in: repository)
        try git(["config", "user.name", "DevHQ Tests"], in: repository)
        try write("base\n", to: "base.txt", in: repository)
        try git(["add", "base.txt"], in: repository)
        try commit("base", in: repository)

        do {
            _ = try await GitHistoryService().branchHistory(in: repository)
            XCTFail("Expected a no-parent error")
        } catch let GitQueryError.noParent(message) {
            XCTAssertFalse(message.isEmpty)
        }
    }

    // MARK: - Commit files

    func testCommitFilesReportsStatusesRenamesAndCounts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try write("keep\nkeep\nkeep\nkeep\n", to: "renameme.txt", in: fixture.repository)
        try write("doomed\n", to: "doomed.txt", in: fixture.repository)
        try git(["add", "."], in: fixture.repository)
        try commit("setup", in: fixture.repository)
        try git(["checkout", "-b", "feature"], in: fixture.repository)

        try git(["mv", "renameme.txt", "renamed.txt"], in: fixture.repository)
        try write("base\nchanged\n", to: "base.txt", in: fixture.repository)
        try write("brand new\n", to: "added.txt", in: fixture.repository)
        try git(["rm", "-q", "doomed.txt"], in: fixture.repository)
        try git(["add", "."], in: fixture.repository)
        try commit("feat: reshape", in: fixture.repository)
        let commitHash = try gitOutput(["rev-parse", "HEAD"], in: fixture.repository)

        let files = try await GitHistoryService().commitFiles(
            in: fixture.repository,
            commit: commitHash
        )

        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        XCTAssertEqual(
            Set(byPath.keys),
            ["renamed.txt", "base.txt", "added.txt", "doomed.txt"]
        )
        XCTAssertEqual(byPath["renamed.txt"]?.kind, .renamed)
        XCTAssertEqual(byPath["renamed.txt"]?.oldPath, "renameme.txt")
        XCTAssertEqual(byPath["renamed.txt"]?.additions, 0)
        XCTAssertEqual(byPath["renamed.txt"]?.deletions, 0)
        XCTAssertEqual(byPath["base.txt"]?.kind, .modified)
        XCTAssertEqual(byPath["base.txt"]?.additions, 1)
        XCTAssertEqual(byPath["base.txt"]?.deletions, 0)
        XCTAssertEqual(byPath["added.txt"]?.kind, .added)
        XCTAssertEqual(byPath["added.txt"]?.additions, 1)
        XCTAssertEqual(byPath["doomed.txt"]?.kind, .deleted)
        XCTAssertEqual(byPath["doomed.txt"]?.deletions, 1)
    }

    func testRootCommitFilesDiffAgainstEmptyTree() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let files = try await GitHistoryService().commitFiles(
            in: fixture.repository,
            commit: fixture.baseCommit
        )

        XCTAssertEqual(files.map(\.path), ["base.txt"])
        XCTAssertEqual(files.first?.kind, .added)
    }

    // MARK: - File content

    func testDeletedFileContentFallsBackToCommitParent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try git(["checkout", "-b", "feature"], in: fixture.repository)
        try git(["rm", "-q", "base.txt"], in: fixture.repository)
        try commit("chore: delete base", in: fixture.repository)
        let commitHash = try gitOutput(["rev-parse", "HEAD"], in: fixture.repository)
        let change = GitFileChange(path: "base.txt", kind: .deleted)

        let content = try await GitHistoryService().fileContent(
            in: fixture.repository,
            commit: commitHash,
            change: change
        )

        XCTAssertEqual(String(decoding: content, as: UTF8.self), "base\n")
    }

    func testFileContentReturnsCommitVersionNotWorkingTree() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try git(["checkout", "-b", "feature"], in: fixture.repository)
        try write("base\ncommitted\n", to: "base.txt", in: fixture.repository)
        try git(["add", "base.txt"], in: fixture.repository)
        try commit("feat: change base", in: fixture.repository)
        let commitHash = try gitOutput(["rev-parse", "HEAD"], in: fixture.repository)
        try write("base\nuncommitted\n", to: "base.txt", in: fixture.repository)

        let content = try await GitHistoryService().fileContent(
            in: fixture.repository,
            commit: commitHash,
            change: GitFileChange(path: "base.txt", kind: .modified)
        )

        XCTAssertEqual(String(decoding: content, as: UTF8.self), "base\ncommitted\n")
    }

    // MARK: - Historical diff

    func testHistoricalDiffScopesHunksToThatCommit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try git(["checkout", "-b", "feature"], in: fixture.repository)
        try write("base\ntwo\n", to: "base.txt", in: fixture.repository)
        try git(["add", "base.txt"], in: fixture.repository)
        try commit("feat: two", in: fixture.repository)
        let firstHash = try gitOutput(["rev-parse", "HEAD"], in: fixture.repository)
        try write("base\ntwo\nthree\n", to: "base.txt", in: fixture.repository)
        try git(["add", "base.txt"], in: fixture.repository)
        try commit("feat: three", in: fixture.repository)

        let result = try await GitQueryService().diff(GitDiffRequest(
            repositoryURL: fixture.repository,
            filePath: "base.txt",
            mode: .head,
            historicalCommit: firstHash
        ))

        let additions = result.hunks
            .flatMap(\.lines)
            .filter { $0.kind == .addition }
            .map(\.text)
        XCTAssertEqual(additions, ["+two"])
        XCTAssertEqual(result.parentState, .resolved(
            reference: "\(firstHash)^1",
            mergeBase: fixture.baseCommit
        ))
    }

    func testHistoricalDiffOfModifiedRenameKeepsOldPath() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try write(
            "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\n",
            to: "before.txt",
            in: fixture.repository
        )
        try git(["add", "before.txt"], in: fixture.repository)
        try commit("setup", in: fixture.repository)
        try git(["checkout", "-b", "feature"], in: fixture.repository)
        try git(["mv", "before.txt", "after.txt"], in: fixture.repository)
        try write(
            "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\n",
            to: "after.txt",
            in: fixture.repository
        )
        try git(["add", "."], in: fixture.repository)
        try commit("feat: rename", in: fixture.repository)
        let commitHash = try gitOutput(["rev-parse", "HEAD"], in: fixture.repository)

        let result = try await GitQueryService().diff(GitDiffRequest(
            repositoryURL: fixture.repository,
            filePath: "after.txt",
            mode: .head,
            historicalCommit: commitHash,
            historicalOldPath: "before.txt"
        ))

        XCTAssertEqual(result.oldPath, "before.txt")
        XCTAssertEqual(result.newPath, "after.txt")
        let additions = result.hunks
            .flatMap(\.lines)
            .filter { $0.kind == .addition }
            .map(\.text)
        XCTAssertEqual(additions, ["+line9"])
    }

    // MARK: - Snapshot tabs

    @MainActor
    func testOpenGitHistorySnapshotCreatesReadOnlyPreviewWithHistoricalContext() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let workspace = WorkspaceModel(arguments: ["DevHQ"], gitQuery: GitQueryService())
        workspace.openWorkspace(fixture.repository)
        let commitInfo = GitHistoryCommit(
            hash: fixture.baseCommit,
            shortHash: String(fixture.baseCommit.prefix(7)),
            date: "2026-09-17",
            author: "DevHQ Tests",
            subject: "base"
        )
        let change = GitFileChange(path: "base.txt", oldPath: "old.txt", kind: .renamed)

        workspace.openGitHistorySnapshot(
            repositoryURL: workspace.rootURL!,
            commit: commitInfo,
            change: change,
            text: "base\n",
            asPreview: true
        )

        let document = try XCTUnwrap(workspace.selectedDocument)
        XCTAssertTrue(document.isReadOnly)
        XCTAssertTrue(document.isEphemeral)
        XCTAssertEqual(document.text, "base\n")
        XCTAssertEqual(document.treeNodeID, "git-history:\(fixture.baseCommit):base.txt")
        XCTAssertEqual(document.historicalContext?.commitID, fixture.baseCommit)
        XCTAssertEqual(document.historicalContext?.oldPath, "old.txt")
        XCTAssertEqual(document.historicalContext?.newPath, "base.txt")

        let configuration = try XCTUnwrap(workspace.diffEditorConfiguration(for: document))
        XCTAssertEqual(
            configuration.context.historicalContext?.commitID,
            fixture.baseCommit
        )
        XCTAssertEqual(configuration.context.historicalContext?.oldPath, "old.txt")

        // Re-opening the same snapshot persistently promotes the existing tab.
        workspace.openGitHistorySnapshot(
            repositoryURL: workspace.rootURL!,
            commit: commitInfo,
            change: change,
            text: "base\n",
            asPreview: false
        )
        XCTAssertEqual(workspace.documents.count, 1)
        XCTAssertFalse(document.isEphemeral)
    }

    @MainActor
    func testOpenGitHistorySnapshotIgnoresStaleRepository() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(fixture.repository)

        workspace.openGitHistorySnapshot(
            repositoryURL: fixture.container,
            commit: GitHistoryCommit(
                hash: "deadbeef",
                shortHash: "deadbee",
                date: "",
                author: "",
                subject: ""
            ),
            change: GitFileChange(path: "base.txt", kind: .modified),
            text: "stale\n",
            asPreview: true
        )

        XCTAssertTrue(workspace.documents.isEmpty)
    }

    // MARK: - Toggle state

    @MainActor
    func testToggleCommandFlipsHistoryPaneAndRequiresWorkspace() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let manager = CommandManager()
        try registerBuiltInCommands(
            in: manager,
            workspace: workspace,
            worktreeExplorer: WorktreeExplorerModel(
                discoverer: GitHistoryTestDiscoverer(),
                onActivate: { _, _ in },
                watcherFactory: { _, _ in GitHistoryTestWatcher() },
                eventDelivery: { $0() }
            ),
            pickers: BuiltInCommandPickers(
                repositoryURL: { nil },
                fileURL: { _ in nil },
                directoryURL: { _ in nil }
            )
        )
        let command = try XCTUnwrap(manager.commandsByID["devhq:toggle-git-history"])
        XCTAssertEqual(command.viewKinds, Set(CommandViewKind.allCases))

        XCTAssertThrowsError(
            try manager.execute(id: "devhq:toggle-git-history", in: CommandContext(view: .file))
        ) { error in
            XCTAssertEqual(
                error as? CommandManagerError,
                .commandUnavailable("devhq:toggle-git-history")
            )
        }

        workspace.openWorkspace(fixture.repository)
        XCTAssertFalse(workspace.gitHistory.isActive)
        try manager.execute(id: "devhq:toggle-git-history", in: CommandContext(view: .file))
        XCTAssertTrue(workspace.gitHistory.isActive)
        try manager.execute(id: "devhq:toggle-git-history", in: CommandContext(view: .document))
        XCTAssertFalse(workspace.gitHistory.isActive)
    }

    @MainActor
    func testHistoryModelLoadsCommitsAndFilesForActiveWorktree() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try git(["checkout", "-b", "feature"], in: fixture.repository)
        try write("first\n", to: "first.txt", in: fixture.repository)
        try git(["add", "first.txt"], in: fixture.repository)
        try commit("feat: first", in: fixture.repository)
        let commitHash = try gitOutput(["rev-parse", "HEAD"], in: fixture.repository)

        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(fixture.repository)
        let model = workspace.gitHistory
        model.toggle()
        XCTAssertTrue(model.isActive)

        try await waitUntil("commit list loads") {
            model.tree.roots.first?.id == commitHash
        }
        let commitNode = try XCTUnwrap(model.tree.roots.first)
        guard case .commit(let commitValue) = commitNode.value else {
            return XCTFail("Expected a commit node")
        }
        XCTAssertEqual(commitValue.label, "feat: first - \(commitValue.shortHash) - \(commitValue.date)")

        model.toggleNode(commitNode)
        XCTAssertTrue(model.tree.isExpanded(commitNode))
        try await waitUntil("commit files load") {
            guard let children = model.tree.roots.first?.children,
                  let first = children.first else { return false }
            if case .file = first.value { return true }
            return false
        }
        let fileNode = try XCTUnwrap(model.tree.roots.first?.children?.first)
        guard case let .file(_, change) = fileNode.value else {
            return XCTFail("Expected a file node")
        }
        XCTAssertEqual(change.path, "first.txt")
        XCTAssertEqual(change.kind, .added)
        XCTAssertEqual(change.additions, 1)

        // Tooltips upgrade asynchronously from "hash\nauthor" to the full log.
        XCTAssertEqual(
            model.commitTooltip(for: commitValue),
            "\(commitValue.hash)\n\(commitValue.author)"
        )
        model.requestCommitLog(for: commitValue)
        try await waitUntil("commit log loads") {
            model.commitLogs[commitValue.hash] != nil
        }
        XCTAssertTrue(model.commitTooltip(for: commitValue).contains("feat: first"))

        model.toggle()
        XCTAssertFalse(model.isActive)
    }

    @MainActor
    func testHistoryPaneReloadsWhenBranchRefChanges() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try git(["checkout", "-b", "feature"], in: fixture.repository)
        try write("first\n", to: "first.txt", in: fixture.repository)
        try git(["add", "first.txt"], in: fixture.repository)
        try commit("feat: first", in: fixture.repository)

        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(fixture.repository)
        let model = workspace.gitHistory
        model.toggle()
        try await waitUntil("initial history loads") {
            model.tree.roots.count == 1 && !model.isLoading
        }
        // The watcher installs asynchronously after activation.
        try await Task.sleep(nanoseconds: 500_000_000)

        try write("second\n", to: "second.txt", in: fixture.repository)
        try git(["add", "second.txt"], in: fixture.repository)
        try commit("feat: second", in: fixture.repository)

        try await waitUntil("history refreshes after new commit") {
            model.tree.roots.count == 2
        }
        guard case .commit(let newest)? = model.tree.roots.first?.value else {
            return XCTFail("Expected a commit node")
        }
        XCTAssertEqual(newest.subject, "feat: second")
        model.toggle()
    }

    // MARK: - Helpers

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private struct Fixture {
        let container: URL
        let repository: URL
        let baseCommit: String
    }

    private func makeFixture() throws -> Fixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try gitRaw(["init", "-b", "main", repository.path])
        try git(["config", "user.email", "devhq@example.invalid"], in: repository)
        try git(["config", "user.name", "DevHQ Tests"], in: repository)
        try write("base\n", to: "base.txt", in: repository)
        try git(["add", "base.txt"], in: repository)
        try commit("base", in: repository)
        let baseCommit = try gitOutput(["rev-parse", "HEAD"], in: repository)
        return Fixture(container: container, repository: repository, baseCommit: baseCommit)
    }

    private func write(_ text: String, to name: String, in repository: URL) throws {
        try text.write(
            to: repository.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    private func commit(_ message: String, in repository: URL) throws {
        try git(["commit", "-m", message, "--no-gpg-sign"], in: repository)
    }

    private func git(_ arguments: [String], in repository: URL) throws {
        try gitRaw(["-C", repository.path] + arguments)
    }

    private func gitOutput(_ arguments: [String], in repository: URL) throws -> String {
        try gitRaw(["-C", repository.path] + arguments, captureOutput: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func gitRaw(_ arguments: [String], captureOutput: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GitQueryError.commandFailed(arguments: arguments, message: text)
        }
        return captureOutput ? text : ""
    }
}

private struct GitHistoryTestDiscoverer: GitWorktreeDiscovering {
    func discover(at url: URL) throws -> GitRepositoryInfo {
        throw CocoaError(.fileNoSuchFile)
    }
}

private final class GitHistoryTestWatcher: RepositoryWatching {
    func cancel() {}
}

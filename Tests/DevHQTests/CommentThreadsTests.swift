import Foundation
import XCTest
@testable import DevHQ

final class CommentThreadsTests: XCTestCase {
    private var container: URL!
    private var repository: URL!
    private var configDirectory: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        repository = container.appendingPathComponent("repository", isDirectory: true)
        configDirectory = container.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try gitRaw(["init", "-b", "main", repository.path])
        try git(["config", "user.email", "devhq@example.invalid"])
        try git(["config", "user.name", "DevHQ Tests"])
        try "line one\nline two\nline three\n".write(
            to: repository.appendingPathComponent("base.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "base.txt"])
        try git(["commit", "-m", "base", "--no-gpg-sign"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
        configDirectory = nil
        repository = nil
        container = nil
    }

    // MARK: - Commit anchoring

    func testCommitAnchoringUsesHeadForCleanFilesAndUncommittedForDirtyOnes() throws {
        let head = try gitOutput(["rev-parse", "HEAD"])
        XCTAssertEqual(
            CommentGit.commitForFile(worktreePath: repository.path, relativePath: "base.txt"),
            head
        )

        try "changed\n".write(
            to: repository.appendingPathComponent("base.txt"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            CommentGit.commitForFile(worktreePath: repository.path, relativePath: "base.txt"),
            "uncommitted"
        )

        try "new\n".write(
            to: repository.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            CommentGit.commitForFile(worktreePath: repository.path, relativePath: "untracked.txt"),
            "uncommitted"
        )
        XCTAssertEqual(CommentGit.headCommit(worktreePath: repository.path), head)
    }

    // MARK: - Controller

    @MainActor
    private func makeController() -> (WorkspaceModel, CommentThreadsController) {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(repository)
        let controller = CommentThreadsController(
            workspace: workspace,
            store: CommentStore(configDirectory: configDirectory)
        )
        return (workspace, controller)
    }

    @MainActor
    func testAddThreadCreatesDraftWithV1IDAndPersistsWithMeta() throws {
        let (workspace, controller) = makeController()
        let before = Int(Date().timeIntervalSince1970)
        let thread = controller.addThread(
            relativePath: "base.txt",
            range: CommentRange(
                start: CommentPosition(line: 2, col: 3),
                end: CommentPosition(line: 3, col: 1)
            )
        )
        let after = Int(Date().timeIntervalSince1970)

        XCTAssertTrue(thread.id.hasSuffix(":base.txt:2:3"))
        let seconds = Int(thread.id.split(separator: ":").first.map(String.init) ?? "")
        XCTAssertNotNil(seconds)
        XCTAssertTrue((before...after).contains(seconds ?? 0))
        XCTAssertEqual(thread.state, .draft)
        XCTAssertEqual(thread.commit, try gitOutput(["rev-parse", "HEAD"]))
        XCTAssertEqual(thread.messages.count, 1)
        XCTAssertEqual(thread.messages[0].state, .draft)
        XCTAssertTrue(controller.isSidebarVisible)

        let root = try XCTUnwrap(workspace.rootURL)
        let store = CommentStore(configDirectory: configDirectory)
        let fileURL = store.commentsFileURL(forWorktreePath: root.path)
        XCTAssertEqual(store.metaWorktreePath(of: fileURL), root.path)
        XCTAssertEqual(store.loadThreads(from: fileURL).map(\.id), [thread.id])
    }

    @MainActor
    func testCommitOverlaySemantics() throws {
        let (_, controller) = makeController()
        let range = CommentRange(
            start: CommentPosition(line: 1, col: 1),
            end: CommentPosition(line: 1, col: 4)
        )
        let thread = controller.addThread(relativePath: "base.txt", range: range)

        // Draft: input replaces the first message body; the thread stays draft.
        controller.commitOverlay(threadID: thread.id, input: "needs a guard")
        var saved = try XCTUnwrap(controller.thread(id: thread.id))
        XCTAssertEqual(saved.state, .draft)
        XCTAssertEqual(saved.messages.map(\.body), ["needs a guard"])

        // Posting promotes drafts to open.
        controller.markPosted(threadIDs: [thread.id])
        saved = try XCTUnwrap(controller.thread(id: thread.id))
        XCTAssertEqual(saved.state, .open)
        XCTAssertEqual(saved.messages.map(\.state), [.open])

        // Open: a non-empty input appends a draft user message.
        controller.commitOverlay(threadID: thread.id, input: "second thought")
        saved = try XCTUnwrap(controller.thread(id: thread.id))
        XCTAssertEqual(saved.messages.count, 2)
        XCTAssertEqual(saved.messages[1].body, "second thought")
        XCTAssertEqual(saved.messages[1].state, .draft)
        XCTAssertEqual(saved.messages[1].author, .user)

        // Empty input on an existing thread changes nothing.
        controller.commitOverlay(threadID: thread.id, input: "")
        XCTAssertEqual(controller.thread(id: thread.id)?.messages.count, 2)

        // Resolve marks the thread and every open message resolved.
        controller.markPosted(threadIDs: [thread.id])
        controller.resolveThread(id: thread.id)
        saved = try XCTUnwrap(controller.thread(id: thread.id))
        XCTAssertEqual(saved.state, .resolved)
        XCTAssertEqual(saved.messages.map(\.state), [.resolved, .resolved])

        // Replying to a resolved thread reopens it.
        controller.commitOverlay(threadID: thread.id, input: "still broken")
        saved = try XCTUnwrap(controller.thread(id: thread.id))
        XCTAssertEqual(saved.state, .open)
        XCTAssertEqual(saved.messages.count, 3)
        XCTAssertEqual(saved.messages[2].state, .draft)
    }

    @MainActor
    func testCancellingJustCreatedThreadWithEmptyInputDeletesIt() throws {
        let (_, controller) = makeController()
        let range = CommentRange(
            start: CommentPosition(line: 1, col: 1),
            end: CommentPosition(line: 1, col: 2)
        )
        let thread = controller.addThread(relativePath: "base.txt", range: range)

        controller.cancelOverlay(threadID: thread.id, created: false, input: "")
        XCTAssertNotNil(controller.thread(id: thread.id))

        controller.cancelOverlay(threadID: thread.id, created: true, input: "kept")
        XCTAssertNotNil(controller.thread(id: thread.id))

        controller.cancelOverlay(threadID: thread.id, created: true, input: "")
        XCTAssertNil(controller.thread(id: thread.id))
        XCTAssertEqual(controller.threads, [])
    }

    @MainActor
    func testExternalChangesReloadUnlessAnOverlayIsOpen() throws {
        let (workspace, controller) = makeController()
        controller.ensureLoaded()
        XCTAssertEqual(controller.threads, [])

        // Another process (the reply CLI, v1) rewrites the JSONL.
        let root = try XCTUnwrap(workspace.rootURL)
        let store = CommentStore(configDirectory: configDirectory)
        let fileURL = store.commentsFileURL(forWorktreePath: root.path)
        let external = CommentThread(
            id: "1:base.txt:1:1",
            worktree: root.path,
            file: "base.txt",
            commit: "uncommitted",
            state: .open,
            range: CommentRange(
                start: CommentPosition(line: 1, col: 1),
                end: CommentPosition(line: 1, col: 2)
            ),
            messages: [CommentMessage(author: .user, body: "external", state: .open)],
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )
        try store.save([external], worktreePath: root.path, to: fileURL)

        controller.overlayWillOpen()
        controller.checkForExternalChanges()
        XCTAssertEqual(controller.threads, [], "no reload while an overlay is open")

        controller.overlayDidClose()
        controller.checkForExternalChanges()
        XCTAssertEqual(controller.threads.map(\.id), ["1:base.txt:1:1"])
    }

    @MainActor
    func testSidebarOrderingSortsByFileThenStartLine() throws {
        let (_, controller) = makeController()
        controller.addThread(
            relativePath: "b.txt",
            range: CommentRange(
                start: CommentPosition(line: 4, col: 1),
                end: CommentPosition(line: 4, col: 2)
            )
        )
        controller.addThread(
            relativePath: "a.txt",
            range: CommentRange(
                start: CommentPosition(line: 9, col: 1),
                end: CommentPosition(line: 9, col: 2)
            )
        )
        controller.addThread(
            relativePath: "a.txt",
            range: CommentRange(
                start: CommentPosition(line: 2, col: 1),
                end: CommentPosition(line: 2, col: 2)
            )
        )
        XCTAssertEqual(
            controller.sortedThreads.map { "\($0.file):\($0.range.start.line)" },
            ["a.txt:2", "a.txt:9", "b.txt:4"]
        )
    }

    @MainActor
    func testPostToTextOpensReadOnlyBlobTabAndMarksMessagesOpen() throws {
        let (workspace, controller) = makeController()
        let thread = controller.addThread(
            relativePath: "base.txt",
            range: CommentRange(
                start: CommentPosition(line: 1, col: 1),
                end: CommentPosition(line: 2, col: 3)
            )
        )
        controller.commitOverlay(threadID: thread.id, input: "tighten this loop")
        XCTAssertEqual(controller.postableThreads().map(\.id), [thread.id])

        try controller.post(
            controller.postableThreads(),
            to: CommentThreadsController.PostTarget(label: "text", session: nil)
        )

        let document = try XCTUnwrap(workspace.selectedDocument)
        XCTAssertTrue(document.isReadOnly)
        XCTAssertTrue(document.text.hasPrefix("Review comments for \(workspace.rootURL!.path)"))
        XCTAssertTrue(document.text.contains("comment \(thread.id)"))
        XCTAssertTrue(document.text.contains("  you: tighten this loop"))

        let saved = try XCTUnwrap(controller.thread(id: thread.id))
        XCTAssertEqual(saved.state, .open)
        XCTAssertEqual(saved.messages.map(\.state), [.open])
        XCTAssertEqual(controller.postableThreads(), [])
    }

    // MARK: - Blob formatting

    func testBlobFormatMatchesV1() {
        let thread = CommentThread(
            id: "1758000000:src/a.swift:3:2",
            worktree: "/tmp/wt",
            file: "src/a.swift",
            commit: "uncommitted",
            state: .draft,
            range: CommentRange(
                start: CommentPosition(line: 3, col: 2),
                end: CommentPosition(line: 4, col: 5)
            ),
            messages: [
                CommentMessage(author: .user, body: "first note", state: .draft),
                CommentMessage(author: .agent, body: "on it", state: .open)
            ],
            createdAt: nil,
            updatedAt: nil
        )

        let blob = CommentThreadsController.blob(
            for: [thread],
            worktreePath: "/tmp/wt",
            cliInvocation: "'/apps/DevHQ'"
        )

        XCTAssertEqual(blob, """
        Review comments for /tmp/wt

        comment 1758000000:src/a.swift:3:2
          src/a.swift:3:2-4:5 [uncommitted]
          you: first note
          agent: on it

        To respond to a comment, run the DevHQ review CLI with the comment id shown above:
          '/apps/DevHQ' review reply <comment-id> --message "your reply"
        This appends your reply to that thread; the reviewer sees it in the DevHQ review sidebar.
        """)
    }

    func testCLIInvocationIncludesConfigDirOverride() {
        XCTAssertEqual(
            CommentThreadsController.cliInvocation(
                environment: ["DEVHQ_CONFIG_DIR": "/custom dir"],
                executablePath: "/apps/DevHQ"
            ),
            "DEVHQ_CONFIG_DIR='/custom dir' '/apps/DevHQ'"
        )
        XCTAssertEqual(
            CommentThreadsController.cliInvocation(environment: [:], executablePath: "/apps/DevHQ"),
            "'/apps/DevHQ'"
        )
    }

    // MARK: - Labels and resolve semantics on the model

    func testCommentLabelTruncatesLongBodies() {
        var thread = CommentThread(
            id: "x",
            worktree: "/tmp/wt",
            file: "a.swift",
            commit: "uncommitted",
            state: .open,
            range: CommentRange(
                start: CommentPosition(line: 7, col: 2),
                end: CommentPosition(line: 7, col: 9)
            ),
            messages: [
                CommentMessage(
                    author: .user,
                    body: "  wraps \n whitespace " + String(repeating: "y", count: 80),
                    state: .open
                )
            ],
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertTrue(thread.label.hasPrefix("a.swift:7:2 wraps whitespace"))
        XCTAssertTrue(thread.label.hasSuffix("..."))

        thread.messages[0].body = "short"
        XCTAssertEqual(thread.label, "a.swift:7:2 short")
    }

    func testResolveOnlyTouchesOpenMessages() {
        var thread = CommentThread(
            id: "x",
            worktree: "/tmp/wt",
            file: "a.swift",
            commit: "uncommitted",
            state: .open,
            range: CommentRange(
                start: CommentPosition(line: 1, col: 1),
                end: CommentPosition(line: 1, col: 2)
            ),
            messages: [
                CommentMessage(author: .user, body: "a", state: .open, updatedAt: "old"),
                CommentMessage(author: .user, body: "b", state: .draft, updatedAt: "old"),
                CommentMessage(author: .agent, body: "c", state: .resolved, updatedAt: "old")
            ],
            createdAt: nil,
            updatedAt: "old"
        )
        thread.resolve(now: "new")
        XCTAssertEqual(thread.state, .resolved)
        XCTAssertEqual(thread.updatedAt, "new")
        XCTAssertEqual(thread.messages.map(\.state), [.resolved, .draft, .resolved])
        XCTAssertEqual(thread.messages.map(\.updatedAt), ["new", "old", "old"])
    }

    // MARK: - Command registration

    @MainActor
    func testReviewCommandsRegisterWithExpectedScopesAndErrors() throws {
        let (workspace, controller) = makeController()
        let manager = CommandManager()
        try registerReviewCommentCommands(
            in: manager,
            workspace: workspace,
            comments: controller,
            pickers: ReviewCommentPickers(choose: { _, _, options in options.first })
        )

        XCTAssertEqual(Set(manager.commandsByID.keys), [
            "devhq:add-comment", "devhq:resolve-comment",
            "devhq:post-all-comments", "devhq:toggle-review-sidebar"
        ])
        for command in manager.commandsByID.values {
            XCTAssertEqual(command.viewKinds, Set(CommandViewKind.allCases), command.id)
        }

        let context = CommandContext(view: .document, worktreeURL: workspace.rootURL)

        XCTAssertThrowsError(try manager.execute(id: "devhq:add-comment", in: context)) {
            XCTAssertEqual($0 as? ReviewCommentError, ReviewCommentError("No active document"))
        }
        XCTAssertThrowsError(try manager.execute(id: "devhq:resolve-comment", in: context)) {
            XCTAssertEqual($0 as? ReviewCommentError, ReviewCommentError("No open comments"))
        }
        XCTAssertThrowsError(try manager.execute(id: "devhq:post-all-comments", in: context)) {
            XCTAssertEqual(
                $0 as? ReviewCommentError,
                ReviewCommentError("No draft comments to post")
            )
        }

        XCTAssertFalse(controller.isSidebarVisible)
        try manager.execute(id: "devhq:toggle-review-sidebar", in: context)
        XCTAssertTrue(controller.isSidebarVisible)
        try manager.execute(id: "devhq:toggle-review-sidebar", in: context)
        XCTAssertFalse(controller.isSidebarVisible)

        // With an open thread, resolve picks through the injected picker.
        let thread = controller.addThread(
            relativePath: "base.txt",
            range: CommentRange(
                start: CommentPosition(line: 1, col: 1),
                end: CommentPosition(line: 1, col: 2)
            )
        )
        controller.commitOverlay(threadID: thread.id, input: "note")
        controller.markPosted(threadIDs: [thread.id])
        try manager.execute(id: "devhq:resolve-comment", in: context)
        XCTAssertEqual(controller.thread(id: thread.id)?.state, .resolved)
    }
}

// MARK: - Git helpers

private extension CommentThreadsTests {
    func git(_ arguments: [String]) throws {
        try gitRaw(["-C", repository.path] + arguments)
    }

    func gitOutput(_ arguments: [String]) throws -> String {
        try gitRaw(["-C", repository.path] + arguments, captureOutput: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func gitRaw(_ arguments: [String], captureOutput: Bool = false) throws -> String {
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

import Foundation
import XCTest
@testable import DevHQ

final class CommentStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var configDirectory: URL!
    private var store: CommentStore!

    /// One thread exactly as DevHQ v1's Lua encoder writes it: sorted keys,
    /// compact separators, unescaped slashes.
    private static let v1ThreadLine = "{\"commit\":\"uncommitted\",\"created_at\":\"2026-01-02T03:04:05Z\","
        + "\"file\":\"src/main.lua\",\"id\":\"1758000000:src/main.lua:3:2\","
        + "\"messages\":[{\"author\":\"user\",\"body\":\"first note\","
        + "\"created_at\":\"2026-01-02T03:04:05Z\",\"state\":\"draft\","
        + "\"updated_at\":\"2026-01-02T03:04:05Z\"}],"
        + "\"range\":{\"end\":{\"col\":5,\"line\":4},\"start\":{\"col\":2,\"line\":3}},"
        + "\"state\":\"draft\",\"updated_at\":\"2026-01-02T03:04:05Z\",\"worktree\":\"/tmp/wt\"}"

    private static let v1MetaLine = "{\"type\":\"meta\",\"worktree\":\"/tmp/wt\"}"

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        configDirectory = temporaryDirectory.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory.appendingPathComponent("ws", isDirectory: true),
            withIntermediateDirectories: true
        )
        store = CommentStore(configDirectory: configDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        store = nil
        configDirectory = nil
        temporaryDirectory = nil
    }

    func testDefaultDirectoryHonorsConfigOverride() {
        let overridden = CommentStore(environment: ["DEVHQ_CONFIG_DIR": "/custom/devhq"])
        XCTAssertEqual(overridden.wsDirectory.path, "/custom/devhq/ws")

        let fallback = CommentStore(environment: [:])
        XCTAssertEqual(
            fallback.wsDirectory,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/devhq/ws", isDirectory: true)
        )
    }

    func testV1FileRoundTripsByteCompatibly() throws {
        let fileURL = store.wsDirectory.appendingPathComponent("wt-devhq-comments-1.jsonl")
        let original = Self.v1MetaLine + "\n" + Self.v1ThreadLine + "\n"
        try Data(original.utf8).write(to: fileURL)

        let threads = store.loadThreads(from: fileURL, worktreePath: "/tmp/wt")
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].id, "1758000000:src/main.lua:3:2")
        XCTAssertEqual(threads[0].state, .draft)
        XCTAssertEqual(threads[0].commit, "uncommitted")
        XCTAssertEqual(threads[0].file, "src/main.lua")
        XCTAssertEqual(
            threads[0].range,
            CommentRange(
                start: CommentPosition(line: 3, col: 2),
                end: CommentPosition(line: 4, col: 5)
            )
        )
        XCTAssertEqual(threads[0].messages.count, 1)
        XCTAssertEqual(threads[0].messages[0].body, "first note")
        XCTAssertEqual(threads[0].messages[0].state, .draft)

        try store.save(threads, worktreePath: "/tmp/wt", to: fileURL)
        let rewritten = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(rewritten, original)
    }

    func testMetaLineMatchesV1Format() throws {
        let fileURL = store.wsDirectory.appendingPathComponent("wt-devhq-comments-1.jsonl")
        try store.save([], worktreePath: "/tmp/wt", to: fileURL)
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(contents, Self.v1MetaLine + "\n")
        XCTAssertEqual(store.metaWorktreePath(of: fileURL), "/tmp/wt")
    }

    func testLegacyBodyAndRepliesShapeMigratesToMessages() throws {
        let legacy = "{\"body\":\"original comment\",\"commit\":\"abc123\","
            + "\"created_at\":\"2026-01-01T00:00:00Z\",\"file\":\"a.swift\",\"id\":\"legacy:a.swift:1:1\","
            + "\"range\":{\"end\":{\"col\":2,\"line\":1},\"start\":{\"col\":1,\"line\":1}},"
            + "\"replies\":[{\"author\":\"agent\",\"body\":\"done\",\"state\":\"open\"}],"
            + "\"state\":\"resolved\",\"updated_at\":\"2026-01-01T00:00:00Z\",\"worktree\":\"/tmp/wt\"}"
        let fileURL = store.wsDirectory.appendingPathComponent("wt-devhq-comments-1.jsonl")
        try Data((Self.v1MetaLine + "\n" + legacy + "\n").utf8).write(to: fileURL)

        let threads = store.loadThreads(from: fileURL, worktreePath: "/tmp/wt")
        XCTAssertEqual(threads.count, 1)
        let thread = threads[0]
        XCTAssertEqual(thread.state, .resolved)
        XCTAssertEqual(thread.messages.count, 2)
        XCTAssertEqual(thread.messages[0].author, .user)
        XCTAssertEqual(thread.messages[0].body, "original comment")
        // Resolved threads force open messages to resolved (v1 normalize_thread).
        XCTAssertEqual(thread.messages[0].state, .resolved)
        XCTAssertEqual(thread.messages[1].author, .agent)
        XCTAssertEqual(thread.messages[1].body, "done")
        XCTAssertEqual(thread.messages[1].state, .resolved)
    }

    func testThreadWithoutMessagesGainsEmptyDraftMessage() throws {
        let bare = "{\"commit\":\"uncommitted\",\"file\":\"a.swift\",\"id\":\"bare:a.swift:1:1\","
            + "\"range\":{\"end\":{\"col\":2,\"line\":1},\"start\":{\"col\":1,\"line\":1}},"
            + "\"state\":\"draft\",\"worktree\":\"/tmp/wt\"}"
        let threads = CommentStore.parseThreads(Data((bare + "\n").utf8))
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].messages.count, 1)
        XCTAssertEqual(threads[0].messages[0].body, "")
        XCTAssertEqual(threads[0].messages[0].state, .draft)
    }

    func testInvalidLinesAreSkipped() throws {
        let data = Data("not json\n{\"no\":\"id\"}\n\(Self.v1ThreadLine)\n".utf8)
        let threads = CommentStore.parseThreads(data)
        XCTAssertEqual(threads.map(\.id), ["1758000000:src/main.lua:3:2"])
    }

    func testFileLookupFindsMatchingMetaAndAllocatesLowestUnusedIndex() throws {
        let worktreeA = "/repos/wt"
        let worktreeB = "/elsewhere/wt"

        // First allocation starts at 1.
        XCTAssertEqual(
            store.commentsFileURL(forWorktreePath: worktreeA).lastPathComponent,
            "wt-devhq-comments-1.jsonl"
        )

        // A file with a different worktree in its meta occupies index 1.
        let fileB = store.wsDirectory.appendingPathComponent("wt-devhq-comments-1.jsonl")
        try store.save([], worktreePath: worktreeB, to: fileB)
        XCTAssertEqual(
            store.commentsFileURL(forWorktreePath: worktreeA).lastPathComponent,
            "wt-devhq-comments-2.jsonl"
        )
        XCTAssertEqual(store.commentsFileURL(forWorktreePath: worktreeB), fileB)

        // Once a matching file exists it is always found again.
        let fileA = store.wsDirectory.appendingPathComponent("wt-devhq-comments-7.jsonl")
        try store.save([], worktreePath: worktreeA, to: fileA)
        XCTAssertEqual(store.commentsFileURL(forWorktreePath: worktreeA), fileA)
    }

    func testFileNamePatternRequiresBasenameAndNumericSuffix() {
        XCTAssertEqual(
            CommentStore.index(ofFileName: "wt-devhq-comments-12.jsonl", worktreeBasename: "wt"),
            12
        )
        XCTAssertNil(
            CommentStore.index(ofFileName: "other-devhq-comments-1.jsonl", worktreeBasename: "wt")
        )
        XCTAssertNil(
            CommentStore.index(ofFileName: "wt-devhq-comments-.jsonl", worktreeBasename: "wt")
        )
        XCTAssertNil(
            CommentStore.index(ofFileName: "wt-devhq-comments-1.json", worktreeBasename: "wt")
        )
    }

    func testSaveLeavesNoTemporaryFileBehind() throws {
        let fileURL = store.wsDirectory.appendingPathComponent("wt-devhq-comments-1.jsonl")
        try store.save([], worktreePath: "/tmp/wt", to: fileURL)
        try store.save([], worktreePath: "/tmp/wt", to: fileURL)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.wsDirectory.path)
        XCTAssertEqual(names, ["wt-devhq-comments-1.jsonl"])
    }
}

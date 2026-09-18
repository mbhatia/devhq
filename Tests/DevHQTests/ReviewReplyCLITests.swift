import Foundation
import XCTest
@testable import DevHQ

final class ReviewReplyCLITests: XCTestCase {
    private var temporaryDirectory: URL!
    private var configDirectory: URL!
    private var wsDirectory: URL!
    private var environment: [String: String]!

    private let threadID = "1758000000:src/main.lua:3:2"

    private var threadLine: String {
        "{\"commit\":\"uncommitted\",\"created_at\":\"2026-01-02T03:04:05Z\","
            + "\"file\":\"src/main.lua\",\"id\":\"\(threadID)\","
            + "\"messages\":[{\"author\":\"user\",\"body\":\"first note\","
            + "\"created_at\":\"2026-01-02T03:04:05Z\",\"state\":\"open\","
            + "\"updated_at\":\"2026-01-02T03:04:05Z\"}],"
            + "\"range\":{\"end\":{\"col\":5,\"line\":4},\"start\":{\"col\":2,\"line\":3}},"
            + "\"state\":\"open\",\"updated_at\":\"2026-01-02T03:04:05Z\",\"worktree\":\"/tmp/wt\"}"
    }

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        configDirectory = temporaryDirectory.appendingPathComponent("config", isDirectory: true)
        wsDirectory = configDirectory.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: wsDirectory, withIntermediateDirectories: true)
        environment = ["DEVHQ_CONFIG_DIR": configDirectory.path]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        environment = nil
        wsDirectory = nil
        configDirectory = nil
        temporaryDirectory = nil
    }

    private func writeCommentsFile(
        named name: String = "wt-devhq-comments-1.jsonl",
        lines: [String]
    ) throws -> URL {
        let fileURL = wsDirectory.appendingPathComponent(name)
        try Data((["{\"type\":\"meta\",\"worktree\":\"/tmp/wt\"}"] + lines)
            .joined(separator: "\n")
            .appending("\n").utf8
        ).write(to: fileURL)
        return fileURL
    }

    private func run(
        _ arguments: [String],
        environment: [String: String]? = nil
    ) -> (status: Int32, output: [String], errors: [String]) {
        var output: [String] = []
        var errors: [String] = []
        let status = ReviewReplyCLI.run(
            arguments: arguments,
            environment: environment ?? self.environment,
            output: { output.append($0) },
            errorOutput: { errors.append($0) }
        )
        return (status, output, errors)
    }

    func testReplyAppendsAgentMessageAndPrintsReplyID() throws {
        let fileURL = try writeCommentsFile(lines: [threadLine])
        var environment = self.environment!
        environment["AGENT_ID"] = "agent-7"

        let result = run(
            ["devhq", "review", "reply", threadID, "--message", "will fix"],
            environment: environment
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, ["\(threadID):reply:2"])
        XCTAssertEqual(result.errors, [])

        let store = CommentStore(configDirectory: configDirectory)
        let threads = store.loadThreads(from: fileURL)
        XCTAssertEqual(threads.count, 1)
        let thread = threads[0]
        XCTAssertEqual(thread.messages.count, 2)
        let reply = thread.messages[1]
        XCTAssertEqual(reply.author, .agent)
        XCTAssertEqual(reply.body, "will fix")
        XCTAssertEqual(reply.state, .open)
        XCTAssertEqual(reply.id, "\(threadID):reply:2")
        XCTAssertEqual(reply.agentID, "agent-7")
        XCTAssertNotEqual(thread.updatedAt, "2026-01-02T03:04:05Z")

        // The rewrite is atomic: no temporary sibling remains and the meta
        // line survives.
        let names = try FileManager.default.contentsOfDirectory(atPath: wsDirectory.path)
        XCTAssertEqual(names.sorted(), ["wt-devhq-comments-1.jsonl"])
        XCTAssertEqual(store.metaWorktreePath(of: fileURL), "/tmp/wt")
    }

    func testReplyWithoutAgentIDOmitsAgentIDField() throws {
        let fileURL = try writeCommentsFile(lines: [threadLine])
        let result = run(["devhq", "review", "reply", threadID, "--message", "ok"])
        XCTAssertEqual(result.status, 0)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("agent_id"))
    }

    func testUnknownCommentIDFails() throws {
        _ = try writeCommentsFile(lines: [threadLine])
        let result = run(["devhq", "review", "reply", "nope", "--message", "hi"])
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.errors, ["devhq: comment not found: nope"])
    }

    func testAmbiguousCommentIDFailsWithoutWriting() throws {
        let first = try writeCommentsFile(named: "wt-devhq-comments-1.jsonl", lines: [threadLine])
        let second = try writeCommentsFile(named: "wt2-devhq-comments-1.jsonl", lines: [threadLine])
        let firstBefore = try Data(contentsOf: first)
        let secondBefore = try Data(contentsOf: second)

        let result = run(["devhq", "review", "reply", threadID, "--message", "hi"])

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.errors, ["devhq: comment id is ambiguous: \(threadID)"])
        XCTAssertEqual(try Data(contentsOf: first), firstBefore)
        XCTAssertEqual(try Data(contentsOf: second), secondBefore)
    }

    func testBadArgumentsPrintUsageAndExitTwo() {
        for arguments in [
            ["devhq", "review"],
            ["devhq", "review", "rply", "id", "--message", "hi"],
            ["devhq", "review", "reply"],
            ["devhq", "review", "reply", "id", "--bogus", "hi"],
            ["devhq", "review", "reply", "id", "--message", "a", "--message", "b"],
            ["devhq", "review", "reply", "id", "--message"]
        ] {
            let result = run(arguments)
            XCTAssertEqual(result.status, 2, "\(arguments)")
            XCTAssertEqual(result.errors, [ReviewReplyCLI.usage], "\(arguments)")
        }
    }

    func testMissingMessageFailsWithExitOne() {
        for arguments in [
            ["devhq", "review", "reply", "id"],
            ["devhq", "review", "reply", "id", "--message", ""]
        ] {
            let result = run(arguments)
            XCTAssertEqual(result.status, 1, "\(arguments)")
            XCTAssertEqual(result.errors, ["devhq: --message is required"], "\(arguments)")
        }
    }

    func testReviewInvocationDetection() {
        XCTAssertTrue(ReviewReplyCLI.isReviewInvocation(["devhq", "review", "reply", "x"]))
        XCTAssertTrue(ReviewReplyCLI.isReviewInvocation(["devhq", "review"]))
        XCTAssertFalse(ReviewReplyCLI.isReviewInvocation(["devhq"]))
        XCTAssertFalse(ReviewReplyCLI.isReviewInvocation(["devhq", "--workspace", "/tmp"]))
    }
}

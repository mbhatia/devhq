import Darwin
import Foundation
import XCTest
@testable import DevHQ

final class TerminalDrawerTests: XCTestCase {
    @MainActor
    func testToggleCreatesSessionOnFirstUseThenCollapsesAndReusesIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var spawnedDirectories: [URL] = []
        let drawer = TerminalDrawerModel { workingDirectory in
            spawnedDirectories.append(workingDirectory)
            return try TerminalSession(
                rootURL: workingDirectory,
                command: ["/bin/cat"]
            )
        }
        defer { drawer.terminate() }

        try drawer.toggle(activeWorktree: root)
        XCTAssertTrue(drawer.isVisible)
        let session = try XCTUnwrap(drawer.session)
        XCTAssertEqual(
            spawnedDirectories,
            [root.standardizedFileURL.resolvingSymlinksInPath()]
        )

        try drawer.toggle(activeWorktree: root)
        XCTAssertFalse(drawer.isVisible)
        XCTAssertEqual(drawer.session?.id, session.id)

        try drawer.toggle(activeWorktree: root)
        XCTAssertTrue(drawer.isVisible)
        XCTAssertEqual(drawer.session?.id, session.id)
        XCTAssertEqual(spawnedDirectories.count, 1)
    }

    @MainActor
    func testShowWithoutWorkspaceThrowsAndCreatesNothing() {
        let drawer = TerminalDrawerModel { workingDirectory in
            try TerminalSession(rootURL: workingDirectory, command: ["/bin/cat"])
        }

        XCTAssertThrowsError(try drawer.toggle(activeWorktree: nil)) { error in
            XCTAssertEqual(
                error as? WorkspaceCommandOperationError,
                .noWorkspace
            )
        }
        XCTAssertFalse(drawer.isVisible)
        XCTAssertNil(drawer.session)
    }

    @MainActor
    func testTerminateKillsShellAndNextToggleFollowsTheActiveWorktree() throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        var spawnedDirectories: [URL] = []
        let drawer = TerminalDrawerModel { workingDirectory in
            spawnedDirectories.append(workingDirectory)
            return try TerminalSession(
                rootURL: workingDirectory,
                command: ["/bin/cat"]
            )
        }
        defer { drawer.terminate() }

        try drawer.toggle(activeWorktree: first)
        let firstPID = try XCTUnwrap(drawer.session).processID

        drawer.terminate()
        XCTAssertFalse(drawer.isVisible)
        XCTAssertNil(drawer.session)
        XCTAssertEqual(kill(firstPID, 0), -1)

        try drawer.toggle(activeWorktree: second)
        XCTAssertTrue(drawer.isVisible)
        XCTAssertEqual(
            spawnedDirectories.map(\.path),
            [
                first.standardizedFileURL.resolvingSymlinksInPath().path,
                second.standardizedFileURL.resolvingSymlinksInPath().path
            ]
        )
    }

    @MainActor
    func testShowRejectsMissingWorkingDirectory() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let drawer = TerminalDrawerModel { workingDirectory in
            try TerminalSession(rootURL: workingDirectory, command: ["/bin/cat"])
        }

        XCTAssertThrowsError(try drawer.show(activeWorktree: missing)) { error in
            guard case .invalidTerminalWorkingDirectory = error
                as? WorkspaceCommandOperationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNil(drawer.session)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

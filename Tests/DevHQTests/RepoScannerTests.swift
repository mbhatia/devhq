import Foundation
import XCTest
@testable import DevHQ

final class RepoScannerTests: XCTestCase {
    func testScanFindsReposViaGitDirOrFileAndStopsDescendingAtRepoBoundaries() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // A repository with a nested repository inside it: only the outer one
        // is reported because the walk stops at the first repo on each path.
        let alpha = root.appendingPathComponent("alpha", isDirectory: true)
        try makeRepo(at: alpha, gitAsFile: false)
        try makeRepo(
            at: alpha.appendingPathComponent("nested", isDirectory: true),
            gitAsFile: false
        )

        // A linked-worktree style repository whose `.git` is a plain file,
        // nested below a non-repo directory.
        let gamma = root
            .appendingPathComponent("beta", isDirectory: true)
            .appendingPathComponent("gamma", isDirectory: true)
        try makeRepo(at: gamma, gitAsFile: true)

        // Plain directories without repositories are walked but not reported.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plain/subdir", isDirectory: true),
            withIntermediateDirectories: true
        )

        let found = try RepoScanner.scanRepositories(under: root)

        XCTAssertEqual(
            Set(found.map(\.lastPathComponent)),
            ["alpha", "gamma"]
        )
    }

    func testScanOfARepositoryRootReturnsOnlyThatRepository() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRepo(at: root, gitAsFile: false)
        try makeRepo(
            at: root.appendingPathComponent("vendored", isDirectory: true),
            gitAsFile: false
        )

        let found = try RepoScanner.scanRepositories(under: root)

        XCTAssertEqual(
            found.map(\.path),
            [root.standardizedFileURL.resolvingSymlinksInPath().path]
        )
    }

    func testScanSkipsSymlinkedDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try makeRepo(at: repo, gitAsFile: false)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: repo
        )

        let found = try RepoScanner.scanRepositories(under: root)

        XCTAssertEqual(found.map(\.lastPathComponent), ["repo"])
    }

    func testScanRejectsFilesAndMissingPaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("missing", isDirectory: true)

        XCTAssertThrowsError(try RepoScanner.scanRepositories(under: file)) { error in
            XCTAssertEqual(error as? RepoScannerError, .notADirectory(file))
        }
        XCTAssertThrowsError(try RepoScanner.scanRepositories(under: missing)) { error in
            XCTAssertEqual(error as? RepoScannerError, .notADirectory(missing))
        }
    }

    private func makeRepo(at url: URL, gitAsFile: Bool) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        let git = url.appendingPathComponent(".git")
        if gitAsFile {
            try "gitdir: /elsewhere/.git/worktrees/x\n"
                .write(to: git, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.createDirectory(
                at: git,
                withIntermediateDirectories: false
            )
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

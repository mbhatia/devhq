import Foundation

enum RepoScannerError: LocalizedError, Equatable {
    case notADirectory(URL)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            "\(url.path) is not a directory."
        }
    }
}

/// Recursive git repository discovery mirroring DevHQ v1's `git.scan_repos`:
/// the walk descends into plain directories and stops at any directory that
/// is itself a git repository, so worktrees and submodules nested inside a
/// found repository are not reported separately.
enum RepoScanner {
    static func scanRepositories(under directory: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw RepoScannerError.notADirectory(directory)
        }
        var found: [URL] = []
        scan(
            directory.standardizedFileURL.resolvingSymlinksInPath(),
            into: &found
        )
        return found
    }

    /// A repository root carries `.git` as either a directory (main worktree)
    /// or a file (linked worktree or submodule checkout).
    static func isRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".git").path
        )
    }

    private static func scan(_ directory: URL, into found: inout [URL]) {
        if isRepository(directory) {
            found.append(directory)
            return
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return }
        let subdirectories = children
            .filter { child in
                guard let values = try? child.resourceValues(forKeys: keys) else {
                    return false
                }
                return values.isSymbolicLink != true && values.isDirectory == true
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
        for child in subdirectories {
            scan(child, into: &found)
        }
    }
}

import Darwin
import Foundation

/// Folder rules for files only this user may reach. Mechanism only: each
/// caller turns a Failure into its own error text, because the remedy names
/// a different flag (--token-file, --socket-path).
enum PrivateFolder {
    enum Failure: Error, Equatable {
        /// ensure: the path exists but is not a folder.
        case notAFolder(path: String)
        /// ensure: the folder belongs to another user.
        case wrongOwner(path: String)
        /// requireOwned: the path is not a folder, or belongs to another user.
        case notOwnedFolder(path: String)
        /// requireOwned: nothing exists at the path.
        case missing(path: String)
        case io(path: String, operation: String, reason: String)

        static func posix(_ path: String, _ operation: String, _ code: Int32) -> Failure {
            .io(path: path, operation: operation, reason: String(cString: strerror(code)))
        }
    }

    /// Creates the folder 0700 when absent, requires a folder owned by the
    /// effective uid, and tightens a looser mode to 0700.
    static func ensure(_ path: String) throws(Failure) {
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw .io(path: path, operation: "create", reason: error.localizedDescription)
        }
        var info = stat()
        guard stat(path, &info) == 0 else { throw .posix(path, "stat", errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw .notAFolder(path: path) }
        guard info.st_uid == geteuid() else { throw .wrongOwner(path: path) }
        if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 {
            throw .posix(path, "chmod", errno)
        }
    }

    /// Requires an existing folder owned by the effective uid. Leaves its
    /// mode alone.
    static func requireOwned(_ path: String) throws(Failure) {
        var info = stat()
        guard stat(path, &info) == 0 else {
            if errno == ENOENT { throw .missing(path: path) }
            throw .posix(path, "find folder", errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            throw .notOwnedFolder(path: path)
        }
    }
}

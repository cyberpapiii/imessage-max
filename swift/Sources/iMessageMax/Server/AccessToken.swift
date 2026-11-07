import Darwin
import Foundation
import IMessageMaxContract
import Security

/// The bearer secret every HTTP request must present. It lives in a file only
/// the user can read, so another macOS user or a sandboxed process cannot
/// reach the messages the server exposes.
struct AccessToken: Sendable {
    enum LoadError: Error, CustomStringConvertible, Equatable {
        case insecurePermissions(path: String, mode: mode_t)
        case wrongOwner(path: String)
        case unsafeFolder(path: String)
        case notRegularFile(path: String)
        case malformed(path: String)
        case io(path: String, operation: String, reason: String)

        static func posix(_ path: String, _ operation: String, _ code: Int32) -> LoadError {
            .io(path: path, operation: operation, reason: String(cString: strerror(code)))
        }

        var description: String {
            switch self {
            case .insecurePermissions(let path, let mode):
                "Token file \(path) has mode \(String(mode & 0o777, radix: 8)). Other users could read it. Run `chmod 600 '\(path)'`, or delete it so the server creates a new one."
            case .wrongOwner(let path):
                "\(path) belongs to another user. Remove it, or pass --token-file with a path you own."
            case .unsafeFolder(let path):
                "Folder \(path) belongs to another user, or is not a folder. Pass --token-file with a path in a folder you own."
            case .notRegularFile(let path):
                "\(path) is a link or special file, not the expected file or folder. Remove it so the server can create the token."
            case .malformed(let path):
                "\(path) exists but does not hold an iMessage Max token, so the server left it alone. Pass --token-file with another path, or delete the file if it is a damaged token."
            case .io(let path, let operation, let reason):
                "Cannot \(operation) \(path): \(reason)"
            }
        }
    }

    /// 32 random bytes, base64url without padding.
    static let byteCount = 32
    static let encodedLength = 43
    private static let maxFileBytes = 1024

    private let bytes: [UInt8]

    init?(_ encoded: String) {
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count >= Self.encodedLength,
              trimmed.utf8.allSatisfy(Self.isBase64URL)
        else { return nil }
        bytes = Array(trimmed.utf8)
    }

    static func generate() -> AccessToken {
        var random = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &random)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        let encoded = Data(random).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return AccessToken(encoded)!
    }

    var encoded: String { String(decoding: bytes, as: UTF8.self) }

    /// Where the token lives. The server creates and tightens only its own
    /// app-support folder. A `--token-file` folder must already exist and
    /// belong to the user, and its mode is left alone.
    enum Location: Equatable {
        case appSupport(home: URL)
        case custom(URL)

        static var standard: Location { .appSupport(home: FileManager.default.homeDirectoryForCurrentUser) }

        var file: URL {
            switch self {
            case .appSupport(let home): home.appendingPathComponent(ServiceDefaults.tokenPath)
            case .custom(let file): file
            }
        }
    }

    /// Accepts an `Authorization` header value of the form `Bearer <token>`.
    /// The comparison takes the same time wherever the first differing byte is.
    func authorizes(_ header: String?) -> Bool {
        guard let header else { return false }
        let scheme = Array("bearer ".utf8)
        let field = Array(header.utf8)
        guard field.count > scheme.count,
              zip(field, scheme).allSatisfy({ (UInt8(ascii: "A")...UInt8(ascii: "Z") ~= $0 ? $0 | 0x20 : $0) == $1 })
        else { return false }
        let presented = field[scheme.count...]
        var difference = UInt8(presented.count == bytes.count ? 0 : 1)
        for index in bytes.indices {
            let offset = presented.startIndex + index
            difference |= bytes[index] ^ (offset < presented.endIndex ? presented[offset] : 0)
        }
        return difference == 0
    }

    /// Returns the token at `location`, creating it first when the file is
    /// absent. An existing file is never replaced: a valid token keeps
    /// clients working across restarts, and any other content may be the
    /// user's data, so the server refuses to start instead.
    static func loadOrCreate(_ location: Location) throws -> AccessToken {
        let path = location.file.path
        let folder = location.file.deletingLastPathComponent().path
        switch location {
        case .appSupport: try ensurePrivateDirectory(folder)
        case .custom: try requireOwnedDirectory(folder)
        }
        if let existing = try read(path) {
            return existing
        }
        try install(generate(), at: path)
        guard let stored = try read(path) else { throw LoadError.malformed(path: path) }
        return stored
    }

    /// nil only when no file exists at `path`. Throws when the file exists
    /// but other users could have read or replaced it, or when it holds
    /// anything but a token.
    static func read(_ path: String) throws -> AccessToken? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw LoadError.notRegularFile(path: path) }
            throw LoadError.posix(path, "open", errno)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw LoadError.posix(path, "stat", errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw LoadError.notRegularFile(path: path) }
        guard info.st_uid == geteuid() else { throw LoadError.wrongOwner(path: path) }
        guard info.st_mode & 0o077 == 0 else { throw LoadError.insecurePermissions(path: path, mode: info.st_mode) }
        var buffer = [UInt8](repeating: 0, count: maxFileBytes + 1)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count >= 0 else { throw LoadError.posix(path, "read", errno) }
        guard count <= maxFileBytes,
              let token = AccessToken(String(decoding: buffer.prefix(count), as: UTF8.self))
        else { throw LoadError.malformed(path: path) }
        return token
    }

    private static func requireOwnedDirectory(_ path: String) throws {
        var info = stat()
        guard stat(path, &info) == 0 else { throw LoadError.posix(path, "find folder", errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            throw LoadError.unsafeFolder(path: path)
        }
    }

    private static func ensurePrivateDirectory(_ path: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw LoadError.io(path: path, operation: "create", reason: error.localizedDescription)
        }
        var info = stat()
        guard stat(path, &info) == 0 else { throw LoadError.posix(path, "stat", errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw LoadError.notRegularFile(path: path) }
        guard info.st_uid == geteuid() else { throw LoadError.wrongOwner(path: path) }
        if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 {
            throw LoadError.posix(path, "chmod", errno)
        }
    }

    /// Writes a temporary file, then links it into place. `link` never
    /// replaces a file: when another process created the token first, that
    /// token wins, and the caller's read decides whether it is valid.
    private static func install(_ token: AccessToken, at path: String) throws {
        let temporary = "\(path).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LoadError.posix(path, "create", errno) }
        defer { unlink(temporary) }
        defer { close(fd) }
        let contents = Array((token.encoded + "\n").utf8)
        let written = write(fd, contents, contents.count)
        guard written >= 0 else { throw LoadError.posix(path, "write", errno) }
        guard written == contents.count else {
            throw LoadError.io(path: path, operation: "write", reason: "short write")
        }
        guard fsync(fd) == 0 else { throw LoadError.posix(path, "sync", errno) }
        guard link(temporary, path) == 0 || errno == EEXIST else { throw LoadError.posix(path, "install", errno) }
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }
}

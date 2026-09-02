import Foundation

/// Lexical path normalization plus a symlink walk for outbound attachment
/// paths. `realpath()` is not enough: it resolves the link and hands back
/// the target, which is exactly what an attacker wants. We refuse the path
/// on any symlink instead. Ported from openclaw/imsg.
enum SecurePath {
    /// macOS keeps these as symlinks to /private/*. They are trusted, so
    /// rewrite them before the walk instead of rejecting them.
    private static let trustedSystemAliasPrefixes: [(alias: String, canonical: String)] = [
        ("/tmp", "/private/tmp"),
        ("/var", "/private/var"),
        ("/etc", "/private/etc"),
    ]

    /// Tilde-expanded, `..`/`.`-collapsed, alias-normalized absolute path.
    /// Nil when the input is not absolute after tilde expansion: we never
    /// resolve against the process cwd (under launchd it is `/`).
    static func absoluteLexicalPath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let standardized = (expanded as NSString).standardizingPath
        return normalizingTrustedSystemAliasPrefix(standardized)
    }

    /// True when any component of the (already lexical) path is a symlink.
    /// Components that fail `lstat` are skipped; a missing file is a
    /// different error and is reported by the open that follows.
    static func hasSymlinkComponent(_ lexicalPath: String) -> Bool {
        var cursor = ""
        for component in (lexicalPath as NSString).pathComponents {
            if component == "/" { cursor = "/"; continue }
            cursor = (cursor as NSString).appendingPathComponent(component)
            var info = stat()
            guard lstat(cursor, &info) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFLNK { return true }
        }
        return false
    }

    private static func normalizingTrustedSystemAliasPrefix(_ path: String) -> String {
        for (alias, canonical) in trustedSystemAliasPrefixes {
            if path == alias { return canonical }
            if path.hasPrefix(alias + "/") { return canonical + path.dropFirst(alias.count) }
        }
        return path
    }
}

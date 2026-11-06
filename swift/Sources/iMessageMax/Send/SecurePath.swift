import Foundation

enum SecurePath {
    private static let trustedSystemAliasPrefixes: [(alias: String, canonical: String)] = [
        ("/tmp", "/private/tmp"),
        ("/var", "/private/var"),
        ("/etc", "/private/etc"),
    ]

    static func absoluteLexicalPath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let standardized = (expanded as NSString).standardizingPath
        return normalizingTrustedSystemAliasPrefix(standardized)
    }

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

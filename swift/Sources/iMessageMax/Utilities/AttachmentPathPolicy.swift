import Foundation

/// Validates that attachment paths from chat.db stay inside allowed roots.
/// chat.db content is data, not trusted input — a tampered row must not
/// turn get_attachment into an arbitrary file read.
enum AttachmentPathPolicy {
    static let defaultRoots: [String] = [
        ("~/Library/Messages" as NSString).expandingTildeInPath
    ]

    /// Returns the canonical path if it is inside one of the roots, else nil.
    static func validatedPath(_ rawPath: String, allowedRoots: [String] = defaultRoots) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let canonical = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        for root in allowedRoots {
            let canonicalRoot = URL(fileURLWithPath: root)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            if canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/") {
                return canonical
            }
        }
        return nil
    }
}

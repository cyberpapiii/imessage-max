import Foundation

enum AttachmentPathPolicy {
    static let defaultRoots: [String] = [
        ("~/Library/Messages" as NSString).expandingTildeInPath
    ]

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

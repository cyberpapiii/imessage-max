import Foundation

enum SendPayload {
    case text(String)
    case file(path: String)

    enum BuildResult {
        case success([SendPayload])
        case failure(String)
    }

    static func build(
        text: String?,
        filePaths: [String]?
    ) -> BuildResult {
        var payloads: [SendPayload] = []

        if let filePaths, !filePaths.isEmpty {
            for path in filePaths where !path.isEmpty {
                payloads.append(.file(path: path))
            }
        }

        if let text, !text.isEmpty {
            payloads.append(.text(text))
        }

        guard !payloads.isEmpty else {
            return .failure("At least one of 'text' or 'file_paths' must be provided")
        }

        return .success(payloads)
    }
}

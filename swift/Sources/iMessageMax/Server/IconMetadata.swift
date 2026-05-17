import Foundation
import Logging
import MCP

enum IconMetadata {
    static let mimeType = "image/png"
    static let sizes = ["64x64"]

    private static let latestProtocolVersion = "2025-11-25"
    private static let serverInfoMarker = Data(#""serverInfo""#.utf8)
    private static let iconBase64 = """
    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
    """

    private static let iconDataURI = "data:\(mimeType);base64,\(iconBase64.filter { !$0.isWhitespace })"

    static var icons: [Icon]? {
        [
            Icon(
                src: iconDataURI,
                mimeType: mimeType,
                sizes: sizes
            )
        ]
    }

    static func injectServerIcons(into data: Data) -> Data {
        guard data.contains(serverInfoMarker),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var result = object["result"] as? [String: Any],
              result["protocolVersion"] as? String == latestProtocolVersion,
              var serverInfo = result["serverInfo"] as? [String: Any],
              serverInfo["icons"] == nil else {
            return data
        }

        serverInfo["icons"] = [
            [
                "src": iconDataURI,
                "mimeType": mimeType,
                "sizes": sizes,
            ]
        ]
        result["serverInfo"] = serverInfo
        object["result"] = result

        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }
}

actor IconMetadataTransport: Transport {
    private let base: any Transport
    private let messageStream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var receiveTask: Task<Void, Never>?
    nonisolated let logger: Logger

    init(base: any Transport) {
        self.base = base
        self.logger = Logger(
            label: "mcp.transport.icon-metadata",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.messageStream = AsyncThrowingStream<Data, Error> { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation
    }

    func connect() async throws {
        try await base.connect()
        let upstream = await base.receive()
        receiveTask = Task {
            do {
                for try await data in upstream {
                    continuation.yield(data)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func disconnect() async {
        receiveTask?.cancel()
        await base.disconnect()
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        try await base.send(IconMetadata.injectServerIcons(into: data))
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        messageStream
    }
}

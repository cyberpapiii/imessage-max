import Foundation
import Hummingbird
import NIOCore

enum HTTPRequestParsing {
    /// Largest request body accepted on POST. Same 512 KB bound the old
    /// `collect(upTo:)` call enforced.
    static let maxRequestBodyBytes = 512 * 1024

    /// Upper bound on how many over-limit bytes get read and discarded before
    /// giving up on leaving the connection cleanly closable.
    static let overLimitDrainBytes = 32 * 1024 * 1024

    enum BodyCollection {
        case complete(Data)
        case tooLarge
        case timedOut
    }

    private struct BodyReadTimeout: Error {}

    /// Collects the request body up to `maxBytes`. On overflow, keeps
    /// consuming the remaining body (bounded by `drainLimit`) before
    /// reporting `.tooLarge`.
    ///
    /// The drain is load-bearing. `collect(upTo:)` threw on overflow and left
    /// the rest of the body unread. For clients that send `Connection: close`
    /// (Python urllib does by default), Hummingbird's HTTP1 loop skips its
    /// own post-response body drain and blocks on the channel's closeFuture.
    /// With megabytes unread, NIO back-pressure stops socket reads, EOF is
    /// never seen, and the server-side FD is never closed — each oversized
    /// request leaked one descriptor (CLOSED / FIN_WAIT_2 / TIME_WAIT under
    /// the pid in lsof) against a soft limit of 256. Orderly keep-alive
    /// clients (http.client) were unaffected because the HTTP1 loop drains
    /// before reading the next request head.
    ///
    /// The body is a single-iteration sequence, so draining cannot happen
    /// after `collect` throws; this helper owns the one iteration and does
    /// both jobs. Bodies whose declared Content-Length exceeds `drainLimit`
    /// are rejected without reading; that keeps the work bounded and matches
    /// the old behavior for absurd sizes.
    static func collectBodyDrainingOverflow(
        _ body: RequestBody,
        declaredLength: Int?,
        maxBytes: Int,
        drainLimit: Int,
        deadline: Duration
    ) async throws -> BodyCollection {
        if let declaredLength, declaredLength > drainLimit {
            return .tooLarge
        }
        do {
            return try await withThrowingTaskGroup(of: BodyCollection.self) { group in
                group.addTask {
                    try await readAndDrain(body, maxBytes: maxBytes, drainLimit: drainLimit)
                }
                group.addTask {
                    await AsyncTimeout.sleep(deadline)
                    throw BodyReadTimeout()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch is BodyReadTimeout {
            return .timedOut
        }
    }

    private static func readAndDrain(
        _ body: RequestBody,
        maxBytes: Int,
        drainLimit: Int
    ) async throws -> BodyCollection {
        var collected = ByteBuffer()
        var iterator = body.makeAsyncIterator()
        while var chunk = try await iterator.next() {
            guard collected.readableBytes + chunk.readableBytes <= maxBytes else {
                var drained = chunk.readableBytes
                while drained <= drainLimit, let more = try await iterator.next() {
                    drained += more.readableBytes
                }
                return .tooLarge
            }
            collected.writeBuffer(&chunk)
        }
        return .complete(Data(buffer: collected))
    }

    static func acceptsStreamableHTTP(_ accept: String) -> Bool {
        if accept.contains("*/*") { return true }
        return accept.contains("application/json") && accept.contains("text/event-stream")
    }
}

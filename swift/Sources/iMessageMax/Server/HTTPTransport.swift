import Foundation
import Hummingbird
import HTTPTypes
import Logging
import MCP
import NIOCore

/// A production-ready implementation of the MCP Streamable HTTP transport for servers.
///
/// This transport implements the [Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http)
/// specification from the Model Context Protocol for server-side usage.
///
/// Key features:
/// - **Per-session Server instances** - Each client session gets its own Server,
///   enabling clean reconnection without "already initialized" errors
/// - HTTP POST for client -> server JSON-RPC messages
/// - HTTP GET with SSE for server -> client streaming
/// - HTTP DELETE for session termination
/// - Session ID via `Mcp-Session-Id` header
///
/// Built on Hummingbird 2.x for production-grade HTTP handling.
public actor HTTPTransport: Transport {
    /// The host to listen on
    public let host: String

    /// The port to listen on
    public let port: Int

    /// Logger instance for transport-related events
    public nonisolated let logger: Logger

    // State
    private var isConnected = false
    private let sessionManager: SessionManager
    private let sseManager = SSEConnectionManager()

    // Request correlation: maps JSON-RPC id to continuation for response
    private var pendingRequests: [String: PendingRequest] = [:]

    // Server task
    private var serverTask: Task<Void, Error>?

    /// Tracks a pending request with its session
    private struct PendingRequest {
        let sessionId: String
        let continuation: CheckedContinuation<Data, Error>
    }

    /// Creates a new HTTP server transport
    ///
    /// - Parameters:
    ///   - host: The host to listen on (default: "127.0.0.1")
    ///   - port: The port to listen on (default: 8080)
    ///   - database: Database instance for tool access
    ///   - resolver: Contact resolver for tool access
    ///   - logger: Optional logger instance for transport events
    init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        database: Database,
        resolver: ContactResolver,
        logger: Logger? = nil
    ) {
        self.host = host
        self.port = port
        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.http.server",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )
        self.sessionManager = SessionManager(database: database, resolver: resolver)
    }

    /// Establishes the HTTP server connection
    ///
    /// This starts listening for incoming HTTP connections on the specified host and port.
    ///
    /// - Throws: Error if the server cannot be started
    public func connect() async throws {
        guard !isConnected else { return }

        // Set up response routing from per-session Servers
        await sessionManager.setResponseHandler { [weak self] sessionId, data in
            await self?.handleServerResponse(sessionId: sessionId, data: data)
        }

        // Set up SSE cleanup when sessions expire
        await sessionManager.setSessionTerminationHandler { [weak self] sessionId in
            await self?.sseManager.terminateSession(sessionId: sessionId)
            await self?.cleanupPendingRequestsAsync(for: sessionId)
        }

        // Create router with all routes
        let router = Router()

        // Add origin validation middleware
        router.add(middleware: OriginValidationMiddleware())

        // Register routes - capture self for route handlers
        let transport = self
        router.post("/") { request, context in
            try await transport.handlePost(request: request, context: context)
        }
        router.get("/") { request, context in
            try await transport.handleGet(request: request, context: context)
        }
        router.delete("/") { request, context in
            try await transport.handleDelete(request: request, context: context)
        }

        // Create application
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port)
            ),
            logger: logger
        )

        logger.info("Starting HTTP transport on \(host):\(port)")

        isConnected = true

        // Start server in background
        serverTask = Task {
            try await app.run()
        }
    }

    /// Handles POST requests with JSON-RPC messages
    private func handlePost(
        request: Request,
        context: some RequestContext
    ) async throws -> Response {
        // Validate Content-Type
        guard let contentType = request.headers[.contentType],
            contentType.contains("application/json")
        else {
            return errorResponse(
                status: .unsupportedMediaType,
                message: "Invalid Content-Type, expected application/json"
            )
        }

        // Validate Accept header
        guard let accept = request.headers[.accept],
            accept.contains("application/json") || accept.contains("text/event-stream")
                || accept.contains("*/*")
        else {
            return errorResponse(
                status: .notAcceptable,
                message: "Invalid Accept header, expected application/json or text/event-stream"
            )
        }

        // Collect request body
        let body = try await request.body.collect(upTo: 10 * 1024 * 1024)  // 10MB max
        let requestData = Data(buffer: body)

        // Parse JSON to determine message type
        guard let json = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        else {
            // Check if it's a batch (array)
            if let jsonArray = try? JSONSerialization.jsonObject(with: requestData)
                as? [[String: Any]]
            {
                return try await handleBatchRequest(
                    jsonArray: jsonArray,
                    requestData: requestData,
                    request: request
                )
            }
            return errorResponse(
                status: .badRequest,
                message: "Invalid JSON"
            )
        }

        let messageType = detectMessageType(json)
        let isInitialize = (json["method"] as? String) == "initialize"

        var sessionId: String
        var responseHeaders = HTTPFields()
        responseHeaders[.contentType] = "application/json"

        if isInitialize {
            // Create new session with its own Server instance
            let session = await sessionManager.createSession()
            sessionId = session.id
            responseHeaders[.mcpSessionId] = sessionId
            logger.info("Created new session with dedicated Server: \(sessionId)")
        } else {
            // Validate existing session
            guard let requestSessionId = request.headers[.mcpSessionId] else {
                return errorResponse(
                    status: .badRequest,
                    message: "Missing Mcp-Session-Id header"
                )
            }

            // Return 404 for invalid/expired sessions (MCP spec compliant)
            // This tells client to re-initialize with a fresh session
            guard await sessionManager.validate(sessionId: requestSessionId) != nil else {
                return errorResponse(
                    status: .notFound,
                    message: "Invalid or expired session. Please re-initialize."
                )
            }

            sessionId = requestSessionId
            await sessionManager.touch(sessionId: sessionId)
            responseHeaders[.mcpSessionId] = sessionId
        }

        // Handle based on message type
        switch messageType {
        case .request:
            // Route to session's Server and wait for response
            let jsonRpcId = parseJsonRpcId(from: json)

            do {
                let responseData = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Data, Error>) in
                    self.storePendingRequest(
                        id: jsonRpcId,
                        sessionId: sessionId,
                        continuation: continuation
                    )

                    // Route message to session's Server
                    Task {
                        let routed = await self.sessionManager.routeMessage(
                            sessionId: sessionId,
                            data: requestData
                        )
                        if !routed {
                            // Session was terminated between validation and routing
                            if let pending = await self.removePendingRequest(id: jsonRpcId) {
                                pending.continuation.resume(
                                    throwing: MCPError.connectionClosed
                                )
                            }
                        }
                    }
                }

                return Response(
                    status: .ok,
                    headers: responseHeaders,
                    body: .init(byteBuffer: ByteBuffer(data: responseData))
                )
            } catch {
                return errorResponse(
                    status: .internalServerError,
                    message: "Failed to process request: \(error.localizedDescription)"
                )
            }

        case .notification, .response:
            // Route to session's Server, no response expected
            let routed = await sessionManager.routeMessage(sessionId: sessionId, data: requestData)
            if !routed {
                return errorResponse(
                    status: .notFound,
                    message: "Session no longer valid"
                )
            }
            return Response(
                status: .accepted,
                headers: responseHeaders
            )

        case .batch:
            // Shouldn't reach here since we check for batch above
            return Response(
                status: .accepted,
                headers: responseHeaders
            )
        }
    }

    /// Handles batch requests
    private func handleBatchRequest(
        jsonArray: [[String: Any]],
        requestData: Data,
        request: Request
    ) async throws -> Response {
        var responseHeaders = HTTPFields()
        responseHeaders[.contentType] = "application/json"

        // Get session ID
        guard let sessionId = request.headers[.mcpSessionId] else {
            return errorResponse(
                status: .badRequest,
                message: "Missing Mcp-Session-Id header for batch request"
            )
        }

        guard await sessionManager.validate(sessionId: sessionId) != nil else {
            return errorResponse(
                status: .notFound,
                message: "Invalid or expired session. Please re-initialize."
            )
        }

        responseHeaders[.mcpSessionId] = sessionId

        // For batches, generate a unique ID and wait for response
        let batchId = "batch-\(UUID().uuidString)"

        do {
            let responseData = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                self.storePendingRequest(
                    id: batchId,
                    sessionId: sessionId,
                    continuation: continuation
                )

                Task {
                    let routed = await self.sessionManager.routeMessage(
                        sessionId: sessionId,
                        data: requestData
                    )
                    if !routed {
                        if let pending = await self.removePendingRequest(id: batchId) {
                            pending.continuation.resume(throwing: MCPError.connectionClosed)
                        }
                    }
                }
            }

            return Response(
                status: .ok,
                headers: responseHeaders,
                body: .init(byteBuffer: ByteBuffer(data: responseData))
            )
        } catch {
            return errorResponse(
                status: .internalServerError,
                message: "Failed to process batch: \(error.localizedDescription)"
            )
        }
    }

    /// Handles GET requests for SSE streaming
    private func handleGet(
        request: Request,
        context: some RequestContext
    ) async throws -> Response {
        // Validate Accept header
        guard let accept = request.headers[.accept],
            accept.contains("text/event-stream")
        else {
            return errorResponse(
                status: .notAcceptable,
                message: "Invalid Accept header, expected text/event-stream"
            )
        }

        // Validate session
        guard let sessionId = request.headers[.mcpSessionId] else {
            return errorResponse(
                status: .badRequest,
                message: "Missing Mcp-Session-Id header"
            )
        }

        guard await sessionManager.validate(sessionId: sessionId) != nil else {
            return errorResponse(
                status: .notFound,
                message: "Invalid or expired session. Please re-initialize."
            )
        }

        await sessionManager.touch(sessionId: sessionId)

        // Get Last-Event-ID for resumption if provided
        let lastEventId = request.headers[.lastEventId]

        // Create streaming response
        var responseHeaders = HTTPFields()
        responseHeaders[.contentType] = "text/event-stream"
        responseHeaders[.cacheControl] = "no-cache"
        responseHeaders[.connection] = "keep-alive"
        responseHeaders[.mcpSessionId] = sessionId

        // Create connection info and register
        let connectionInfo = SSEConnectionInfo(
            sessionId: sessionId,
            lastEventId: lastEventId
        )

        let channel = await sseManager.register(info: connectionInfo)
        let connectionId = connectionInfo.id
        let sseManager = self.sseManager
        let logger = self.logger

        logger.debug("SSE connection established: \(connectionId) for session: \(sessionId)")

        return Response(
            status: .ok,
            headers: responseHeaders,
            body: .init { writer in
                // Stream events from channel (includes keep-alives)
                do {
                    for await event in channel.stream {
                        try await writer.write(ByteBuffer(string: event))
                    }
                } catch {
                    logger.debug("SSE stream error: \(error)")
                }

                await sseManager.unregister(connectionId: connectionId)
                logger.debug("SSE connection closed: \(connectionId)")
            }
        )
    }

    /// Handles DELETE requests for session termination
    private func handleDelete(
        request: Request,
        context: some RequestContext
    ) async throws -> Response {
        // Validate session
        guard let sessionId = request.headers[.mcpSessionId] else {
            return errorResponse(
                status: .badRequest,
                message: "Missing Mcp-Session-Id header"
            )
        }

        guard await sessionManager.validate(sessionId: sessionId) != nil else {
            return errorResponse(
                status: .notFound,
                message: "Invalid or expired session"
            )
        }

        // Terminate session (this also stops its Server instance)
        await sessionManager.terminate(sessionId: sessionId)
        await sseManager.terminateSession(sessionId: sessionId)

        // Clean up any pending requests for this session
        cleanupPendingRequests(for: sessionId)

        logger.info("Session terminated: \(sessionId)")

        return Response(status: .noContent)
    }

    /// Handles responses from per-session Server instances
    private func handleServerResponse(sessionId: String, data: Data) async {
        guard isConnected else { return }

        // Parse the response to get the JSON-RPC id
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("Failed to parse server response as JSON")
            return
        }

        let jsonRpcId = parseJsonRpcId(from: json)

        // Check if this matches a pending request
        if let pending = pendingRequests.removeValue(forKey: jsonRpcId) {
            pending.continuation.resume(returning: data)
            logger.trace("Routed response for request: \(jsonRpcId)")
        } else {
            // Broadcast via SSE to session's connections
            let event = SSEEvent(
                id: UUID().uuidString,
                event: "message",
                data: String(data: data, encoding: .utf8) ?? ""
            )

            let formattedEvent = event.formatted()
            await sseManager.broadcast(sessionId: sessionId, event: formattedEvent)

            logger.trace("Broadcast SSE message to session: \(sessionId)")
        }
    }

    /// Disconnects the HTTP server
    ///
    /// This stops accepting new connections and closes existing ones.
    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false

        // Cancel server task
        serverTask?.cancel()
        serverTask = nil

        // Terminate all sessions
        for sessionId in await sessionManager.activeSessionIds() {
            await sessionManager.terminate(sessionId: sessionId)
        }

        // Cancel all pending requests
        for (_, pending) in pendingRequests {
            pending.continuation.resume(throwing: MCPError.connectionClosed)
        }
        pendingRequests.removeAll()

        logger.info("HTTP transport disconnected")
    }

    /// Sends a response message (Transport protocol requirement - not used in per-session model)
    public func send(_ data: Data) async throws {
        // In per-session model, responses route through handleServerResponse
        // This method exists for Transport protocol compliance
        logger.warning("send() called directly on HTTPTransport - should use per-session routing")
    }

    /// Receives messages (Transport protocol requirement - not used in per-session model)
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        // In per-session model, each session has its own receive stream
        // Return empty stream for Transport protocol compliance
        return AsyncThrowingStream { $0.finish() }
    }

    // MARK: - Private Helpers

    /// Stores a pending request continuation for later response matching
    private func storePendingRequest(
        id: String,
        sessionId: String,
        continuation: CheckedContinuation<Data, Error>
    ) {
        pendingRequests[id] = PendingRequest(sessionId: sessionId, continuation: continuation)

        // Set up a timeout to prevent indefinite waiting
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))  // 5 minute timeout
            if let pending = await self?.removePendingRequest(id: id) {
                pending.continuation.resume(
                    throwing: MCPError.serverError(code: -32000, message: "Request timeout")
                )
            }
        }
    }

    /// Removes and returns a pending request
    private func removePendingRequest(id: String) -> PendingRequest? {
        return pendingRequests.removeValue(forKey: id)
    }

    /// Cleans up all pending requests for a terminated session
    private func cleanupPendingRequests(for sessionId: String) {
        let toRemove = pendingRequests.filter { $0.value.sessionId == sessionId }
        for (id, pending) in toRemove {
            pendingRequests.removeValue(forKey: id)
            pending.continuation.resume(
                throwing: MCPError.serverError(code: -32000, message: "Session terminated")
            )
        }
    }

    /// Async wrapper for cleanup (called from session termination handler)
    private func cleanupPendingRequestsAsync(for sessionId: String) async {
        cleanupPendingRequests(for: sessionId)
    }

    /// Detects the type of JSON-RPC message
    private nonisolated func detectMessageType(_ json: [String: Any]) -> JSONRPCMessageType {
        if json["method"] != nil && json["id"] != nil {
            return .request
        } else if json["method"] != nil {
            return .notification
        } else if json["result"] != nil || json["error"] != nil {
            return .response
        }
        return .notification  // Default fallback
    }

    /// Parses the JSON-RPC id from a message
    private nonisolated func parseJsonRpcId(from json: [String: Any]) -> String {
        if let id = json["id"] {
            if let stringId = id as? String {
                return stringId
            } else if let intId = id as? Int {
                return String(intId)
            } else if let doubleId = id as? Double {
                return String(Int(doubleId))
            } else if id is NSNull {
                return "null"
            }
        }
        return UUID().uuidString  // Generate unique ID if none found
    }

    /// Creates a JSON-RPC error response
    private nonisolated func errorResponse(status: HTTPResponse.Status, message: String) -> Response
    {
        let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")
        let errorJson =
            """
            {"jsonrpc":"2.0","error":{"code":-32600,"message":"\(escapedMessage)"},"id":null}
            """
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: errorJson))
        )
    }
}

// MARK: - Supporting Types

/// Types of JSON-RPC messages
private enum JSONRPCMessageType {
    case request
    case notification
    case response
    case batch
}

// MARK: - HTTPField.Name Extensions

extension HTTPField.Name {
    /// MCP Session ID header
    static let mcpSessionId = HTTPField.Name("Mcp-Session-Id")!

    /// Last-Event-ID header for SSE resumption
    static let lastEventId = HTTPField.Name("Last-Event-ID")!

    /// Connection header
    static let connection = HTTPField.Name("Connection")!
}

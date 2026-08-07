import Foundation
import Hummingbird
import HTTPTypes
import Logging
import MCP
import NIOCore

enum MCPProtocolVersion {
    static let latest = "2025-11-25"
    static let defaultAssumed = "2025-03-26"
    static let supported: Set<String> = [latest, "2025-06-18", defaultAssumed, "2024-11-05"]
    static let requiresHeaderAfterInitialize: Set<String> = [latest, "2025-06-18"]
}

/// MCP Streamable HTTP transport (Hummingbird): per-session Servers, POST/GET-SSE/DELETE, `Mcp-Session-Id`.
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
    private let database: Database
    private let resolver: ContactResolver

    // Request correlation: maps JSON-RPC id to continuation for response
    private var pendingRequests: [PendingRequestKey: PendingRequest] = [:]
    private var routingConfigured = false
    private let requestTimeout: Duration

    /// Background task running the Hummingbird server
    private var serverTask: Task<Void, Error>?

    /// Tracks a pending request with its session
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTimer: DispatchSourceTimer
    }

    private struct PendingRequestKey: Hashable {
        let sessionId: String
        let requestId: String
    }

    /// Creates a new HTTP server transport
    ///
    /// - Parameters:
    ///   - host: The host to listen on (default: "127.0.0.1")
    ///   - port: The port to listen on (default: 8080)
    ///   - database: Database instance for tool access
    ///   - resolver: Contact resolver for tool access
    ///   - logger: Optional logger instance for transport events
    ///   - maxSessions: concurrent-session cap, forwarded to `SessionManager`.
    ///     Production uses the default; tests lower it to reach the 503 path.
    init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        database: Database,
        resolver: ContactResolver,
        logger: Logger? = nil,
        requestTimeout: Duration = .seconds(300),
        maxSessions: Int = 100
    ) {
        self.host = host
        self.port = port
        self.requestTimeout = requestTimeout
        self.database = database
        self.resolver = resolver
        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.http.server",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )
        self.sessionManager = SessionManager(
            database: database,
            resolver: resolver,
            maxSessions: maxSessions
        )
    }

    /// Establishes the HTTP server connection
    ///
    /// This starts listening for incoming HTTP connections on the specified host and port.
    ///
    /// - Throws: Error if the server cannot be started
    public func connect() async throws {
        guard !isConnected else { return }

        await configureRoutingIfNeeded()
        await ensureToolCatalogRegistered()

        let app = buildApplication()

        logger.info("Starting HTTP transport on \(host):\(port)")

        isConnected = true

        // Start the server in a background task
        self.serverTask = Task {
            try await app.runService()
        }
    }

    func makeApplicationForTesting() async -> some ApplicationProtocol {
        await configureRoutingIfNeeded()
        await ensureToolCatalogRegistered()
        isConnected = true
        return buildApplication()
    }

    /// Populates the global tool registry at startup so the stateless modern
    /// lane can serve `tools/list`/`tools/call` before (or without) any
    /// legacy session ever being created.
    private func ensureToolCatalogRegistered() async {
        guard ToolHandlerRegistry.shared.getTools().isEmpty else { return }
        let server = Server(
            name: Version.name,
            version: Version.current,
            title: Version.title,
            instructions: Version.instructions,
            capabilities: Version.serverCapabilities
        )
        await ToolRegistry.registerAll(on: server, db: database, resolver: resolver)
    }

    func registerMethodHandlerForTesting<M: MCP.Method>(
        sessionId: String,
        _ method: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) async -> Bool {
        await sessionManager.registerMethodHandlerForTesting(
            sessionId: sessionId,
            method,
            handler: handler
        )
    }

    /// Blocks until the server terminates, propagating any errors.
    ///
    /// Call this from main.swift after `connect()`. If the Hummingbird server
    /// crashes or encounters an error, it propagates here, so the process
    /// exits and launchd can restart it.
    public func waitForTermination() async throws {
        guard let task = serverTask else { return }
        try await task.value
    }

    /// Handles POST requests with JSON-RPC messages
    func handlePost(
        request: Request,
        context: some Hummingbird.RequestContext
    ) async throws -> Response {
        guard let contentType = request.headers[.contentType],
            contentType.contains("application/json")
        else {
            return errorResponse(
                status: .unsupportedMediaType,
                message: "Invalid Content-Type, expected application/json"
            )
        }

        // Streamable HTTP clients advertise both response shapes because a
        // request can complete as JSON or as an SSE stream.
        guard let accept = request.headers[.accept],
            acceptsStreamableHTTP(accept)
        else {
            return errorResponse(
                status: .notAcceptable,
                message: "Invalid Accept header, expected application/json and text/event-stream"
            )
        }

        let body = try await request.body.collect(upTo: 512 * 1024)  // 512KB
        let requestData = Data(buffer: body)

        let jsonString = String(data: requestData, encoding: .utf8) ?? ""
        if jsonString.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            return errorResponse(
                status: .badRequest,
                message: "Batch requests are not supported",
                code: -32600
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        else {
            return errorResponse(
                status: .badRequest,
                message: "Invalid JSON"
            )
        }

        let messageType = detectMessageType(json)
        let isInitialize = (json["method"] as? String) == "initialize"

        // Era selection (dual-era server, MCP 2026-07-28 backward-compat
        // model): an `initialize` request selects legacy session semantics;
        // modern per-request `_meta` (or `server/discover`) selects the
        // stateless 2026-07-28 lane. Only the BODY selects the era. Real
        // legacy clients (plug) send Mcp-Method/MCP-Protocol-Version headers
        // on session traffic too, so header presence must not reroute them.
        if !isInitialize, ModernDispatcher.isModernMessage(json) {
            return await handleModernPost(
                request: request,
                requestData: requestData,
                json: json,
                messageType: messageType
            )
        }

        let requestedProtocolVersion = isInitialize
            ? parseInitializeProtocolVersion(from: json)
            : nil

        // Validate client's protocol version header. The header is required on
        // subsequent HTTP requests for sessions negotiated at 2025-06-18+.
        if let versionError = await validateProtocolVersionHeader(
            request: request,
            isInitialize: isInitialize
        ) {
            return versionError
        }

        var sessionId: String
        var responseHeaders = HTTPFields()
        responseHeaders[.contentType] = "application/json"

        if isInitialize {
            // Create new session with its own Server instance. Capacity
            // refusal and startup failure are distinct: the first is
            // retryable (503), the second is an internal fault (500).
            let creation: SessionCreationResult = await sessionManager.createSession(
                protocolVersion: requestedProtocolVersion ?? MCPProtocolVersion.latest
            )
            switch creation {
            case .created(let session):
                sessionId = session.id
                responseHeaders[.mcpSessionId] = sessionId
                logger.info("Created new session with dedicated Server: \(sessionId)")
                FileHandle.standardError.write(
                    Data("[iMessage Max] era=legacy transport=http version=\(requestedProtocolVersion ?? MCPProtocolVersion.latest) method=initialize session=\(sessionId.prefix(8))\n".utf8)
                )
            case .atCapacity:
                return errorResponse(
                    status: .serviceUnavailable,
                    message: """
                        Session capacity reached. Reuse an existing session, terminate unused \
                        sessions with DELETE and their Mcp-Session-Id, or retry after idle \
                        sessions expire.
                        """
                )
            case .startFailed:
                return errorResponse(
                    status: .internalServerError,
                    message: "Failed to start session. Check the server log."
                )
            }
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
            let method = (json["method"] as? String)
                ?? (messageType == .notification ? "notification" : "response")
            let version = request.headers[.mcpProtocolVersion] ?? "legacy"
            FileHandle.standardError.write(
                Data(
                    "[iMessage Max] era=legacy transport=http version=\(ModernDispatcher.sanitizedLogField(version)) method=\(ModernDispatcher.sanitizedLogField(method)) session=\(sessionId.prefix(8))\n"
                        .utf8
                )
            )
        }

        // Handle based on message type
        switch messageType {
        case .request:
            // Route to session's Server and wait for response
            let jsonRpcId = Self.parseJsonRpcId(from: json)

            do {
                let responseData = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Data, Error>) in
                    let stored = self.storePendingRequest(
                        sessionId: sessionId,
                        id: jsonRpcId,
                        continuation: continuation
                    )

                    guard stored else {
                        continuation.resume(
                            throwing: MCPError.serverError(
                                code: -32600,
                                message: "Duplicate in-flight JSON-RPC request id: \(jsonRpcId)"
                            )
                        )
                        return
                    }

                    // Route message to session's Server
                    Task {
                        let routed = await self.sessionManager.routeMessage(
                            sessionId: sessionId,
                            data: requestData
                        )
                        if !routed {
                            // Session was terminated between validation and routing
                            if let pending = self.removePendingRequest(
                                sessionId: sessionId,
                                id: jsonRpcId
                            ) {
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
                FileHandle.standardError.write(
                    Data("[iMessage Max] Request handling failed: \(error)\n".utf8)
                )
                return errorResponse(
                    status: .internalServerError,
                    message: ClientErrorMessages.internalError
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

        }
    }

    // MARK: - Modern era (2026-07-28)

    private func handleModernPost(
        request: Request,
        requestData: Data,
        json: [String: Any],
        messageType: JSONRPCMessageType
    ) async -> Response {
        switch messageType {
        case .response:
            // Modern clients MUST NOT POST JSON-RPC responses.
            return modernResponse(
                ModernDispatcher.errorResult(
                    id: nil,
                    code: ModernDispatcher.ErrorCode.invalidRequest,
                    message: "JSON-RPC responses are not accepted",
                    httpStatus: 400
                )
            )
        case .notification:
            // Header requirements for notification POSTs are undefined in
            // this revision; accept with no body.
            return Response(status: .accepted)
        case .request:
            break
        }

        if let mismatch = validateModernHeaders(request: request, json: json) {
            return modernResponse(mismatch)
        }

        let result = await ModernDispatcher.handle(requestData, transport: "http")
        return modernResponse(result)
    }

    /// Enforces the required Streamable HTTP request-metadata headers
    /// (`MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`) and their
    /// header/body consistency. Returns a HeaderMismatch (-32020) outcome on
    /// failure, per spec section "Server Validation".
    private nonisolated func validateModernHeaders(
        request: Request,
        json: [String: Any]
    ) -> ModernDispatchResult? {
        let id = json["id"]
        let method = json["method"] as? String ?? ""
        let params = json["params"] as? [String: Any]
        let bodyVersion = ModernDispatcher.requestedProtocolVersion(in: json)

        func mismatch(_ message: String) -> ModernDispatchResult {
            ModernDispatcher.errorResult(
                id: id,
                code: ModernDispatcher.ErrorCode.headerMismatch,
                message: message,
                httpStatus: 400
            )
        }

        guard let headerVersion = request.headers[.mcpProtocolVersion] else {
            return mismatch("Missing required MCP-Protocol-Version header")
        }
        if let bodyVersion, bodyVersion != headerVersion {
            return mismatch(
                "Header mismatch: MCP-Protocol-Version header value '\(headerVersion)' does not match body value '\(bodyVersion)'"
            )
        }

        guard let headerMethod = request.headers[.mcpMethod] else {
            return mismatch("Missing required Mcp-Method header")
        }
        guard headerMethod == method else {
            return mismatch(
                "Header mismatch: Mcp-Method header value '\(headerMethod)' does not match body value '\(method)'"
            )
        }

        if ["tools/call", "resources/read", "prompts/get"].contains(method) {
            guard let rawName = request.headers[.mcpName] else {
                return mismatch("Missing required Mcp-Name header")
            }
            let headerName = ModernDispatcher.decodeBase64Sentinel(rawName)
            let bodyName = (params?["name"] as? String) ?? (params?["uri"] as? String) ?? ""
            guard headerName == bodyName else {
                return mismatch(
                    "Header mismatch: Mcp-Name header value '\(headerName)' does not match body value '\(bodyName)'"
                )
            }
        }

        return nil
    }

    private nonisolated func modernResponse(_ result: ModernDispatchResult) -> Response {
        let status = HTTPResponse.Status(code: result.httpStatus)
        guard let data = result.data else {
            return Response(status: status)
        }
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    /// Handles GET requests for SSE streaming
    func handleGet(
        request: Request,
        context: some Hummingbird.RequestContext
    ) async throws -> Response {
        guard let accept = request.headers[.accept],
            accept.contains("text/event-stream")
        else {
            return errorResponse(
                status: .notAcceptable,
                message: "Invalid Accept header, expected text/event-stream"
            )
        }

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

        var responseHeaders = HTTPFields()
        responseHeaders[.contentType] = "text/event-stream"
        responseHeaders[.cacheControl] = "no-cache"
        responseHeaders[.connection] = "keep-alive"
        responseHeaders[.mcpSessionId] = sessionId

        let connectionInfo = SSEConnectionInfo(sessionId: sessionId)

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
    func handleDelete(
        request: Request,
        context: some Hummingbird.RequestContext
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
        await sessionManager.terminateSession(sessionId: sessionId)
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

        let jsonRpcId = Self.parseJsonRpcId(from: json)

        // Check if this matches a pending request. Route through the helper so
        // the timeout work item is cancelled. Removing the entry directly left
        // an armed 300s timer plus a wakeup Task behind for every served
        // request, which is exactly the stray-wakeup churn this runtime is
        // documented to be sensitive to.
        if let pending = removePendingRequest(sessionId: sessionId, id: jsonRpcId) {
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
            await sessionManager.terminateSession(sessionId: sessionId)
        }

        // Cancel all pending requests
        for (_, pending) in pendingRequests {
            pending.timeoutTimer.cancel()
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
        sessionId: String,
        id: String,
        continuation: CheckedContinuation<Data, Error>
    ) -> Bool {
        let key = PendingRequestKey(sessionId: sessionId, requestId: id)
        guard pendingRequests[key] == nil else {
            return false
        }

        // Use a Dispatch timer instead of Task.sleep here. On this launchd-run
        // service, sleeping unstructured Swift tasks have repeatedly aborted in
        // swift_task_dealloc when they wake around the timeout boundary.
        //
        // Use a cancellable DispatchSourceTimer, not asyncAfter: a cancelled
        // asyncAfter work item stays enqueued (timer source, group, blocks,
        // ~0.65 KiB) until its deadline, so every served request retained its
        // 300 s timer and sustained load carried tens of MB of dead timers
        // (R0-02 diagnosis). Cancelling a timer source releases it immediately.
        let timeoutTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timeoutTimer.setEventHandler { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                await self.timeoutPendingRequest(sessionId: sessionId, id: id)
            }
        }
        timeoutTimer.schedule(deadline: .now() + AsyncTimeout.dispatchInterval(for: requestTimeout))
        timeoutTimer.resume()

        pendingRequests[key] = PendingRequest(
            continuation: continuation,
            timeoutTimer: timeoutTimer
        )

        return true
    }

    private func timeoutPendingRequest(sessionId: String, id: String) {
        if let pending = removePendingRequest(sessionId: sessionId, id: id) {
            pending.continuation.resume(
                throwing: MCPError.serverError(code: -32000, message: "Request timeout")
            )
        }
    }

    /// Removes and returns a pending request, releasing its timeout timer.
    /// Cancelling after the timer has fired is safe and unregisters the source.
    private func removePendingRequest(
        sessionId: String,
        id: String
    ) -> PendingRequest? {
        let key = PendingRequestKey(sessionId: sessionId, requestId: id)
        let pending = pendingRequests.removeValue(forKey: key)
        pending?.timeoutTimer.cancel()
        return pending
    }

    /// Cleans up all pending requests for a terminated session
    private func cleanupPendingRequests(for sessionId: String) {
        let keysToRemove = pendingRequests.keys.filter { $0.sessionId == sessionId }
        for key in keysToRemove {
            guard let pending = pendingRequests.removeValue(forKey: key) else { continue }
            pending.timeoutTimer.cancel()
            pending.continuation.resume(
                throwing: MCPError.serverError(code: -32000, message: "Session terminated")
            )
        }
    }

    private func configureRoutingIfNeeded() async {
        guard !routingConfigured else { return }

        await sessionManager.setResponseHandler { [weak self] sessionId, data in
            await self?.handleServerResponse(sessionId: sessionId, data: data)
        }

        await sessionManager.setSessionTerminationHandler { [weak self] sessionId in
            await self?.sseManager.terminateSession(sessionId: sessionId)
            await self?.cleanupPendingRequests(for: sessionId)
        }

        routingConfigured = true
    }

    private func buildApplication() -> some ApplicationProtocol {
        let router = Router(context: BasicRequestContext.self)

        router.add(middleware: OriginValidationMiddleware())

        router.post("/") { request, context in
            try await self.handlePost(request: request, context: context)
        }
        router.get("/") { request, context in
            try await self.handleGet(request: request, context: context)
        }
        router.delete("/") { request, context in
            try await self.handleDelete(request: request, context: context)
        }

        return Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port)
            ),
            logger: logger
        )
    }

    private nonisolated func acceptsStreamableHTTP(_ accept: String) -> Bool {
        if accept.contains("*/*") { return true }
        return accept.contains("application/json") && accept.contains("text/event-stream")
    }

    private func validateProtocolVersionHeader(
        request: Request,
        isInitialize: Bool
    ) async -> Response? {
        let versionHeader = request.headers[.mcpProtocolVersion]

        if let versionHeader {
            guard MCPProtocolVersion.supported.contains(versionHeader) else {
                return errorResponse(
                    status: .badRequest,
                    // Only reachable with arbitrary client input, so the clamp
                    // is load-bearing here: keep a garbage header from bloating
                    // the response and the log. Serialization already makes any
                    // content safe.
                    message: "Unsupported protocol version: \(String(versionHeader.prefix(64)))",
                    code: -32600
                )
            }
        }

        guard !isInitialize else { return nil }

        guard let sessionId = request.headers[.mcpSessionId],
            let negotiated = await sessionManager.protocolVersion(for: sessionId)
        else {
            return nil
        }

        if MCPProtocolVersion.requiresHeaderAfterInitialize.contains(negotiated) {
            guard let versionHeader else {
                return errorResponse(
                    status: .badRequest,
                    message: "Missing MCP-Protocol-Version header for negotiated protocol version \(negotiated)",
                    code: -32600
                )
            }

            guard versionHeader == negotiated else {
                return errorResponse(
                    status: .badRequest,
                    message: "MCP-Protocol-Version header \(versionHeader) does not match negotiated version \(negotiated)",
                    code: -32600
                )
            }
        }

        return nil
    }

    private nonisolated func parseInitializeProtocolVersion(from json: [String: Any]) -> String? {
        guard let params = json["params"] as? [String: Any],
            let version = params["protocolVersion"] as? String,
            MCPProtocolVersion.supported.contains(version)
        else {
            return nil
        }
        return version
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

    /// Canonicalizes the JSON-RPC id to a collision-free string form.
    /// Type-tagged so `1` and `"1"` (both legal, distinct ids) never collide.
    /// Total: never traps, whatever the client sends.
    ///
    /// The previous form forced a Double id through a non-failable Int
    /// conversion, which trapped on any id outside Int's range.
    /// `{"id": 1e300}` on an unauthenticated POST aborted the whole
    /// launchd service.
    ///
    /// Branch order matters: `["id": 1]` bridges to NSNumber, and on Apple
    /// platforms both `as? Int` and `as? Double` succeed for integral
    /// NSNumbers, so Int must be tested first to keep `1` in the `i:` space.
    nonisolated static func parseJsonRpcId(from json: [String: Any]) -> String {
        guard let id = json["id"] else {
            return "u:\(UUID().uuidString)"  // No id, so generate a unique key
        }
        if let stringId = id as? String {
            return "s:\(stringId)"
        }
        if let intId = id as? Int {
            return "i:\(intId)"
        }
        if let doubleId = id as? Double {
            if let exact = Int(exactly: doubleId) {
                return "i:\(exact)"  // 2.0 and 2 are the same JSON number
            }
            return "d:\(doubleId)"  // fractional or out-of-Int-range; no trap
        }
        if id is NSNull {
            return "n:null"
        }
        return "u:\(UUID().uuidString)"
    }

    /// Creates a JSON-RPC error response
    private nonisolated func errorResponse(status: HTTPResponse.Status, message: String, code: Int = -32600) -> Response
    {
        // Serialize rather than interpolate. The old form escaped only `"`,
        // so a client-controlled message containing a backslash or a control
        // character produced malformed, injectable JSON.
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
            "id": NSNull(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object))
            ?? Data(#"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"},"id":null}"#.utf8)
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}

// MARK: - Supporting Types

/// Types of JSON-RPC messages
private enum JSONRPCMessageType {
    case request
    case notification
    case response
}

// MARK: - HTTPField.Name Extensions

extension HTTPField.Name {
    static let mcpSessionId = HTTPField.Name("Mcp-Session-Id")!
    static let connection = HTTPField.Name("Connection")!

    /// MCP protocol version header
    static let mcpProtocolVersion = HTTPField.Name("MCP-Protocol-Version")!

    /// Mcp-Method request-metadata header (2026-07-28)
    static let mcpMethod = HTTPField.Name("Mcp-Method")!

    /// Mcp-Name request-metadata header (2026-07-28)
    static let mcpName = HTTPField.Name("Mcp-Name")!
}

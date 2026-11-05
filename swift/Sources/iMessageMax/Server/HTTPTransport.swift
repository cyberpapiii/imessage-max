import Foundation
import Hummingbird
import HTTPTypes
import Logging
import MCP
import NIOCore
import ServiceLifecycle
import UnixSignals

/// MCP Streamable HTTP server (Hummingbird): POST for both eras, GET-SSE and
/// DELETE for legacy sessions, each session with its own SDK Server.
actor HTTPTransport {
    /// Production uses the defaults; tests shrink them.
    struct Configuration: Sendable {
        var requestTimeout: Duration = .seconds(300)
        var bodyReadDeadline: Duration = .seconds(30)
        var channelIdleTimeout: Duration = .seconds(60)
        /// Concurrent-session cap, forwarded to `SessionManager`.
        var maxSessions = 512
        var cleanupInterval: Duration = .seconds(300)
        var sessionTimeout: TimeInterval = 3600
        var sseKeepAliveInterval: Duration = .seconds(30)
        /// Builds each legacy session's SDK Server.
        var makeServer: @Sendable (ToolCatalog) async -> Server = { await Version.makeServer(catalog: $0) }
    }

    let host: String
    let port: Int

    private let configuration: Configuration
    private let sessionManager: SessionManager
    private let sseManager: SSEConnectionManager
    private let catalog: ToolCatalog
    private let setupPermissions: SetupPermissionService
    /// Maps (session, JSON-RPC id) to the POST waiting for the SDK's answer.
    private let pendingRequests: PendingRequestRegistry
    private var isConnected = false
    private var routingConfigured = false
    private var serverTask: Task<Void, Error>?
    private var serviceGroup: ServiceGroup?

    /// Hummingbird and ServiceLifecycle require a Logger. Diagnostics go
    /// through `Log`, so theirs stays silent.
    private static let silentLogger = Logger(label: "imessage-max.http", factory: { _ in SwiftLogNoOpLogHandler() })

    /// Bounds a SIGTERM drain. It stays under launchd's default 20 s
    /// ExitTimeOut, so the service exits on its own instead of by SIGKILL.
    static let maximumGracefulShutdownDuration: Duration = .seconds(15)

    init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        catalog: ToolCatalog,
        setupPermissions: SetupPermissionService,
        configuration: Configuration = .init()
    ) {
        self.host = host
        self.port = port
        self.configuration = configuration
        self.catalog = catalog
        self.setupPermissions = setupPermissions
        self.pendingRequests = PendingRequestRegistry(timeout: configuration.requestTimeout)
        let makeServer = configuration.makeServer
        self.sessionManager = SessionManager(
            makeServer: { await makeServer(catalog) },
            sessionTimeout: configuration.sessionTimeout,
            maxSessions: configuration.maxSessions,
            cleanupInterval: configuration.cleanupInterval
        )
        self.sseManager = SSEConnectionManager(keepAliveInterval: configuration.sseKeepAliveInterval)
    }

    /// Starts listening. SIGTERM and SIGINT trigger a graceful shutdown;
    /// tests pass no signals so the test process keeps its own handlers.
    func connect(gracefulShutdownSignals: [UnixSignal] = [.sigterm, .sigint]) async throws {
        guard !isConnected else { return }

        let app = await application()

        // ServiceGroup shuts services down last-first, so the stream closer
        // runs before the server starts waiting for open requests to finish.
        var groupConfiguration = ServiceGroupConfiguration(
            services: [app, SSEShutdownService(transport: self)],
            gracefulShutdownSignals: gracefulShutdownSignals,
            logger: Self.silentLogger
        )
        groupConfiguration.maximumGracefulShutdownDuration = Self.maximumGracefulShutdownDuration
        let group = ServiceGroup(configuration: groupConfiguration)
        serviceGroup = group
        serverTask = Task {
            try await group.run()
        }
    }

    /// Blocks until the server terminates, propagating any errors, so a
    /// crashed server exits the process and launchd restarts it.
    func waitForTermination() async throws {
        guard let task = serverTask else { return }
        try await task.value
    }

    /// Does what SIGTERM does, waits for the server to exit, then ends every
    /// session and fails whatever is still pending.
    func shutdown() async {
        await serviceGroup?.triggerGracefulShutdown()
        _ = try? await serverTask?.value
        isConnected = false
        for sessionId in await sessionManager.activeSessionIds() {
            await sessionManager.terminateSession(sessionId: sessionId)
        }
        await pendingRequests.removeAll()
    }

    /// The router-backed application, with session routing wired up.
    /// `connect` serves it; tests drive it in-process.
    func application() async -> some ApplicationProtocol {
        await configureRoutingIfNeeded()
        isConnected = true

        let router = Router(context: BasicRequestContext.self)
        router.add(middleware: OriginValidationMiddleware(boundHost: host))
        router.post("/") { request, _ in
            try await self.handlePost(request: request)
        }
        router.post("/setup/permissions") { request, _ in
            try await self.handleSetupPermission(request: request)
        }
        router.get("/") { request, _ in
            await self.handleGet(request: request)
        }
        router.delete("/") { request, _ in
            await self.handleDelete(request: request)
        }

        return Application(
            router: router,
            server: .http1(configuration: .init(idleTimeout: .nanoseconds(Int64(AsyncTimeout.nanoseconds(for: configuration.channelIdleTimeout))))),
            configuration: .init(address: .hostname(host, port: port)),
            logger: Self.silentLogger
        )
    }

    @discardableResult
    func notifyNewMessages(maxRowid: Int64) async -> Int {
        await sessionManager.notifyAllSessions(
            Message<NewMessagesNotification>(
                method: NewMessagesNotification.name,
                params: .init(max_rowid: maxRowid)
            )
        )
    }

    /// Ends every open SSE stream. An SSE GET never finishes on its own, and
    /// graceful shutdown waits for open requests, so without this a single
    /// connected client kept the process alive until launchd's SIGKILL.
    fileprivate func closeAllSSEStreams() async {
        for sessionId in await sessionManager.activeSessionIds() {
            await sseManager.terminateSession(sessionId: sessionId)
        }
    }

    // MARK: - POST

    private func handlePost(request: Request) async throws -> Response {
        guard let contentType = request.headers[.contentType],
            contentType.contains("application/json")
        else {
            return errorResponse(.unsupportedMediaType, "Invalid Content-Type, expected application/json")
        }

        // Streamable HTTP clients advertise both response shapes because a
        // request can complete as JSON or as an SSE stream.
        guard let accept = request.headers[.accept],
            HTTPRequestParsing.acceptsStreamableHTTP(accept)
        else {
            return errorResponse(.notAcceptable, "Invalid Accept header, expected application/json and text/event-stream")
        }

        let requestData: Data
        switch try await HTTPRequestParsing.collectBodyDrainingOverflow(
            request.body,
            declaredLength: request.headers[.contentLength].flatMap(Int.init),
            maxBytes: HTTPRequestParsing.maxRequestBodyBytes,
            drainLimit: HTTPRequestParsing.overLimitDrainBytes,
            deadline: configuration.bodyReadDeadline
        ) {
        case .complete(let data):
            requestData = data
        case .tooLarge:
            // Same observable shape as the old `collect(upTo:)` throw that
            // Hummingbird converted to 413: empty body, Content-Length: 0.
            return Response(status: .contentTooLarge)
        case .timedOut:
            return errorResponse(.requestTimeout, "Request body read timed out")
        }

        switch JSONRPCMessage.parse(requestData) {
        case .batch:
            return errorResponse(.badRequest, "Batch requests are not supported")
        case .invalid:
            return errorResponse(.badRequest, "Invalid JSON")
        case .message(let message) where message.era == .modern:
            return await handleModernPost(request: request, message: message)
        case .message(let message):
            return await handleLegacyPost(request: request, message: message, requestData: requestData)
        }
    }

    private func handleLegacyPost(request: Request, message: JSONRPCMessage, requestData: Data) async -> Response {
        if let versionError = await validateProtocolVersionHeader(request: request, isInitialize: message.isInitialize) {
            return versionError
        }

        let sessionId: String
        var responseHeaders = HTTPFields()
        responseHeaders[.contentType] = "application/json"

        if message.isInitialize {
            // Capacity refusal is retryable (503); startup failure is an
            // internal fault (500).
            let version = LegacyProtocol.negotiate(message.params?["protocolVersion"] as? String)
            switch await sessionManager.createSession(protocolVersion: version) {
            case .created(let session):
                sessionId = session.id
                responseHeaders[.mcpSessionId] = sessionId
                EraLog.legacy(message, transport: "http", version: version, session: sessionId)
            case .atCapacity:
                return errorResponse(
                    .serviceUnavailable,
                    """
                    Session capacity reached. Reuse an existing session, terminate unused \
                    sessions with DELETE and their Mcp-Session-Id, or retry after idle \
                    sessions expire.
                    """
                )
            case .startFailed:
                return errorResponse(.internalServerError, "Failed to start session. Check the server log.")
            }
        } else {
            guard let requestSessionId = request.headers[.mcpSessionId] else {
                return errorResponse(.badRequest, "Missing Mcp-Session-Id header")
            }
            // 404 tells the client to re-initialize (spec).
            guard await sessionManager.validate(sessionId: requestSessionId) != nil else {
                return errorResponse(.notFound, "Invalid or expired session. Please re-initialize.")
            }
            sessionId = requestSessionId
            await sessionManager.touch(sessionId: sessionId)
            responseHeaders[.mcpSessionId] = sessionId
            EraLog.legacy(
                message,
                transport: "http",
                version: request.headers[.mcpProtocolVersion] ?? "legacy",
                session: sessionId
            )
        }

        // A `tools/call` needs nothing that the session's own Server holds:
        // handlers live in the catalog and the result fields are identical in
        // both eras. Answering it here skips routing the request into the SDK,
        // which re-encodes the whole response through Codable `Value` on the
        // way out. That round-trip cost about 9 ms of the 26 ms a 12 kB
        // list_chats reply took on this lane. Anything malformed falls through
        // to the SDK, which owns the error wording.
        if message.kind == .request, message.method == "tools/call", let toolName = message.toolName {
            return await legacyToolCallResponse(message: message, name: toolName, sessionId: sessionId, headers: responseHeaders)
        }

        switch message.kind {
        case .request:
            return await forwardRequest(requestData, key: message.requestKey, sessionId: sessionId, headers: responseHeaders)
        case .notification, .response:
            guard await sessionManager.routeMessage(sessionId: sessionId, data: requestData) else {
                return errorResponse(.notFound, "Session no longer valid")
            }
            return Response(status: .accepted, headers: responseHeaders)
        }
    }

    /// Routes a request to the session's Server and waits for its answer.
    private func forwardRequest(_ requestData: Data, key: String?, sessionId: String, headers: HTTPFields) async -> Response {
        do {
            // An id that is not a JSON scalar can never be matched to the
            // SDK's answer, so it fails the way an unanswered request does.
            guard let key else { throw MCPError.serverError(code: JSONRPCErrorCode.serverError.rawValue, message: "Request timeout") }
            let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                Task {
                    guard await self.pendingRequests.store(sessionId: sessionId, id: key, continuation: continuation) else {
                        continuation.resume(
                            throwing: MCPError.serverError(
                                code: JSONRPCErrorCode.invalidRequest.rawValue,
                                message: "Duplicate in-flight JSON-RPC request id: \(key)"
                            )
                        )
                        return
                    }
                    let routed = await self.sessionManager.routeMessage(sessionId: sessionId, data: requestData)
                    if !routed, let pending = await self.pendingRequests.remove(sessionId: sessionId, id: key)
                    {
                        pending.resume(throwing: MCPError.connectionClosed)
                    }
                }
            }
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: responseData)))
        } catch {
            Log.error("Request handling failed: \(error)")
            return errorResponse(.internalServerError, ClientErrorMessages.internalError)
        }
    }

    /// Legacy-era `tools/call`, answered without the session's Server.
    ///
    /// The envelope mirrors what the SDK's CallTool handler produced: `content`
    /// always, `structuredContent` only for a single JSON-object text block,
    /// `isError` only when the tool failed, and an unknown tool as a
    /// method-not-found error rather than a result.
    private func legacyToolCallResponse(message: JSONRPCMessage, name: String, sessionId: String, headers: HTTPFields) async -> Response {
        let id = message.id ?? NSNull()
        let body: Data
        switch await ToolCallDispatch.perform(
            name: name,
            arguments: message.toolArguments,
            lane: .legacyHTTP(session: sessionId),
            catalog: catalog
        ) {
        case .unknownTool:
            let detail = "Unknown tool: \(name)"
            body = JSONRPC.error(id: id, code: .methodNotFound, message: "Method not found: \(detail)", data: ["detail": detail])
        case .completed(let outcome):
            do {
                body = try JSONRPC.success(id: id, result: ToolCallDispatch.resultJSON(outcome))
            } catch {
                Log.error("legacy tools/call serialization failed for \(name)")
                return errorResponse(.internalServerError, ClientErrorMessages.internalError)
            }
        }
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: body)))
    }

    private func handleModernPost(request: Request, message: JSONRPCMessage) async -> Response {
        // Header requirements for notification POSTs are undefined in this
        // revision; accept with no body.
        guard message.kind == .request else {
            return Response(status: .accepted)
        }
        if let mismatch = Self.headerMismatch(request: request, message: message) {
            return Self.response(for: .error(mismatch, .headerMismatch))
        }
        return Self.response(for: await ModernDispatcher.handle(message, transport: "http", catalog: catalog))
    }

    /// Enforces the required Streamable HTTP request-metadata headers
    /// (`MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`) and their
    /// header/body consistency, per the spec's "Server Validation" section.
    /// The spec names `resources/read` and `prompts/get` too; they are checked
    /// even though they then answer method-not-found.
    /// Returns the HeaderMismatch error envelope, or nil when valid.
    private static func headerMismatch(request: Request, message: JSONRPCMessage) -> Data? {
        let method = message.method ?? ""

        func mismatch(_ text: String) -> Data {
            JSONRPC.error(id: message.id, code: .headerMismatch, message: text)
        }

        guard let headerVersion = request.headers[.mcpProtocolVersion] else {
            return mismatch("Missing required MCP-Protocol-Version header")
        }
        if let bodyVersion = message.modernProtocolVersion, bodyVersion != headerVersion {
            return mismatch(
                "Header mismatch: MCP-Protocol-Version header value '\(headerVersion)' does not match body value '\(bodyVersion)'"
            )
        }

        guard let headerMethod = request.headers[.mcpMethod] else {
            return mismatch("Missing required Mcp-Method header")
        }
        guard headerMethod == method else {
            return mismatch("Header mismatch: Mcp-Method header value '\(headerMethod)' does not match body value '\(method)'")
        }

        if ["tools/call", "resources/read", "prompts/get"].contains(method) {
            guard let rawName = request.headers[.mcpName] else {
                return mismatch("Missing required Mcp-Name header")
            }
            let headerName = HTTPRequestParsing.decodeBase64Sentinel(rawName)
            let bodyName = message.toolName ?? (message.params?["uri"] as? String) ?? ""
            guard headerName == bodyName else {
                return mismatch("Header mismatch: Mcp-Name header value '\(headerName)' does not match body value '\(bodyName)'")
            }
        }

        return nil
    }

    /// The Streamable HTTP status the spec gives each modern outcome.
    static func status(for reply: ModernReply) -> HTTPResponse.Status {
        switch reply {
        case .accepted: .accepted
        case .result: .ok
        case .error(_, .methodNotFound): .notFound
        case .error: .badRequest
        }
    }

    private static func response(for reply: ModernReply) -> Response {
        guard let body = reply.body else {
            return Response(status: status(for: reply))
        }
        return Response(
            status: status(for: reply),
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: body))
        )
    }

    // MARK: - GET (SSE) and DELETE

    func handleGet(request: Request) async -> Response {
        guard let accept = request.headers[.accept], accept.contains("text/event-stream") else {
            return errorResponse(.notAcceptable, "Invalid Accept header, expected text/event-stream")
        }
        guard let sessionId = request.headers[.mcpSessionId] else {
            return errorResponse(.badRequest, "Missing Mcp-Session-Id header")
        }
        guard await sessionManager.validate(sessionId: sessionId) != nil else {
            return errorResponse(.notFound, "Invalid or expired session. Please re-initialize.")
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
        let sessionManager = self.sessionManager

        return Response(
            status: .ok,
            headers: responseHeaders,
            body: .init { writer in
                // The stream includes keep-alives. A write error means the
                // client went away.
                do {
                    for await event in channel.stream {
                        try await writer.write(ByteBuffer(string: event))
                        // An open stream is a live client, even one that only
                        // listens. Keep-alives land every 30s, so its session
                        // never looks idle to expiry or reclaim.
                        await sessionManager.touch(sessionId: sessionId)
                    }
                    // Hummingbird only ends the response on finish. Without
                    // it a server-side close left the client's stream open.
                    try await writer.finish(nil)
                } catch {}
                await sseManager.unregister(connectionId: connectionId)
            }
        )
    }

    private func handleDelete(request: Request) async -> Response {
        guard let sessionId = request.headers[.mcpSessionId] else {
            return errorResponse(.badRequest, "Missing Mcp-Session-Id header")
        }
        guard await sessionManager.validate(sessionId: sessionId) != nil else {
            return errorResponse(.notFound, "Invalid or expired session")
        }

        // Cancels the session's task, stops its SDK Server (2 s bound), and
        // drops it from the table. SSE and pending requests are separate.
        await sessionManager.terminateSession(sessionId: sessionId)
        await sseManager.terminateSession(sessionId: sessionId)
        await pendingRequests.cleanup(for: sessionId)
        return Response(status: .noContent)
    }

    /// Answers from a session's Server: the reply to a waiting POST, or else
    /// a server-initiated message for the session's SSE streams.
    private func handleServerResponse(sessionId: String, data: Data) async {
        guard isConnected else { return }

        guard case .message(let message) = JSONRPCMessage.parse(data) else {
            Log.warning("session \(sessionId.prefix(8)) Server sent a non-object message; dropped")
            return
        }

        // Removing through the registry also cancels the timeout timer.
        if let key = message.requestKey,
            let pending = await pendingRequests.remove(sessionId: sessionId, id: key)
        {
            pending.resume(returning: data)
        } else {
            let event = SSEEvent(
                id: UUID().uuidString,
                event: "message",
                data: String(data: data, encoding: .utf8) ?? ""
            )
            await sseManager.broadcast(sessionId: sessionId, event: event.formatted())
        }
    }

    // MARK: - Setup permission route

    private func handleSetupPermission(request: Request) async throws -> Response {
        guard HostBindingPolicy.isLoopback(host) else { return Response(status: .notFound) }
        // Browser requests are never setup requests, including loopback origins.
        // The explicit header forces a browser preflight; no CORS is offered.
        guard request.headers[.origin] == nil,
              request.headers[.setupRequest] == "permission-request-v1" else {
            return Response(status: .forbidden)
        }
        guard request.headers[.contentType]?.lowercased() == "application/json" else {
            return Response(status: .unsupportedMediaType)
        }
        let data: Data
        switch try await HTTPRequestParsing.collectBodyDrainingOverflow(request.body,
            declaredLength: request.headers[.contentLength].flatMap(Int.init),
            maxBytes: 256, drainLimit: 1024, deadline: .seconds(5)) {
        case .complete(let body): data = body
        case .tooLarge: return Response(status: .contentTooLarge)
        case .timedOut: return Response(status: .requestTimeout)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              json.count == 1, let name = json["permission"], let permission = SetupPermission(rawValue: name) else {
            return Response(status: .badRequest)
        }
        do {
            let result = try await setupPermissions.request(permission)
            let body = try JSONEncoder().encode(result)
            return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                body: .init(byteBuffer: .init(bytes: body)))
        } catch SetupPermissionService.RequestError.alreadyRequesting {
            return Response(status: .conflict)
        }
    }

    // MARK: - Helpers

    private func configureRoutingIfNeeded() async {
        guard !routingConfigured else { return }

        await sessionManager.setResponseHandler { [weak self] sessionId, data in
            await self?.handleServerResponse(sessionId: sessionId, data: data)
        }

        await sessionManager.setSessionTerminationHandler { [weak self] sessionId in
            await self?.sseManager.terminateSession(sessionId: sessionId)
            await self?.pendingRequests.cleanup(for: sessionId)
        }

        routingConfigured = true
    }

    private func validateProtocolVersionHeader(request: Request, isInitialize: Bool) async -> Response? {
        let versionHeader = request.headers[.mcpProtocolVersion]

        if let versionHeader, !LegacyProtocol.supported.contains(versionHeader) {
            // Only reachable with arbitrary client input, so the clamp is
            // load-bearing: keep a garbage header from bloating the response
            // and the log.
            return errorResponse(.badRequest, "Unsupported protocol version: \(String(versionHeader.prefix(64)))")
        }

        guard !isInitialize,
            let sessionId = request.headers[.mcpSessionId],
            let negotiated = await sessionManager.protocolVersion(for: sessionId),
            LegacyProtocol.requiresHeaderAfterInitialize.contains(negotiated)
        else {
            return nil
        }

        guard let versionHeader else {
            return errorResponse(.badRequest, "Missing MCP-Protocol-Version header for negotiated protocol version \(negotiated)")
        }
        guard versionHeader == negotiated else {
            return errorResponse(
                .badRequest,
                "MCP-Protocol-Version header \(versionHeader) does not match negotiated version \(negotiated)"
            )
        }
        return nil
    }

    /// A transport-level failure: the HTTP status carries the meaning, the
    /// body is a JSON-RPC error with a null id.
    private nonisolated func errorResponse(
        _ status: HTTPResponse.Status,
        _ message: String,
        code: JSONRPCErrorCode = .invalidRequest
    ) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: JSONRPC.error(id: nil, code: code, message: message)))
        )
    }
}

/// Waits for graceful shutdown, then closes the transport's SSE streams.
private struct SSEShutdownService: Service {
    let transport: HTTPTransport

    func run() async throws {
        try await gracefulShutdown()
        await transport.closeAllSSEStreams()
    }
}

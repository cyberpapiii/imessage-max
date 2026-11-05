import Foundation
import Hummingbird
import HTTPTypes
import IMessageMaxContract
import Logging
import MCP
import NIOCore
import ServiceLifecycle
import UnixSignals

/// MCP Streamable HTTP server (Hummingbird): POST for both eras, GET-SSE and
/// DELETE for legacy sessions, each session with its own SDK Server.
actor HTTPTransport {
    /// Production uses the defaults; tests shrink them. The only place these
    /// values are written: `SessionManager` and the SSE types take them from
    /// here.
    struct Configuration: Sendable {
        var requestTimeout: Duration = .seconds(300)
        var bodyReadDeadline: Duration = .seconds(30)
        var channelIdleTimeout: Duration = .seconds(60)
        /// Concurrent-session cap. A session costs about half a kilobyte of
        /// resident memory (measured across 100 live sessions), so the cap is
        /// a guard against runaway clients rather than a resource limit; 100
        /// turned a fleet of agents that each open their own session into
        /// 503s within seconds.
        var maxSessions = 512
        /// Idle span after which a session may be reclaimed to admit a new
        /// client once `maxSessions` is reached.
        var reclaimableIdle: TimeInterval = 300
        /// Expired-session sweep period. Tests shrink it so a leftover sweep
        /// task cannot pin a `swift test --parallel` worker for five minutes.
        var cleanupInterval: Duration = .seconds(300)
        /// Idle TTL before a session is reaped.
        var sessionTimeout: TimeInterval = 3600
        /// SSE heartbeat spacing. It also keeps a listen-only client's
        /// session from looking idle.
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
    /// Legacy `tools/call`s answered here rather than by the session's SDK
    /// Server, by (session, JSON-RPC id), for `notifications/cancelled`.
    private let inFlightToolCalls = InFlightRequests<PendingRequestRegistry.Key>()
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
        host: String = ServiceDefaults.host,
        port: Int = ServiceDefaults.port,
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
        self.sessionManager = SessionManager(catalog: catalog, configuration: configuration)
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
    /// session (which closes its streams and fails its waiting requests).
    func shutdown() async {
        await serviceGroup?.triggerGracefulShutdown()
        _ = try? await serverTask?.value
        isConnected = false
        for sessionId in await sessionManager.activeSessionIds() {
            await sessionManager.terminateSession(sessionId: sessionId)
        }
        // A POST that stored its entry as its session ended.
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
        router.post(RouterPath(SetupPermissionRoute.path)) { request, _ in
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
        // list_chats reply took on this lane. A call without a string name or
        // with non-object arguments falls through to the SDK, which owns the
        // error wording for malformed params.
        if message.kind == .request, message.method == "tools/call", let toolName = message.toolName,
            !message.hasMalformedToolArguments
        {
            return await legacyToolCallResponse(message: message, name: toolName, sessionId: sessionId, headers: responseHeaders)
        }

        switch message.kind {
        case .request:
            return await forwardRequest(requestData, message: message, sessionId: sessionId, headers: responseHeaders)
        case .notification, .response:
            // The SDK cancels the requests it holds; the calls answered here
            // it never saw, so cancel those directly.
            if let cancelled = message.cancelledRequestKey {
                inFlightToolCalls.cancel(PendingRequestRegistry.Key(sessionId: sessionId, requestId: cancelled))
            }
            guard await sessionManager.routeMessage(sessionId: sessionId, data: requestData) else {
                return errorResponse(.notFound, "Session no longer valid")
            }
            return Response(status: .accepted, headers: responseHeaders)
        }
    }

    /// Routes a request to the session's Server and waits for its answer.
    /// A malformed or reused id is the client's error (400, with the id when
    /// it has one); a timeout or a session that ends first is ours (500).
    private func forwardRequest(_ requestData: Data, message: JSONRPCMessage, sessionId: String, headers: HTTPFields) async -> Response {
        // An id that is not a JSON scalar can never be matched to the SDK's
        // answer.
        guard let key = message.requestKey else {
            return errorResponse(.badRequest, "Invalid Request: id must be a string, a number, or null")
        }
        do {
            let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                Task {
                    guard await self.pendingRequests.store(sessionId: sessionId, id: key, continuation: continuation) else {
                        continuation.resume(throwing: DuplicateRequestId())
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
        } catch is DuplicateRequestId {
            return errorResponse(
                .badRequest,
                "Invalid Request: id is already in use by a request in flight on this session",
                id: JSONRPC.fallbackId(for: message.id)
            )
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
    ///
    /// The call runs in its own task, listed in `inFlightToolCalls`, so a
    /// `notifications/cancelled` for its id cancels it the way the SDK cancels
    /// a stdio call: the tool stops and the reply is its cancelled result.
    private func legacyToolCallResponse(message: JSONRPCMessage, name: String, sessionId: String, headers: HTTPFields) async -> Response {
        let id = message.id ?? NSNull()
        let arguments = message.toolArguments
        let catalog = self.catalog
        let call = inFlightToolCalls.start(
            message.requestKey.map { PendingRequestRegistry.Key(sessionId: sessionId, requestId: $0) }
        ) {
            await ToolCallDispatch.execute(name: name, arguments: arguments, lane: .legacyHTTP(session: sessionId), catalog: catalog)
        }
        let execution = await inFlightToolCalls.finish(call)

        let body: Data
        switch execution {
        case .unknownTool:
            body = JSONRPC.error(id: id, ToolCallDispatch.unknownToolError(name))
        case .completed(let content, let isError):
            do {
                body = try JSONRPC.success(id: id, result: ToolCallDispatch.resultJSON(content: content, isError: isError))
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
                        // listens. Keep-alives land every
                        // `sseKeepAliveInterval`, so its session never looks
                        // idle to expiry or reclaim.
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

        // Stops the session's SDK Server (2 s bound), drops it from the
        // table, and through the termination handler closes its SSE streams
        // and fails its waiting requests.
        await sessionManager.terminateSession(sessionId: sessionId)
        return Response(status: .noContent)
    }

    /// Answers from a session's Server: the reply to a waiting POST, or else
    /// a server-initiated message for the session's SSE streams. Internal so
    /// tests can inject a server-initiated message.
    func handleServerResponse(sessionId: String, data: Data) async {
        guard isConnected else { return }

        guard case .message(let message) = JSONRPCMessage.parse(data) else {
            Log.warning("session \(sessionId.prefix(8)) Server sent a non-object message; dropped")
            return
        }

        // Only a response answers a POST. A server-initiated request carries
        // an id from the Server's own sequence, which can equal a waiting
        // client id. Removing through the registry also cancels the timer.
        if message.kind == .response, let key = message.requestKey,
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
              request.headers[.setupRequest] == SetupPermissionRoute.headerValue else {
            return Response(status: .forbidden)
        }
        guard request.headers[.contentType]?.lowercased() == "application/json" else {
            return Response(status: .unsupportedMediaType)
        }
        let data: Data
        switch try await HTTPRequestParsing.collectBodyDrainingOverflow(request.body,
            declaredLength: request.headers[.contentLength].flatMap(Int.init),
            maxBytes: SetupPermissionRoute.maxRequestBytes, drainLimit: 1024, deadline: .seconds(5)) {
        case .complete(let body): data = body
        case .tooLarge: return Response(status: .contentTooLarge)
        case .timedOut: return Response(status: .requestTimeout)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              json.count == 1, let name = json[SetupPermissionRoute.bodyKey],
              let permission = SetupPermission(rawValue: name) else {
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
            LegacyProtocol.requiresHeaderAfterInitialize(negotiated)
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
    /// body is a JSON-RPC error, with a null id unless the request's is known.
    private nonisolated func errorResponse(
        _ status: HTTPResponse.Status,
        _ message: String,
        code: JSONRPCErrorCode = .invalidRequest,
        id: Any? = nil
    ) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: JSONRPC.error(id: id, code: code, message: message)))
        )
    }
}

/// A request reused the id of one still waiting on the same session.
private struct DuplicateRequestId: Error {}

/// Waits for graceful shutdown, then closes the transport's SSE streams.
private struct SSEShutdownService: Service {
    let transport: HTTPTransport

    func run() async throws {
        try await gracefulShutdown()
        await transport.closeAllSSEStreams()
    }
}

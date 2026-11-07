import Foundation
import Hummingbird
import HTTPTypes
import IMessageMaxContract
import Logging
import MCP
import NIOCore
import ServiceLifecycle
import UnixSignals

actor HTTPTransport {
    struct Configuration: Sendable {
        var requestTimeout: Duration = .seconds(300)
        var bodyReadDeadline: Duration = .seconds(30)
        var channelIdleTimeout: Duration = .seconds(60)
        var maxSessions = 512
        var reclaimableIdle: TimeInterval = 300
        var cleanupInterval: Duration = .seconds(300)
        var sessionTimeout: TimeInterval = 3600
        var sseKeepAliveInterval: Duration = .seconds(30)
        var makeServer: @Sendable (ToolCatalog) async -> Server = { await Version.makeServer(catalog: $0) }
    }

    let host: String
    let port: Int

    private let accessToken: AccessToken
    private let configuration: Configuration
    private let sessionManager: SessionManager
    private let sseManager: SSEConnectionManager
    private let catalog: ToolCatalog
    private let setupPermissions: SetupPermissionService
    private let pendingRequests: PendingRequestRegistry
    private let inFlightToolCalls = InFlightRequests<PendingRequestRegistry.Key>()
    private var isConnected = false
    private var routingConfigured = false
    private var serverTask: Task<Void, Error>?
    private var serviceGroup: ServiceGroup?
    private var shutdownDeadline: DispatchSourceTimer?

    private static let silentLogger = Logger(label: "imessage-max.http", factory: { _ in SwiftLogNoOpLogHandler() })

    /// Bounds a SIGTERM drain. It stays under launchd's default 20 s
    /// ExitTimeOut, so the service exits on its own instead of by SIGKILL.
    static let maximumGracefulShutdownDuration: Duration = .seconds(15)

    init(
        host: String = ServiceDefaults.host,
        port: Int = ServiceDefaults.port,
        accessToken: AccessToken,
        catalog: ToolCatalog,
        setupPermissions: SetupPermissionService,
        configuration: Configuration = .init()
    ) {
        self.host = host
        self.port = port
        self.accessToken = accessToken
        self.configuration = configuration
        self.catalog = catalog
        self.setupPermissions = setupPermissions
        self.pendingRequests = PendingRequestRegistry(timeout: configuration.requestTimeout)
        self.sessionManager = SessionManager(catalog: catalog, configuration: configuration)
        self.sseManager = SSEConnectionManager(keepAliveInterval: configuration.sseKeepAliveInterval)
    }

    func connect(gracefulShutdownSignals: [UnixSignal] = [.sigterm, .sigint]) async throws {
        guard !isConnected else { return }

        let app = await application()

        // ServiceGroup shuts services down last-first, so the stream closer
        // runs before the server starts waiting for open requests to finish.
        // The group gets no maximumGracefulShutdownDuration: ServiceGroup
        // enforces it with a Task.sleep child, and cancelling that sleep when
        // shutdown ends aborts release builds in swift_task_dealloc (#27).
        // GracefulShutdownService arms a Dispatch timer for the bound instead.
        let group = ServiceGroup(configuration: ServiceGroupConfiguration(
            services: [app, GracefulShutdownService(transport: self)],
            gracefulShutdownSignals: gracefulShutdownSignals,
            logger: Self.silentLogger
        ))
        serviceGroup = group
        serverTask = Task {
            defer { disarmShutdownDeadline() }
            try await group.run()
        }
    }

    func waitForTermination() async throws {
        guard let task = serverTask else { return }
        try await task.value
    }

    func shutdown() async {
        await serviceGroup?.triggerGracefulShutdown()
        _ = try? await serverTask?.value
        isConnected = false
        for sessionId in await sessionManager.activeSessionIds() {
            await sessionManager.terminateSession(sessionId: sessionId)
        }
        await pendingRequests.removeAll()
    }

    func application() async -> some ApplicationProtocol {
        await configureRoutingIfNeeded()
        isConnected = true

        let router = Router(context: BasicRequestContext.self)
        router.add(middleware: OriginValidationMiddleware(boundHost: host))
        router.add(middleware: BearerAuthMiddleware(token: accessToken))
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

    fileprivate func beginGracefulShutdown() async {
        armShutdownDeadline()
        await sseManager.closeAll()
    }

    /// Cancels the service group if the drain outlasts
    /// `maximumGracefulShutdownDuration`, as ServiceGroup's own bound would.
    private func armShutdownDeadline() {
        guard shutdownDeadline == nil, let serverTask else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.setEventHandler { serverTask.cancel() }
        timer.schedule(deadline: .now() + AsyncTimeout.dispatchInterval(for: Self.maximumGracefulShutdownDuration))
        timer.resume()
        shutdownDeadline = timer
    }

    private func disarmShutdownDeadline() {
        shutdownDeadline?.cancel()
        shutdownDeadline = nil
    }

    private func handlePost(request: Request) async throws -> Response {
        guard let contentType = request.headers[.contentType],
            contentType.contains("application/json")
        else {
            return errorResponse(.unsupportedMediaType, "Invalid Content-Type, expected application/json")
        }

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
            guard await sessionManager.validate(sessionId: requestSessionId) else {
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

        switch message.kind {
        case .request:
            guard let requestId = message.requestKey else {
                return errorResponse(.badRequest, "Invalid Request: id must be a string, a number, or null")
            }
            let key = PendingRequestRegistry.Key(sessionId: sessionId, requestId: requestId)
            if message.method == "tools/call", let toolName = message.toolName, !message.hasMalformedToolArguments {
                return await legacyToolCallResponse(message: message, name: toolName, key: key, headers: responseHeaders)
            }
            return await forwardRequest(requestData, message: message, key: key, headers: responseHeaders)
        case .notification, .response:
            if let cancelled = message.cancelledRequestKey {
                inFlightToolCalls.cancel(PendingRequestRegistry.Key(sessionId: sessionId, requestId: cancelled))
            }
            guard await sessionManager.routeMessage(sessionId: sessionId, data: requestData) else {
                return errorResponse(.notFound, "Session no longer valid")
            }
            return Response(status: .accepted, headers: responseHeaders)
        }
    }

    private func idInUseResponse(_ message: JSONRPCMessage) -> Response {
        errorResponse(
            .badRequest,
            "Invalid Request: id is already in use by a request in flight on this session",
            id: JSONRPC.fallbackId(for: message.id)
        )
    }

    private func forwardRequest(
        _ requestData: Data, message: JSONRPCMessage, key: PendingRequestRegistry.Key, headers: HTTPFields
    ) async -> Response {
        guard !inFlightToolCalls.isInFlight(key) else { return idInUseResponse(message) }
        let sessionId = key.sessionId, id = key.requestId
        do {
            let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                Task {
                    guard await self.pendingRequests.store(sessionId: sessionId, id: id, continuation: continuation) else {
                        continuation.resume(throwing: DuplicateRequestId())
                        return
                    }
                    let routed = await self.sessionManager.routeMessage(sessionId: sessionId, data: requestData)
                    if !routed, let pending = await self.pendingRequests.remove(sessionId: sessionId, id: id)
                    {
                        pending.resume(throwing: MCPError.connectionClosed)
                    }
                }
            }
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: responseData)))
        } catch is DuplicateRequestId {
            return idInUseResponse(message)
        } catch {
            Log.error("Request handling failed: \(error)")
            return errorResponse(.internalServerError, ClientErrorMessages.internalError)
        }
    }

    private func legacyToolCallResponse(
        message: JSONRPCMessage, name: String, key: PendingRequestRegistry.Key, headers: HTTPFields
    ) async -> Response {
        let id = message.id ?? NSNull()
        let arguments = message.toolArguments
        let catalog = self.catalog
        let sessionId = key.sessionId
        guard await !pendingRequests.isPending(sessionId: sessionId, id: key.requestId),
            let call = inFlightToolCalls.startUnlessInFlight(key, {
                await ToolCallDispatch.execute(name: name, arguments: arguments, lane: .legacyHTTP(session: sessionId), catalog: catalog)
            })
        else {
            return idInUseResponse(message)
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
        guard message.kind == .request else {
            return Response(status: .accepted)
        }
        if let mismatch = Self.headerMismatch(request: request, message: message) {
            return Self.response(for: .error(mismatch, .headerMismatch))
        }
        return Self.response(for: await ModernDispatcher.handle(message, transport: "http", catalog: catalog))
    }

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

    func handleGet(request: Request) async -> Response {
        guard let accept = request.headers[.accept], accept.contains("text/event-stream") else {
            return errorResponse(.notAcceptable, "Invalid Accept header, expected text/event-stream")
        }
        guard let sessionId = request.headers[.mcpSessionId] else {
            return errorResponse(.badRequest, "Missing Mcp-Session-Id header")
        }
        guard await sessionManager.validate(sessionId: sessionId) else {
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
        guard await sessionManager.validate(sessionId: sessionId) else {
            await sseManager.unregister(connectionId: connectionId)
            return errorResponse(.notFound, "Invalid or expired session. Please re-initialize.")
        }

        return Response(
            status: .ok,
            headers: responseHeaders,
            body: .init { writer in
                do {
                    for await event in channel.stream {
                        try await writer.write(ByteBuffer(string: event))
                        await sessionManager.touch(sessionId: sessionId)
                    }
                    // Hummingbird ends the response only on finish. Without
                    // this call, a server-side close left the client's stream open.
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
        guard await sessionManager.validate(sessionId: sessionId) else {
            return errorResponse(.notFound, "Invalid or expired session")
        }

        await sessionManager.terminateSession(sessionId: sessionId)
        return Response(status: .noContent)
    }

    func handleServerResponse(sessionId: String, data: Data) async {
        guard isConnected else { return }

        guard case .message(let message) = JSONRPCMessage.parse(data) else {
            Log.warning("session \(sessionId.prefix(8)) Server sent a non-object message; dropped")
            return
        }

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

    private func handleSetupPermission(request: Request) async throws -> Response {
        guard HostBindingPolicy.isLoopback(host) else { return Response(status: .notFound) }
        // Browser requests are never setup requests, including loopback origins.
        // The explicit header forces a browser preflight, and the server offers no CORS.
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

private struct DuplicateRequestId: Error {}

private struct GracefulShutdownService: Service {
    let transport: HTTPTransport

    func run() async throws {
        try await gracefulShutdown()
        await transport.beginGracefulShutdown()
    }
}

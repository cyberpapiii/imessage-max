import Foundation

actor HelperBridge {
    private let transport: HelperTransport
    private let timeout: TimeInterval
    private let idFactory: @Sendable () -> String

    init(transport: HelperTransport,
         timeout: TimeInterval = 10,
         idFactory: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.transport = transport
        self.timeout = timeout
        self.idFactory = idFactory
    }

    func createGroupChat(addresses: [String],
                         service: String = "iMessage") async -> Result<String, HelperError> {
        let id = idFactory()
        let req = HelperRequest.createChat(id: id, addresses: addresses, service: service)
        switch await send(req) {
        case .failure(let e): return .failure(e)
        case .success(let resp):
            guard let guid = resp.chatGuid else {
                return .failure(.malformedResponse("create-chat ok but no chat_guid"))
            }
            return .success(guid)
        }
    }

    func sendText(chatGuid: String, body: String) async -> Result<Void, HelperError> {
        let req = HelperRequest.sendText(id: idFactory(), chatGuid: chatGuid, body: body)
        return await send(req).map { _ in () }
    }

    func sendFile(chatGuid: String, path: String) async -> Result<Void, HelperError> {
        let req = HelperRequest.sendFile(id: idFactory(), chatGuid: chatGuid, path: path)
        return await send(req).map { _ in () }
    }

    func probe() async -> Bool {
        guard await transport.isConnected() else { return false }
        switch await send(.ping(id: idFactory())) {
        case .success(let resp): return resp.ok
        case .failure: return false
        }
    }

    private func send(_ request: HelperRequest) async -> Result<HelperResponse, HelperError> {
        let data: Data
        do { data = try HelperWire.encode(request) }
        catch { return .failure(.malformedResponse("encode failed: \(error)")) }

        let responseData: Data
        do { responseData = try await transport.roundTrip(data, timeout: timeout) }
        catch let e as HelperError { return .failure(e) }
        catch { return .failure(.malformedResponse("transport error: \(error)")) }

        let resp: HelperResponse
        do { resp = try HelperWire.decode(responseData) }
        catch { return .failure(.malformedResponse("decode failed: \(error)")) }

        guard resp.v == helperProtocolVersion else {
            return .failure(.protocolMismatch(expected: helperProtocolVersion, got: resp.v))
        }
        guard resp.id == request.id else {
            return .failure(.idMismatch(expected: request.id, got: resp.id))
        }
        if !resp.ok {
            let err = resp.error ?? HelperWireError(code: "unknown", message: "ok=false, no error body")
            return .failure(.remote(code: err.code, message: err.message))
        }
        return .success(resp)
    }
}

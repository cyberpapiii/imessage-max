import Foundation

let helperProtocolVersion = 1

enum HelperCommand: String, Codable, Sendable {
    case ping
    case createChat = "create-chat"
    case sendText = "send-text"
    case sendFile = "send-file"
}

struct HelperRequest: Codable, Equatable, Sendable {
    var v: Int = helperProtocolVersion
    let id: String
    let cmd: HelperCommand
    var addresses: [String]?
    var service: String?
    var chatGuid: String?
    var body: String?
    var path: String?

    enum CodingKeys: String, CodingKey {
        case v, id, cmd, addresses, service
        case chatGuid = "chat_guid"
        case body, path
    }

    static func ping(id: String) -> HelperRequest {
        HelperRequest(id: id, cmd: .ping)
    }
    static func createChat(id: String, addresses: [String], service: String) -> HelperRequest {
        HelperRequest(id: id, cmd: .createChat, addresses: addresses, service: service)
    }
    static func sendText(id: String, chatGuid: String, body: String) -> HelperRequest {
        HelperRequest(id: id, cmd: .sendText, chatGuid: chatGuid, body: body)
    }
    static func sendFile(id: String, chatGuid: String, path: String) -> HelperRequest {
        HelperRequest(id: id, cmd: .sendFile, chatGuid: chatGuid, path: path)
    }
}

struct HelperWireError: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

struct HelperResponse: Codable, Equatable, Sendable {
    let v: Int
    let id: String
    let ok: Bool
    var chatGuid: String?
    var error: HelperWireError?

    enum CodingKeys: String, CodingKey {
        case v, id, ok
        case chatGuid = "chat_guid"
        case error
    }
}

enum HelperWire {
    static func encode(_ request: HelperRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A) // '\n'
        return data
    }
    static func decode(_ line: Data) throws -> HelperResponse {
        try JSONDecoder().decode(HelperResponse.self, from: line)
    }
}

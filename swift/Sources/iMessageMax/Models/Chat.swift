// Sources/iMessageMax/Models/Chat.swift
import Foundation

struct Chat: Codable {
    let id: String          // "chat123"
    let guid: String?
    let displayName: String?
    let serviceName: String?
    let participantCount: Int
    let isGroup: Bool
    let lastMessage: LastMessage?

    struct LastMessage: Codable {
        let text: String?
        let ts: String          // ISO timestamp
        let fromMe: Bool
    }
}

// Sources/iMessageMax/Models/Participant.swift
import Foundation

struct Participant: Codable {
    let handle: String
    let name: String?
    let service: String?
    let inContacts: Bool
}


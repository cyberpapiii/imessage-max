import Foundation

struct PeopleMap {
    struct Rules {
        enum Collision {
            case appendPosition
            case appendCounter
        }

        let collision: Collision
        let unnamedPrefix: String

        static let participants = Rules(collision: .appendPosition, unnamedPrefix: "unknown")
        static let seen = Rules(collision: .appendCounter, unnamedPrefix: "p")
    }

    struct Person {
        let key: String
        let handle: String?
        let name: String?
        var isMe: Bool { handle == nil }
    }

    static let meKey = "me"

    let rules: Rules
    private(set) var people: [Person] = []
    private(set) var keyByHandle: [String: String] = [:]
    private var taken: Set<String> = []
    private var unnamedCount = 0

    init(rules: Rules) {
        self.rules = rules
    }

    mutating func addMe() {
        guard taken.insert(Self.meKey).inserted else { return }
        people.append(Person(key: Self.meKey, handle: nil, name: "Me"))
    }

    @discardableResult
    mutating func add(handle: String, name: String?, position: Int = 0) -> String {
        if let key = keyByHandle[handle] { return key }

        var key: String
        if let name {
            let base = (name.split(separator: " ").first.map(String.init) ?? name).lowercased()
            key = unique(base, position: position)
        } else {
            repeat {
                unnamedCount += 1
                key = "\(rules.unnamedPrefix)\(unnamedCount)"
            } while taken.contains(key)
        }
        taken.insert(key)
        keyByHandle[handle] = key
        people.append(Person(key: key, handle: handle, name: name))
        return key
    }

    private func unique(_ base: String, position: Int) -> String {
        guard taken.contains(base) else { return base }
        var suffix: Int
        switch rules.collision {
        case .appendPosition: suffix = position
        case .appendCounter: suffix = 2
        }
        while taken.contains("\(base)\(suffix)") { suffix += 1 }
        return "\(base)\(suffix)"
    }

    func labels(noHandle: String) -> SenderLabels {
        SenderLabels(
            me: Self.meKey,
            noHandle: noHandle,
            names: keyByHandle,
            missingSender: .handle,
            missingReactor: .label("unknown")
        )
    }
}

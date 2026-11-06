import Foundation

/// Short keys for the people a response names, so each message says
/// `"from": "alice"` and the full name appears once in `people`.
///
/// get_messages and get_context have always keyed people differently, and
/// clients may hold on to either form, so the two rules stay explicit.
struct PeopleMap {
    struct Rules {
        enum Collision {
            /// `alice`, then `alice<n>` where n is the person's position in the chat.
            case appendPosition
            /// `alice`, then `alice2`, `alice3`, ...
            case appendCounter
        }

        let collision: Collision
        /// Prefix for people without a contact name: `unknown1`, `p1`, ...
        let unnamedPrefix: String

        /// get_messages: every chat participant, keyed in participant order.
        static let participants = Rules(collision: .appendPosition, unnamedPrefix: "unknown")
        /// get_context: only the people the window shows, keyed as they appear.
        static let seen = Rules(collision: .appendCounter, unnamedPrefix: "p")
    }

    struct Person {
        let key: String
        let handle: String?
        /// Contact name; nil when the handle has none.
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

    /// The key for `handle`, adding it on first sight. `position` is the
    /// handle's index among the chat's participants (`appendPosition` only).
    @discardableResult
    mutating func add(handle: String, name: String?, position: Int = 0) -> String {
        if let key = keyByHandle[handle] { return key }

        // Every candidate is checked against `taken`: a contact named
        // "Unknown B" can claim `unknown1` before an unnamed handle does.
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

    /// `noHandle` is the label for a received message with a NULL handle.
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

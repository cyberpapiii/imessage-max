# iMessage Max Swift Rewrite - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rewrite iMessage Max from Python to Swift for maximum performance and single-binary distribution.

**Architecture:** Single Swift Package with organized source folders. Raw SQLite3 for database, native CNContactStore for contacts, Core Image for media processing. MCP protocol via official swift-sdk.

**Tech Stack:** Swift 6.0, MCP Swift SDK 0.10.x, Swift Argument Parser, SQLite3, Contacts.framework, CoreImage, AVFoundation

---

## Phase 1: Project Scaffolding (Serial - Must Complete First)

### Task 1.1: Initialize Swift Package

**Files:**
- Create: `swift/Package.swift`
- Create: `swift/Sources/iMessageMax/main.swift`
- Create: `swift/README.md`

**Step 1: Create Swift package directory structure**

```bash
mkdir -p swift/Sources/iMessageMax/{Server,Database,Contacts,Tools,Enrichment,Models,Utilities}
mkdir -p swift/Tests/iMessageMaxTests
mkdir -p swift/.github/workflows
```

**Step 2: Create Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "imessage-max",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "imessage-max", targets: ["iMessageMax"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "iMessageMax",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/iMessageMax"
        ),
        .testTarget(
            name: "iMessageMaxTests",
            dependencies: ["iMessageMax"],
            path: "Tests/iMessageMaxTests"
        ),
    ]
)
```

**Step 3: Create minimal main.swift**

```swift
// Sources/iMessageMax/main.swift
import Foundation

@main
struct iMessageMax {
    static func main() async throws {
        print("iMessage Max Swift - Starting...")
    }
}
```

**Step 4: Verify build**

Run: `cd swift && swift build`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add swift/
git commit -m "feat: initialize Swift package structure"
```

---

## Phase 2: Core Infrastructure (Parallelizable)

### Task 2.1: Database Layer - Connection & Safety

**Files:**
- Create: `swift/Sources/iMessageMax/Database/Database.swift`
- Create: `swift/Sources/iMessageMax/Database/SQLiteRow.swift`
- Create: `swift/Sources/iMessageMax/Database/Errors.swift`
- Test: `swift/Tests/iMessageMaxTests/DatabaseTests.swift`

**Step 1: Create database errors**

```swift
// Sources/iMessageMax/Database/Errors.swift
import Foundation

enum DatabaseError: LocalizedError {
    case permissionDenied(String)
    case notFound(String)
    case queryFailed(String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let path):
            return "Permission denied accessing \(path). Grant Full Disk Access in System Settings."
        case .notFound(let path):
            return "Database not found at \(path). Ensure iMessage is set up."
        case .queryFailed(let msg):
            return "Query failed: \(msg)"
        case .invalidData(let msg):
            return "Invalid data: \(msg)"
        }
    }
}
```

**Step 2: Create SQLiteRow wrapper**

```swift
// Sources/iMessageMax/Database/SQLiteRow.swift
import Foundation
import SQLite3

struct SQLiteRow {
    private let stmt: OpaquePointer

    init(_ stmt: OpaquePointer) {
        self.stmt = stmt
    }

    func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(stmt, column)
    }

    func optionalInt(_ column: Int32) -> Int64? {
        if sqlite3_column_type(stmt, column) == SQLITE_NULL {
            return nil
        }
        return sqlite3_column_int64(stmt, column)
    }

    func string(_ column: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cstr)
    }

    func blob(_ column: Int32) -> Data? {
        guard let ptr = sqlite3_column_blob(stmt, column) else { return nil }
        let size = sqlite3_column_bytes(stmt, column)
        return Data(bytes: ptr, count: Int(size))
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(stmt, column)
    }
}
```

**Step 3: Create Database wrapper**

```swift
// Sources/iMessageMax/Database/Database.swift
import Foundation
import SQLite3

final class Database: @unchecked Sendable {
    static let defaultPath: String = {
        ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath
    }()

    private let path: String

    init(path: String = Database.defaultPath) {
        self.path = path
    }

    // MARK: - Access Check

    static func checkAccess(path: String = defaultPath) -> (ok: Bool, status: String) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else {
            return (false, "database_not_found")
        }

        guard fm.isReadableFile(atPath: path) else {
            return (false, "permission_denied")
        }

        // Try to actually open
        var db: OpaquePointer?
        let result = sqlite3_open_v2(
            "file:\(path)?mode=ro",
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        )

        if let db = db {
            sqlite3_close(db)
        }

        if result == SQLITE_OK {
            return (true, "accessible")
        } else {
            return (false, "permission_denied")
        }
    }

    // MARK: - Query Execution

    func query<T>(
        _ sql: String,
        params: [Any] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        let conn = try openReadOnly()
        defer { sqlite3_close(conn) }

        let stmt = try prepare(conn, sql: sql, params: params)
        defer { sqlite3_finalize(stmt) }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            try results.append(map(SQLiteRow(stmt)))
        }
        return results
    }

    func execute(_ sql: String, params: [Any] = []) throws {
        let conn = try openReadOnly()
        defer { sqlite3_close(conn) }

        let stmt = try prepare(conn, sql: sql, params: params)
        defer { sqlite3_finalize(stmt) }

        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE && result != SQLITE_ROW {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(conn)))
        }
    }

    // MARK: - Private

    private func openReadOnly() throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: path) else {
            throw DatabaseError.notFound(path)
        }

        var db: OpaquePointer?
        let result = sqlite3_open_v2(
            "file:\(path)?mode=ro",
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        )

        guard result == SQLITE_OK, let db = db else {
            throw DatabaseError.permissionDenied(path)
        }

        // Safety settings
        sqlite3_busy_timeout(db, 1000)
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, &errMsg)

        return db
    }

    private func prepare(
        _ conn: OpaquePointer,
        sql: String,
        params: [Any]
    ) throws -> OpaquePointer {
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(conn)))
        }

        // Bind parameters
        for (index, param) in params.enumerated() {
            let idx = Int32(index + 1)
            switch param {
            case let value as Int:
                sqlite3_bind_int64(stmt, idx, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(stmt, idx, value)
            case let value as String:
                sqlite3_bind_text(stmt, idx, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let value as Double:
                sqlite3_bind_double(stmt, idx, value)
            case let value as Data:
                value.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case is NSNull:
                sqlite3_bind_null(stmt, idx)
            default:
                sqlite3_bind_null(stmt, idx)
            }
        }

        return stmt
    }
}
```

**Step 4: Commit**

```bash
git add swift/Sources/iMessageMax/Database/
git commit -m "feat: add SQLite3 database layer with safety wrapper"
```

---

### Task 2.2: Apple Time Utilities

**Files:**
- Create: `swift/Sources/iMessageMax/Database/AppleTime.swift`
- Create: `swift/Sources/iMessageMax/Utilities/TimeUtils.swift`

**Step 1: Create AppleTime conversion**

```swift
// Sources/iMessageMax/Database/AppleTime.swift
import Foundation

enum AppleTime {
    /// Apple epoch: January 1, 2001 00:00:00 UTC
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// Convert Apple nanoseconds timestamp to Date
    static func toDate(_ nanoseconds: Int64?) -> Date? {
        guard let ns = nanoseconds else { return nil }
        let seconds = Double(ns) / 1_000_000_000.0
        return epoch.addingTimeInterval(seconds)
    }

    /// Convert Date to Apple nanoseconds timestamp
    static func fromDate(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    /// Parse various time formats to Apple timestamp
    static func parse(_ input: String) -> Int64? {
        // Try relative formats first: "24h", "7d", "2w"
        if let relative = parseRelative(input) {
            return fromDate(relative)
        }

        // Try ISO 8601
        if let iso = parseISO(input) {
            return fromDate(iso)
        }

        // Try natural language: "yesterday", "last week"
        if let natural = parseNatural(input) {
            return fromDate(natural)
        }

        return nil
    }

    private static func parseRelative(_ input: String) -> Date? {
        let pattern = #"^(\d+)(h|d|w|m)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let numRange = Range(match.range(at: 1), in: input),
              let unitRange = Range(match.range(at: 2), in: input),
              let num = Double(input[numRange]) else {
            return nil
        }

        let unit = String(input[unitRange])
        let seconds: Double
        switch unit {
        case "h": seconds = num * 3600
        case "d": seconds = num * 86400
        case "w": seconds = num * 604800
        case "m": seconds = num * 2592000  // ~30 days
        default: return nil
        }

        return Date().addingTimeInterval(-seconds)
    }

    private static func parseISO(_ input: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: input) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: input)
    }

    private static func parseNatural(_ input: String) -> Date? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)
        let calendar = Calendar.current
        let now = Date()

        switch lower {
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: now)
        case "last week":
            return calendar.date(byAdding: .weekOfYear, value: -1, to: now)
        case "last month":
            return calendar.date(byAdding: .month, value: -1, to: now)
        case "today":
            return calendar.startOfDay(for: now)
        default:
            return nil
        }
    }
}
```

**Step 2: Create TimeUtils for formatting**

```swift
// Sources/iMessageMax/Utilities/TimeUtils.swift
import Foundation

enum TimeUtils {
    /// Format date as compact relative string for AI consumption
    static func formatCompactRelative(_ date: Date?) -> String? {
        guard let date = date else { return nil }

        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }

    /// Format date as ISO 8601 for precise timestamps
    static func formatISO(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
```

**Step 3: Commit**

```bash
git add swift/Sources/iMessageMax/Database/AppleTime.swift swift/Sources/iMessageMax/Utilities/TimeUtils.swift
git commit -m "feat: add Apple epoch time conversion and formatting utilities"
```

---

### Task 2.3: Phone Number Utilities

**Files:**
- Create: `swift/Sources/iMessageMax/Contacts/PhoneUtils.swift`

**Step 1: Create phone number utilities**

```swift
// Sources/iMessageMax/Contacts/PhoneUtils.swift
import Foundation

enum PhoneUtils {
    /// Normalize phone number to E.164 format (+1XXXXXXXXXX)
    static func normalizeToE164(_ input: String) -> String? {
        // Strip all non-digit characters except leading +
        var digits = input.filter { $0.isNumber }
        let hasPlus = input.hasPrefix("+")

        guard !digits.isEmpty else { return nil }

        // Handle US numbers
        if digits.count == 10 {
            // Assume US: add +1
            return "+1\(digits)"
        } else if digits.count == 11 && digits.hasPrefix("1") {
            // US with country code
            return "+\(digits)"
        } else if hasPlus {
            // International with +
            return "+\(digits)"
        } else if digits.count > 10 {
            // Assume international
            return "+\(digits)"
        }

        return nil
    }

    /// Format phone for display: +1 (555) 123-4567
    static func formatDisplay(_ phone: String) -> String {
        guard let normalized = normalizeToE164(phone) else {
            return phone
        }

        // Format US numbers
        if normalized.hasPrefix("+1") && normalized.count == 12 {
            let digits = String(normalized.dropFirst(2))
            let area = digits.prefix(3)
            let exchange = digits.dropFirst(3).prefix(3)
            let subscriber = digits.suffix(4)
            return "+1 (\(area)) \(exchange)-\(subscriber)"
        }

        return normalized
    }

    /// Check if string looks like a phone number
    static func isPhoneNumber(_ input: String) -> Bool {
        let digits = input.filter { $0.isNumber }
        return digits.count >= 10 && digits.count <= 15
    }

    /// Check if string is an email address
    static func isEmail(_ input: String) -> Bool {
        input.contains("@") && input.contains(".")
    }
}
```

**Step 2: Commit**

```bash
git add swift/Sources/iMessageMax/Contacts/PhoneUtils.swift
git commit -m "feat: add phone number normalization and formatting utilities"
```

---

### Task 2.4: Contact Resolver

**Files:**
- Create: `swift/Sources/iMessageMax/Contacts/ContactResolver.swift`

**Step 1: Create ContactResolver actor**

```swift
// Sources/iMessageMax/Contacts/ContactResolver.swift
import Foundation
import Contacts

actor ContactResolver {
    private var cache: [String: String] = [:]
    private var isInitialized = false
    private let store = CNContactStore()

    // MARK: - Authorization

    static func authorizationStatus() -> (authorized: Bool, status: String) {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return (true, "authorized")
        case .denied:
            return (false, "denied")
        case .restricted:
            return (false, "restricted")
        case .notDetermined:
            return (false, "not_determined")
        case .limited:
            return (true, "limited")
        @unknown default:
            return (false, "unknown")
        }
    }

    func requestAccess() async throws -> Bool {
        try await store.requestAccess(for: .contacts)
    }

    // MARK: - Initialization

    func initialize() throws {
        guard !isInitialized else { return }

        let (authorized, _) = Self.authorizationStatus()
        guard authorized else {
            isInitialized = true
            return
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)

        try store.enumerateContacts(with: request) { [self] contact, _ in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            guard !name.isEmpty else { return }

            // Map phone numbers
            for phone in contact.phoneNumbers {
                let number = phone.value.stringValue
                if let normalized = PhoneUtils.normalizeToE164(number) {
                    cache[normalized] = name
                }
            }

            // Map emails
            for email in contact.emailAddresses {
                let addr = (email.value as String).lowercased()
                cache[addr] = name
            }
        }

        isInitialized = true
    }

    // MARK: - Resolution

    func resolve(_ handle: String) -> String? {
        // Direct match
        if let name = cache[handle] {
            return name
        }

        // Try normalized phone
        if let normalized = PhoneUtils.normalizeToE164(handle),
           let name = cache[normalized] {
            return name
        }

        // Try lowercase email
        if handle.contains("@"),
           let name = cache[handle.lowercased()] {
            return name
        }

        return nil
    }

    func searchByName(_ query: String) -> [(handle: String, name: String)] {
        let q = query.lowercased()
        return cache.compactMap { handle, name in
            name.lowercased().contains(q) ? (handle, name) : nil
        }
    }

    // MARK: - Stats

    func getStats() -> (initialized: Bool, handleCount: Int) {
        (isInitialized, cache.count)
    }
}
```

**Step 2: Commit**

```bash
git add swift/Sources/iMessageMax/Contacts/ContactResolver.swift
git commit -m "feat: add CNContactStore contact resolver with caching"
```

---

### Task 2.5: Query Builder

**Files:**
- Create: `swift/Sources/iMessageMax/Database/QueryBuilder.swift`

**Step 1: Create fluent query builder**

```swift
// Sources/iMessageMax/Database/QueryBuilder.swift
import Foundation

final class QueryBuilder {
    private var selectCols: [String] = []
    private var fromTable: String = ""
    private var joins: [String] = []
    private var conditions: [(String, [Any])] = []
    private var groupByCols: [String] = []
    private var orderByCols: [String] = []
    private var limitValue: Int?
    private var offsetValue: Int?

    @discardableResult
    func select(_ columns: String...) -> QueryBuilder {
        selectCols.append(contentsOf: columns)
        return self
    }

    @discardableResult
    func from(_ table: String) -> QueryBuilder {
        fromTable = table
        return self
    }

    @discardableResult
    func join(_ clause: String) -> QueryBuilder {
        joins.append("JOIN \(clause)")
        return self
    }

    @discardableResult
    func leftJoin(_ clause: String) -> QueryBuilder {
        joins.append("LEFT JOIN \(clause)")
        return self
    }

    @discardableResult
    func `where`(_ condition: String, _ params: Any...) -> QueryBuilder {
        conditions.append((condition, params))
        return self
    }

    @discardableResult
    func groupBy(_ columns: String...) -> QueryBuilder {
        groupByCols.append(contentsOf: columns)
        return self
    }

    @discardableResult
    func orderBy(_ columns: String...) -> QueryBuilder {
        orderByCols.append(contentsOf: columns)
        return self
    }

    @discardableResult
    func limit(_ n: Int) -> QueryBuilder {
        limitValue = n
        return self
    }

    @discardableResult
    func offset(_ n: Int) -> QueryBuilder {
        offsetValue = n
        return self
    }

    func build() -> (sql: String, params: [Any]) {
        var parts: [String] = []
        var allParams: [Any] = []

        // SELECT
        parts.append("SELECT \(selectCols.joined(separator: ", "))")

        // FROM
        parts.append("FROM \(fromTable)")

        // JOINs
        parts.append(contentsOf: joins)

        // WHERE
        if !conditions.isEmpty {
            let whereClauses = conditions.map { $0.0 }
            parts.append("WHERE \(whereClauses.joined(separator: " AND "))")
            for (_, params) in conditions {
                allParams.append(contentsOf: params)
            }
        }

        // GROUP BY
        if !groupByCols.isEmpty {
            parts.append("GROUP BY \(groupByCols.joined(separator: ", "))")
        }

        // ORDER BY
        if !orderByCols.isEmpty {
            parts.append("ORDER BY \(orderByCols.joined(separator: ", "))")
        }

        // LIMIT
        if let limit = limitValue {
            parts.append("LIMIT \(limit)")
        }

        // OFFSET
        if let offset = offsetValue {
            parts.append("OFFSET \(offset)")
        }

        return (parts.joined(separator: "\n"), allParams)
    }

    // MARK: - Utility

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
}
```

**Step 2: Commit**

```bash
git add swift/Sources/iMessageMax/Database/QueryBuilder.swift
git commit -m "feat: add fluent SQL query builder"
```

---

### Task 2.6: Data Models

**Files:**
- Create: `swift/Sources/iMessageMax/Models/Chat.swift`
- Create: `swift/Sources/iMessageMax/Models/Message.swift`
- Create: `swift/Sources/iMessageMax/Models/Participant.swift`
- Create: `swift/Sources/iMessageMax/Models/Attachment.swift`
- Create: `swift/Sources/iMessageMax/Models/Reactions.swift`

**Step 1: Create Chat model**

```swift
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
```

**Step 2: Create Message model**

```swift
// Sources/iMessageMax/Models/Message.swift
import Foundation

struct Message: Codable {
    let id: String          // "msg123"
    let guid: String
    let text: String?
    let ts: String          // ISO timestamp
    let from: String        // Short key into people map
    let fromMe: Bool
    let reactions: [String]?    // ["❤️ nick", "😂 andrew"]
    let media: [MediaMetadata]?
    let replyTo: String?
    let edited: Bool?
    let session: String?    // Session grouping
}

struct MediaMetadata: Codable {
    let id: String          // "att123"
    let type: String        // "image", "video", "audio", "file"
    let filename: String?
    let sizeBytes: Int?
    let dimensions: Dimensions?
    let duration: Double?   // For audio/video

    struct Dimensions: Codable {
        let width: Int
        let height: Int
    }
}
```

**Step 3: Create Participant model**

```swift
// Sources/iMessageMax/Models/Participant.swift
import Foundation

struct Participant: Codable {
    let handle: String
    let name: String?
    let service: String?
    let inContacts: Bool
}

/// People map for token-efficient responses
typealias PeopleMap = [String: Participant]
```

**Step 4: Create Attachment model**

```swift
// Sources/iMessageMax/Models/Attachment.swift
import Foundation

struct AttachmentInfo: Codable {
    let id: String
    let filename: String?
    let mimeType: String?
    let uti: String?
    let totalBytes: Int?
    let chat: String?       // "chat123"
    let from: String?       // Short key
    let ts: String?         // ISO timestamp
}
```

**Step 5: Create Reactions mapping**

```swift
// Sources/iMessageMax/Models/Reactions.swift
import Foundation

enum ReactionType: Int {
    case loved = 2000
    case liked = 2001
    case disliked = 2002
    case laughed = 2003
    case emphasized = 2004
    case questioned = 2005

    // Removal types are 3000-3005
    static func isRemoval(_ type: Int) -> Bool {
        type >= 3000 && type < 3006
    }

    var emoji: String {
        switch self {
        case .loved: return "❤️"
        case .liked: return "👍"
        case .disliked: return "👎"
        case .laughed: return "😂"
        case .emphasized: return "‼️"
        case .questioned: return "❓"
        }
    }

    static func fromType(_ type: Int) -> ReactionType? {
        ReactionType(rawValue: type)
    }
}
```

**Step 6: Commit**

```bash
git add swift/Sources/iMessageMax/Models/
git commit -m "feat: add data models for chat, message, participant, attachment, reactions"
```

---

### Task 2.7: Image Processor (Core Image)

**Files:**
- Create: `swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift`

**Step 1: Create ImageProcessor**

```swift
// Sources/iMessageMax/Enrichment/ImageProcessor.swift
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageVariant: String, CaseIterable {
    case vision = "vision"  // 1568px - AI analysis
    case thumb = "thumb"    // 400px - quick preview
    case full = "full"      // original resolution

    var maxDimension: Int? {
        switch self {
        case .vision: return 1568
        case .thumb: return 400
        case .full: return nil
        }
    }
}

struct ImageProcessor {
    private let context: CIContext

    init() {
        self.context = CIContext(options: [
            .useSoftwareRenderer: false,
            .highQualityDownsample: true
        ])
    }

    struct ImageResult {
        let data: Data
        let format: String
        let width: Int
        let height: Int
    }

    struct ImageMetadata {
        let filename: String
        let sizeBytes: Int
        let width: Int
        let height: Int
    }

    /// Get metadata without full processing (fast path)
    func getMetadata(at path: String) -> ImageMetadata? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int
        else { return nil }

        return ImageMetadata(
            filename: url.lastPathComponent,
            sizeBytes: size,
            width: width,
            height: height
        )
    }

    /// Process image to JPEG at specified variant
    func process(at path: String, variant: ImageVariant) -> ImageResult? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        guard let ciImage = CIImage(contentsOf: url) else { return nil }

        var image = ciImage
        let originalSize = ciImage.extent.size

        // Resize if needed
        if let maxDim = variant.maxDimension {
            let scale = min(
                CGFloat(maxDim) / originalSize.width,
                CGFloat(maxDim) / originalSize.height,
                1.0
            )

            if scale < 1.0 {
                image = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }

        // Render to JPEG
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpegData = context.jpegRepresentation(
                  of: image,
                  colorSpace: colorSpace,
                  options: [kCGImageDestinationLossyCompressionQuality: 0.85 as CFNumber]
              )
        else { return nil }

        let finalSize = image.extent.size
        return ImageResult(
            data: jpegData,
            format: "jpeg",
            width: Int(finalSize.width),
            height: Int(finalSize.height)
        )
    }
}
```

**Step 2: Commit**

```bash
git add swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift
git commit -m "feat: add Core Image processor with HEIC support and GPU acceleration"
```

---

### Task 2.8: Video/Audio Processor

**Files:**
- Create: `swift/Sources/iMessageMax/Enrichment/VideoProcessor.swift`
- Create: `swift/Sources/iMessageMax/Enrichment/AudioProcessor.swift`

**Step 1: Create VideoProcessor**

```swift
// Sources/iMessageMax/Enrichment/VideoProcessor.swift
import Foundation
import AVFoundation

struct VideoProcessor {
    func getDuration(at path: String) -> Double? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVAsset(url: url)
        let duration = asset.duration
        return duration.seconds.isFinite ? duration.seconds : nil
    }

    func getThumbnail(at path: String) -> Data? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)

        let time = CMTime(seconds: 0, preferredTimescale: 1)

        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let ciImage = CIImage(cgImage: cgImage)
            let context = CIContext()
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return context.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [:])
        } catch {
            return nil
        }
    }

    struct VideoMetadata {
        let duration: Double
        let width: Int?
        let height: Int?
    }

    func getMetadata(at path: String) -> VideoMetadata? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVAsset(url: url)

        guard let duration = getDuration(at: path) else { return nil }

        var width: Int?
        var height: Int?

        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            width = Int(abs(size.width))
            height = Int(abs(size.height))
        }

        return VideoMetadata(duration: duration, width: width, height: height)
    }
}
```

**Step 2: Create AudioProcessor**

```swift
// Sources/iMessageMax/Enrichment/AudioProcessor.swift
import Foundation
import AVFoundation

struct AudioProcessor {
    func getDuration(at path: String) -> Double? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVAsset(url: url)
        let duration = asset.duration
        return duration.seconds.isFinite ? duration.seconds : nil
    }

    struct AudioMetadata {
        let duration: Double
        let codec: String?
    }

    func getMetadata(at path: String) -> AudioMetadata? {
        guard let duration = getDuration(at: path) else { return nil }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVAsset(url: url)

        var codec: String?
        if let track = asset.tracks(withMediaType: .audio).first {
            for desc in track.formatDescriptions {
                let formatDesc = desc as! CMFormatDescription
                let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
                codec = String(format: "%c%c%c%c",
                              (mediaSubType >> 24) & 0xFF,
                              (mediaSubType >> 16) & 0xFF,
                              (mediaSubType >> 8) & 0xFF,
                              mediaSubType & 0xFF)
                break
            }
        }

        return AudioMetadata(duration: duration, codec: codec)
    }
}
```

**Step 3: Commit**

```bash
git add swift/Sources/iMessageMax/Enrichment/VideoProcessor.swift swift/Sources/iMessageMax/Enrichment/AudioProcessor.swift
git commit -m "feat: add video/audio processors using AVFoundation"
```

---

## Phase 3: MCP Server Integration (Serial)

### Task 3.1: MCP Server Setup

**Files:**
- Modify: `swift/Sources/iMessageMax/main.swift`
- Create: `swift/Sources/iMessageMax/Server/MCPServer.swift`
- Create: `swift/Sources/iMessageMax/Server/ToolRegistry.swift`
- Create: `swift/Sources/iMessageMax/Server/Version.swift`

**Step 1: Create Version**

```swift
// Sources/iMessageMax/Server/Version.swift
import Foundation

enum Version {
    static let current = "1.0.0"
    static let name = "iMessage Max"
}
```

**Step 2: Create ToolRegistry stub**

```swift
// Sources/iMessageMax/Server/ToolRegistry.swift
import Foundation
import MCP

enum ToolRegistry {
    static func registerAll(on server: Server) {
        // Tools will be registered here as they are implemented
    }
}
```

**Step 3: Create MCPServer wrapper**

```swift
// Sources/iMessageMax/Server/MCPServer.swift
import Foundation
import MCP

actor MCPServerWrapper {
    private let server: Server
    private let resolver: ContactResolver

    init() {
        self.server = Server(
            name: Version.name,
            version: Version.current
        )
        self.resolver = ContactResolver()
    }

    func start(transport: Transport) async throws {
        // Startup checks
        await performStartupChecks()

        // Register tools
        ToolRegistry.registerAll(on: server)

        // Run
        try await server.run(transport: transport)
    }

    private func performStartupChecks() async {
        // Check database access
        let (dbOk, dbStatus) = Database.checkAccess()
        if !dbOk {
            FileHandle.standardError.write(
                "[iMessage Max] Database: \(dbStatus)\n".data(using: .utf8)!
            )
        }

        // Initialize contacts
        let (contactsOk, contactsStatus) = ContactResolver.authorizationStatus()
        if !contactsOk && contactsStatus == "not_determined" {
            _ = try? await resolver.requestAccess()
        }
        try? await resolver.initialize()
    }
}
```

**Step 4: Update main.swift**

```swift
// Sources/iMessageMax/main.swift
import Foundation
import ArgumentParser
import MCP

@main
struct iMessageMax: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imessage-max",
        abstract: "MCP server for iMessage",
        version: Version.current
    )

    @Flag(name: .long, help: "Run with HTTP transport instead of stdio")
    var http = false

    @Option(name: .long, help: "Port for HTTP transport (default: 8080)")
    var port: Int = 8080

    mutating func run() async throws {
        let server = MCPServerWrapper()

        let transport: Transport
        if http {
            // TODO: Implement HTTPTransport
            fatalError("HTTP transport not yet implemented")
        } else {
            transport = StdioTransport()
        }

        try await server.start(transport: transport)
    }
}
```

**Step 5: Build and verify**

Run: `cd swift && swift build`
Expected: Build succeeds (may have warnings about MCP SDK integration)

**Step 6: Commit**

```bash
git add swift/Sources/iMessageMax/
git commit -m "feat: add MCP server integration with ArgumentParser CLI"
```

---

## Phase 4: Tool Implementations (Highly Parallelizable)

Each tool can be implemented independently. Below are the 12 tools.

### Task 4.1: diagnose Tool

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/Diagnose.swift`

**Implementation:** Port from `src/imessage_max/server.py:405-475`

```swift
// Sources/iMessageMax/Tools/Diagnose.swift
import Foundation
import MCP

struct DiagnoseTool {
    static let definition = ToolDefinition(
        name: "diagnose",
        description: "Diagnose iMessage MCP configuration and permissions.",
        inputSchema: .object(properties: [:])
    )

    static func execute(input: [String: Any], resolver: ContactResolver) async -> [String: Any] {
        var result: [String: Any] = [:]

        // Version info
        result["version"] = Version.current

        // Process info
        result["process_id"] = ProcessInfo.processInfo.processIdentifier

        // Database access
        let (dbOk, dbStatus) = Database.checkAccess()
        result["database_accessible"] = dbOk
        result["database_status"] = dbStatus
        result["database_path"] = Database.defaultPath

        if !dbOk {
            result["database_fix"] = "Grant Full Disk Access: System Settings → Privacy & Security → Full Disk Access → Add the imessage-max binary"
        }

        // Contacts access
        let (contactsOk, contactsStatus) = ContactResolver.authorizationStatus()
        result["contacts_authorized"] = contactsOk
        result["contacts_status"] = contactsStatus

        if contactsOk {
            let stats = await resolver.getStats()
            result["contacts_loaded"] = stats.handleCount
        } else {
            result["contacts_fix"] = "Grant Contacts access: System Settings → Privacy & Security → Contacts → Add the imessage-max binary"
        }

        // Overall status
        result["status"] = (dbOk && contactsOk) ? "ready" : "needs_setup"

        return result
    }
}
```

**Commit:**
```bash
git add swift/Sources/iMessageMax/Tools/Diagnose.swift
git commit -m "feat: implement diagnose tool"
```

---

### Task 4.2: find_chat Tool

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/FindChat.swift`

**Implementation:** Port from `src/imessage_max/tools/find_chat.py`

[Full implementation ~150 lines - searches by participants, name, recent content]

---

### Task 4.3: get_messages Tool

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/GetMessages.swift`

**Implementation:** Port from `src/imessage_max/tools/get_messages.py`

[Full implementation ~250 lines - retrieves messages with filtering, pagination, sessions]

---

### Task 4.4: list_chats Tool

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/ListChats.swift`

**Implementation:** Port from `src/imessage_max/tools/list_chats.py`

[Full implementation ~120 lines - lists recent chats with previews]

---

### Task 4.5: search Tool

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/Search.swift`

**Implementation:** Port from `src/imessage_max/tools/search.py`

[Full implementation ~200 lines - full-text search with filters]

---

### Task 4.6: get_context Tool

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/GetContext.swift`

**Implementation:** Port from `src/imessage_max/tools/get_context.py`

[Full implementation ~100 lines - get messages surrounding a specific message]

---

### Task 4.7: get_active_conversations Tool

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/GetActiveConversations.swift`

**Implementation:** Port from `src/imessage_max/tools/get_active.py`

[Full implementation ~130 lines - find chats with bidirectional activity]

---

### Task 4.8: list_attachments Tool

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/ListAttachments.swift`

**Implementation:** Port from `src/imessage_max/tools/list_attachments.py`

[Full implementation ~150 lines - list attachments with filters]

---

### Task 4.9: get_unread Tool

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/GetUnread.swift`

**Implementation:** Port from `src/imessage_max/tools/get_unread.py`

[Full implementation ~180 lines - get unread messages or summary]

---

### Task 4.10: send Tool

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/Send.swift`
- Create: `swift/Sources/iMessageMax/Utilities/AppleScript.swift`

**Implementation:** Port from `src/imessage_max/tools/send.py`

[Full implementation ~200 lines - send via NSAppleScript]

---

### Task 4.11: get_attachment Tool

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/GetAttachment.swift`

**Implementation:** Port from `src/imessage_max/tools/get_attachment.py`

[Full implementation ~100 lines - return image at specified variant]

---

### Task 4.12: update Tool

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/Update.swift`

**Implementation:** Port from `src/imessage_max/server.py:478-541`

[Full implementation ~80 lines - check for updates via Homebrew]

---

## Phase 5: HTTP Transport (Serial)

### Task 5.1: Streamable HTTP Transport

**Files:**
- Create: `swift/Sources/iMessageMax/Server/HTTPTransport.swift`

**Implementation:** Implement MCP 2025-03-26 Streamable HTTP spec

[~300 lines - HTTP server with SSE support]

---

## Phase 6: CI/CD & Distribution (Serial)

### Task 6.1: GitHub Actions Workflows

**Files:**
- Create: `swift/.github/workflows/build.yml`
- Create: `swift/.github/workflows/release.yml`

---

### Task 6.2: Homebrew Formula

**Files:**
- Create: `swift/Formula/imessage-max.rb`

---

## Execution Summary

| Phase | Tasks | Parallelizable | Est. Work |
|-------|-------|----------------|-----------|
| 1 | 1.1 | No (must complete first) | 1 task |
| 2 | 2.1-2.8 | Yes (all independent) | 8 tasks |
| 3 | 3.1 | No (depends on Phase 2) | 1 task |
| 4 | 4.1-4.12 | Yes (all independent) | 12 tasks |
| 5 | 5.1 | No | 1 task |
| 6 | 6.1-6.2 | Yes | 2 tasks |

**Total: 25 tasks, up to 20 can run in parallel after Phase 1**

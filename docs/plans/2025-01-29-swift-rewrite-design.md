# iMessage Max Swift Rewrite - Design Document

**Date:** 2025-01-29
**Status:** Approved
**Branch:** `feature/swift-rewrite`

## Executive Summary

Rewrite iMessage Max from Python/FastMCP to Swift for maximum performance, native macOS integration, and single-binary distribution. Maintains 100% feature parity with all 12 MCP tools.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Distribution | Single binary via Homebrew/GitHub | Simplest for users, no runtime deps |
| Transport | stdio + Streamable HTTP | Future-proof, supports remote access |
| MCP SDK | Official swift-sdk v0.10.2 | Anthropic-backed, actively maintained |
| Package structure | Single target, organized folders | Simple build, easy debugging |
| SQLite | Raw SQLite3 + Swift wrapper | Maximum performance (7ms), full control |
| Image processing | Core Image | Hardware-accelerated, native HEIC |
| Concurrency | Swift async/await | Modern, structured, clean cancellation |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      imessage-max binary                        │
├─────────────────────────────────────────────────────────────────┤
│  Transport Layer (MCP SDK)                                      │
│  ├── StdioTransport (primary)                                   │
│  └── StreamableHTTPTransport (optional, --http flag)            │
├─────────────────────────────────────────────────────────────────┤
│  Tool Layer (12 tools)                                          │
│  ├── find_chat, get_messages, list_chats, search               │
│  ├── get_context, get_active_conversations, list_attachments   │
│  ├── get_unread, send, get_attachment, diagnose, update        │
├─────────────────────────────────────────────────────────────────┤
│  Core Services                                                  │
│  ├── Database (SQLite3 wrapper, connection lifecycle)          │
│  ├── ContactResolver (CNContactStore, cached lookups)          │
│  ├── MessageParser (attributedBody extraction)                 │
│  └── Enrichment (Core Image, link preview, audio/video)        │
├─────────────────────────────────────────────────────────────────┤
│  macOS Frameworks                                               │
│  ├── SQLite3, Contacts, CoreImage, Foundation                  │
│  └── NSAppleScript (for send functionality)                    │
└─────────────────────────────────────────────────────────────────┘
```

## Package Structure

```
imessage-max-swift/
├── Package.swift
├── README.md
├── LICENSE
├── .github/
│   └── workflows/
│       ├── build.yml
│       └── release.yml
│
└── Sources/
    └── iMessageMax/
        ├── main.swift
        │
        ├── Server/
        │   ├── MCPServer.swift
        │   ├── StdioTransport.swift
        │   ├── HTTPTransport.swift
        │   └── ToolRegistry.swift
        │
        ├── Database/
        │   ├── Database.swift
        │   ├── Connection.swift
        │   ├── QueryBuilder.swift
        │   ├── AppleTime.swift
        │   └── Schema.swift
        │
        ├── Contacts/
        │   ├── ContactResolver.swift
        │   ├── ContactCache.swift
        │   └── PhoneUtils.swift
        │
        ├── Tools/
        │   ├── FindChat.swift
        │   ├── GetMessages.swift
        │   ├── ListChats.swift
        │   ├── Search.swift
        │   ├── GetContext.swift
        │   ├── GetActiveConversations.swift
        │   ├── ListAttachments.swift
        │   ├── GetUnread.swift
        │   ├── Send.swift
        │   ├── GetAttachment.swift
        │   ├── Diagnose.swift
        │   └── Update.swift
        │
        ├── Enrichment/
        │   ├── ImageProcessor.swift
        │   ├── VideoThumbnail.swift
        │   ├── AudioDuration.swift
        │   └── LinkPreview.swift
        │
        ├── Models/
        │   ├── Chat.swift
        │   ├── Message.swift
        │   ├── Attachment.swift
        │   ├── Participant.swift
        │   └── Reactions.swift
        │
        └── Utilities/
            ├── TimeUtils.swift
            ├── JSONEncoder+MCP.swift
            └── Errors.swift
```

## Component Designs

### 1. Database Layer

Raw SQLite3 wrapped with Swift safety idioms:

```swift
final class Database: Sendable {
    static let path = ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath

    func query<T>(_ sql: String, params: [Any] = [], map: (SQLiteRow) -> T) throws -> [T] {
        let conn = try openReadOnly()
        defer { sqlite3_close(conn) }  // CRITICAL: Always close for Tahoe

        let stmt = try prepare(conn, sql, params)
        defer { sqlite3_finalize(stmt) }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(map(SQLiteRow(stmt)))
        }
        return results
    }
}
```

Key patterns:
- `defer` for automatic cleanup (prevents Tahoe issue)
- Read-only connections with `PRAGMA query_only = ON`
- Connection-per-query lifecycle

### 2. Contact Resolution

Native CNContactStore via Swift actor for thread safety:

```swift
actor ContactResolver {
    private var cache: [String: String] = [:]
    private let store = CNContactStore()

    func resolve(_ handle: String) -> String? {
        if let name = cache[handle] { return name }
        if let normalized = PhoneUtils.normalizeToE164(handle) {
            return cache[normalized]
        }
        return nil
    }
}
```

### 3. Image Processing

Core Image with GPU acceleration:

```swift
struct ImageProcessor {
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func process(at path: String, variant: ImageVariant) -> ImageResult? {
        guard let ciImage = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        // Resize and encode to JPEG
    }
}
```

### 4. MCP Server

Integration with official Swift SDK:

```swift
@main
struct iMessageMax {
    static func main() async throws {
        let server = MCPServer(name: "iMessage Max", version: Version.current)
        ToolRegistry.registerAll(on: server)

        let transport: Transport = args.http
            ? HTTPTransport(port: args.port ?? 8080)
            : StdioTransport()

        try await server.run(transport: transport)
    }
}
```

## Dependencies

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
]
```

Only 2 external dependencies. All other functionality uses system frameworks.

## Distribution

### GitHub Releases
- Universal binary (arm64 + x86_64)
- Automated via GitHub Actions on tag push
- Artifact: `imessage-max-macos.tar.gz`

### Homebrew
```bash
brew install yourusername/tap/imessage-max
```

### Claude Desktop Config
```json
{
  "mcpServers": {
    "imessage": {
      "command": "/opt/homebrew/bin/imessage-max"
    }
  }
}
```

## Migration Path

1. Swift version released as `imessage-max-swift` initially
2. Users can run both versions side-by-side
3. After validation, Swift version becomes primary `imessage-max`
4. Python version deprecated but maintained for compatibility

## Success Criteria

- [ ] All 12 tools pass feature parity tests
- [ ] Startup time < 100ms (vs ~2s Python)
- [ ] Query latency < 10ms for typical operations
- [ ] Single binary < 10MB
- [ ] Zero runtime dependencies
- [ ] Homebrew formula published

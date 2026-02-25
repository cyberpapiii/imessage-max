---
title: "refactor: Comprehensive Audit Improvements"
type: refactor
status: active
date: 2026-02-24
---

# Comprehensive Audit Improvements — iMessage Max MCP Server

## Enhancement Summary

**Deepened on:** 2026-02-24
**Research agents used:** 9 (Security Sentinel, Code Simplicity Reviewer, Pattern Recognition Specialist, Performance Oracle, Architecture Strategist, Agent Native Reviewer, MCP Protocol Researcher, Security Best Practices Researcher, MCP Best Practices Applicator)

### Critical Corrections Found
1. **`MCP-Protocol-Version` is a CLIENT request header, NOT a server response header** — server must VALIDATE it on incoming requests, not add it to outgoing responses
2. **IPv6 parsing has edge case bug** — bare `::1` without brackets would be incorrectly stripped to `:`
3. **Swift SDK 0.11.0 requires `swift-tools-version: 6.1`** — Package.swift must update from 6.0
4. **Origin validation must return 403 Forbidden** (not 400) for invalid Origin headers per spec
5. **`Models/` directory already exists** with 5 files — not a "new directory"
6. **`ListChats.swift` has reversed text extraction priority** — tries `attributedBody` FIRST, unlike all other tools

### Key Improvements Over Original Plan
- Use Hummingbird's built-in `ServiceGroup` for graceful shutdown (not hand-rolled DispatchSource)
- Also fix people keys in `GetActiveConversations` and `Search` (not just `GetContext`)
- Include `\u{FFFC}` → `[Photo]` replacement in `MessageTextExtractor`
- Add `encodeJSON` deduplication to Phase 3 scope
- Complete tool annotations (`send`, `update`) and add `title` to all tools
- Drop `firstNameOnly` parameter — always use first names
- Remove SSE connection limits (YAGNI — session cap suffices)
- Add input length validation in AppleScript layer (defense-in-depth)

---

## Overview

Implement all improvements identified by the 20-agent audit of iMessage Max. Six PRs covering security fixes, bug fixes, code deduplication, HTTP transport spec compliance, SDK upgrade, and hardening. Total scope: ~600 lines changed, ~400 lines removed, 4 new utility files.

## Problem Statement / Motivation

A comprehensive audit identified:
- **1 CRITICAL security vulnerability** (AppleScript injection via string interpolation)
- **3 HIGH bugs** (Search param mismatch, IPv6 origin validation, batch handler deadlock)
- **5 MEDIUM issues** (people key inconsistency across 3 tools, empty group names, duplicated code x5, no graceful shutdown)
- **Protocol gap**: MCP spec 3 versions behind (2025-03-26 → 2025-06-18 → 2025-11-25)
- **SDK gap**: swift-sdk 0.10.0 → 0.11.0 available (released 2026-02-19)

## Technical Approach

### Architecture

All changes are targeted fixes within the existing architecture. No structural changes needed — the architecture is sound. The custom `HTTPTransport` + `SessionManager` + `SSEConnectionManager` is architecturally necessary for per-session `Server` isolation and should be kept (not replaced by SDK's built-in `StatefulHTTPServerTransport`).

### Implementation Phases

#### Phase 1: Security Fix (PR 1)

**AppleScript Injection Fix** — `Utilities/AppleScript.swift`

Replace string interpolation with environment variable passing. This eliminates the entire class of injection vulnerabilities.

```swift
// BEFORE (vulnerable):
let script = """
    tell application "Messages"
        set targetBuddy to participant "\(escapedRecipient)" of targetService
        send "\(escapedMessage)" to targetBuddy
    end tell
    """
process.arguments = ["-e", script]

// AFTER (secure):
let script = """
    set recipientId to system attribute "IMSG_RECIPIENT"
    set messageText to system attribute "IMSG_MESSAGE"
    tell application "Messages"
        set targetService to 1st account whose service type = iMessage
        set targetBuddy to participant recipientId of targetService
        send messageText to targetBuddy
    end tell
    """
process.arguments = ["-e", script]
process.environment = [
    "IMSG_RECIPIENT": recipient,
    "IMSG_MESSAGE": message
]
```

Design decisions:
- **Env var names**: `IMSG_RECIPIENT`, `IMSG_MESSAGE` — prefixed to avoid collision
- **Clean environment**: Pass ONLY the two needed vars. The child process inherits NONE of the parent's env vars. `osascript` does not need `PATH`, `HOME`, or anything else to function.
- **No size limit needed**: macOS `ARG_MAX` is 1,048,576 bytes (1MB) shared between args + env. Messages are always much shorter.
- **UTF-8 safe**: `system attribute` returns env vars as AppleScript text assuming UTF-8.
- **Null byte handling**: Swift String cannot contain null bytes, so this is a non-issue.
- **Remove `escape()` function entirely** — it's no longer needed.

### Research Insights — Phase 1

**Security validation (Security Sentinel):** The env var approach is genuinely injection-proof. User data flows through the OS process environment API, never through the AppleScript parser. The script template is now fully static.

**Defense-in-depth (Security Best Practices):** Add input length validation before passing to the process:
```swift
guard recipient.count <= 100 else { return .failure(.invalidRecipient) }
guard message.count <= 20_000 else { return .failure(.messageTooLong) }
```
iMessage has a practical limit around 20,000 characters. Recipients should never exceed ~100 chars.

**Additional fix (Security Best Practices):** The current `DispatchSemaphore` pattern in `AppleScript.swift` blocks a Swift Concurrency thread. Consider replacing with an async `withTaskGroup` pattern in a future PR.

Files:
- `Utilities/AppleScript.swift` — rewrite `send()` method, delete `escape()`, add input length validation

---

#### Phase 2: Bug Fixes (PR 2)

**2a. Search.swift QueryBuilder Param Fix** — `Tools/Search.swift`

Refactor `buildQuery()` to use QueryBuilder's parameter system exclusively. Remove the manual `params` array.

```swift
// BEFORE (fragile dual-tracking):
let builder = QueryBuilder()
    .where("m.associated_message_type = ?", 0)
var params: [Any] = [0]  // DUPLICATE tracking

// ... later ...
builder.where("m.date >= ?")
params.append(sinceTs)

let (sql, _) = builder.build()  // DISCARDS builder params!
return (sql, params)

// AFTER (single source of truth):
let builder = QueryBuilder()
    .where("m.associated_message_type = ?", 0)

// ... later ...
builder.where("m.date >= ?", sinceTs)

return builder.build()  // Returns (sql, params) correctly
```

Every filter in `buildQuery` (lines 487-553) needs conversion:
- `since` filter: `builder.where("m.date >= ?", sinceTs)`
- `before` filter: `builder.where("m.date <= ?", beforeTs)`
- `inChat` filter: `builder.where("cmj.chat_id = ?", chatId)`
- `fromPerson` filter: `builder.where("h.id LIKE ?", "%\(person)%")`
- `has:link` filter: `builder.where("m.text LIKE ?", "%http%")`
- `isGroup` filter: uses subquery, no params needed
- `unanswered` filter: complex subquery, verify param order

### Research Insights — Phase 2a

**Performance (Performance Oracle):** Zero performance impact — QueryBuilder's `build()` is O(n) string concatenation in sub-microsecond range. Generated SQL is byte-for-byte identical.

**Correctness (Pattern Recognition):** Confirmed this is the exact anti-pattern the QueryBuilder was designed to prevent. `GetMessages.swift` already uses QueryBuilder correctly and serves as the reference pattern.

Files:
- `Tools/Search.swift` — refactor `buildQuery()` (~30 lines changed)

---

**2b. IPv6 Origin Validation Fix** — `Server/OriginValidationMiddleware.swift`

Fix the host parsing to handle IPv6 bracket notation and make validation mandatory.

```swift
// BEFORE (broken for IPv6):
if let authority = request.uri.host {
    let hostWithoutPort = authority.split(separator: ":").first.map(String.init) ?? authority
    guard allowedHosts.contains(hostWithoutPort) else { ... }
}

// AFTER (correct — fixed based on Security Sentinel review):
guard let authority = request.uri.host else {
    return Response(status: .forbidden, ...)  // 403 per MCP spec
}

let hostWithoutPort: String
if authority.hasPrefix("[") {
    // IPv6 bracketed: [::1]:8080 -> [::1]
    if let closeBracket = authority.firstIndex(of: "]") {
        hostWithoutPort = String(authority[authority.startIndex...closeBracket])
    } else {
        hostWithoutPort = authority
    }
} else {
    // IPv4 or hostname: strip port if present
    // Only strip suffix that looks like :<digits>
    if let lastColon = authority.lastIndex(of: ":") {
        let portCandidate = authority[authority.index(after: lastColon)...]
        if !portCandidate.isEmpty && portCandidate.allSatisfy({ $0.isNumber }) {
            hostWithoutPort = String(authority[..<lastColon])
        } else {
            hostWithoutPort = authority
        }
    } else {
        hostWithoutPort = authority
    }
}

guard allowedHosts.contains(hostWithoutPort) else {
    return Response(status: .forbidden, ...)  // 403 per MCP spec
}
```

### Research Insights — Phase 2b

**Bug found (Security Sentinel):** The original plan's code had a bug with bare `::1` (no brackets). The `lastIndex(of: ":")` would find index 1, and `authority[lastColon...].allSatisfy({ $0 == ":" || $0.isNumber })` would pass for `":1"`, stripping it to just `:`. The fixed version above only strips the port when the suffix after the last colon is non-empty and purely numeric.

**Spec compliance (MCP Protocol Research):** MCP spec 2025-11-25 requires 403 Forbidden (not 400) for invalid Origin headers.

**IPv6 normalization (Security Best Practices):** Consider adding `import Network` and using `IPv6Address` to normalize expanded forms like `[0:0:0:0:0:0:0:1]` and IPv4-mapped `::ffff:127.0.0.1`. Low priority for a localhost-only server.

Design decisions:
- `if let` → `guard let` makes host validation mandatory (no bypass on nil)
- Port stripping uses `index(after: lastColon)` to check only the part AFTER the colon
- Returns 403 Forbidden per MCP spec (not 400)

Files:
- `Server/OriginValidationMiddleware.swift` — rewrite host extraction (~20 lines)

---

**2c. People Key Consistency** — `Tools/GetContext.swift`, `Tools/GetActiveConversations.swift`, `Tools/Search.swift`

Change from `p1/p2/p3` keys to name-based keys matching `GetMessages` and `ListAttachments`.

```swift
// BEFORE (in GetContext, GetActiveConversations, Search):
let key = "p\(personCounter)"
personCounter += 1

// AFTER (matching GetMessages pattern):
let name = await resolver.resolve(handle)
let key: String
if let resolvedName = name {
    let firstName = resolvedName.split(separator: " ").first.map(String.init) ?? resolvedName
    key = generateUniqueKey(baseName: firstName.lowercased(), existing: people)
} else {
    key = "p\(personCounter)"
    personCounter += 1
}
```

### Research Insights — Phase 2c

**Agent impact (Agent Native Reviewer):** The `p1/p2` scheme is actively harmful for agent reasoning. An agent calling `get_messages` sees `nick`, then `get_context` sees `p1` for the same person — requires cross-referencing. Name-based keys enable cross-tool reasoning directly.

**Scope expansion (Pattern Recognition + Agent Native):** Three tools need this fix, not just one:
- `GetContext.swift` (line 357) — uses `p1/p2/p3`
- `GetActiveConversations.swift` (line 254) — uses `p0/p1/p2` **globally across all results** (even more confusing)
- `Search.swift` (line 686) — uses `p1/p2/p3`

**Message ID inconsistency (Agent Native):** Also standardize message ID format while touching these files: `GetContext` uses `msg123`, `GetMessages` uses `msg_123`, `Search` uses `msg123`, `GetUnread` uses `msg_123`. Pick one (`msg_123` preferred for readability) and use it everywhere.

Design decisions:
- First name, lowercased (e.g., "nick", "andrew") — matches `GetMessages` exactly
- Collision handling: `nick`, `nick2`, `nick3` — same as `GetMessages`
- Unresolved handles fall back to `p1/p2` (rare case)
- `"me"` key unchanged

Files:
- `Tools/GetContext.swift` — modify people key generation (~20 lines)
- `Tools/GetActiveConversations.swift` — modify people key generation (~15 lines)
- `Tools/Search.swift` — modify people key generation (~15 lines)

---

**2d. Empty Group Chat Names** — `Tools/ListChats.swift`, `Tools/GetMessages.swift`

Fix nil-only check to also catch empty strings and whitespace.

```swift
// BEFORE:
let displayName = chatRow.displayName ?? generateDisplayName(participants)

// AFTER:
let raw = chatRow.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
let displayName = (raw?.isEmpty == false) ? raw! : generateDisplayName(participants)
```

### Research Insights — Phase 2d

**Scope reduction (Code Simplicity):** `FindChat.swift` (line 468-470) already handles this correctly with an explicit `isEmpty` check. Only `ListChats.swift` (line 279) and `GetMessages.swift` (line 412) need the fix.

**Format (Agent Native):** Use plain participant names like "Nick, Andrew, Peter" — no prefix like "Group with". The agent already knows it's a group from participant count or `is_group` field.

Files:
- `Tools/ListChats.swift` — 1 line changed
- `Tools/GetMessages.swift` — 1 line changed

---

#### Phase 3: Code Deduplication (PR 3)

**3a. MessageTextExtractor** — new `Utilities/MessageTextExtractor.swift`

Extract `extractTextFromTypedstream` from 5 files into one shared utility.

```swift
// Utilities/MessageTextExtractor.swift
enum MessageTextExtractor {
    /// Extract displayable text from a message, trying plain text first,
    /// then falling back to attributedBody binary parsing.
    /// Replaces \u{FFFC} (object replacement character) with [Photo].
    static func extract(text: String?, attributedBody: Data?) -> String? {
        if let text = text, !text.isEmpty {
            return text.replacingOccurrences(of: "\u{FFFC}", with: "[Photo]")
        }
        guard let blob = attributedBody else { return nil }
        guard let parsed = extractFromTypedstream(blob) else { return nil }
        return parsed.replacingOccurrences(of: "\u{FFFC}", with: "[Photo]")
    }

    /// Parse Apple typedstream format to extract plain text
    static func extractFromTypedstream(_ data: Data) -> String? {
        // Single canonical implementation (currently duplicated in 5 files)
        guard let nsStringRange = data.range(of: Data("NSString".utf8)) ??
              data.range(of: Data("NSMutableString".utf8)) else { return nil }
        let idx = nsStringRange.upperBound + 5
        guard idx < data.count else { return nil }
        let lengthByte = data[idx]
        let length: Int
        let dataStart: Int
        if lengthByte == 0x81 {
            guard idx + 3 <= data.count else { return nil }
            length = Int(data[idx + 1]) | (Int(data[idx + 2]) << 8)
            dataStart = idx + 3
        } else if lengthByte == 0x82 {
            guard idx + 4 <= data.count else { return nil }
            length = Int(data[idx + 1]) | (Int(data[idx + 2]) << 8) | (Int(data[idx + 3]) << 16)
            dataStart = idx + 4
        } else {
            length = Int(lengthByte)
            dataStart = idx + 1
        }
        guard length > 0 && dataStart + length <= data.count else { return nil }
        return String(data: data[dataStart..<(dataStart + length)], encoding: .utf8)
    }
}
```

### Research Insights — Phase 3a

**FFFC handling (Pattern Recognition):** `GetContext.swift` and `GetUnread.swift` replace `\u{FFFC}` (object replacement character) with `"[Photo]"`. Other tools do NOT. The shared `extract()` method should include this so all callers get improved behavior for free.

**Bug fix (Pattern Recognition):** `ListChats.swift` (line 482-489) has REVERSED priority — tries `attributedBody` FIRST, then falls back to `text`. Every other tool does the opposite. The shared `extract()` method normalizes this to the correct priority (text first).

Remove from: `GetMessages.swift`, `GetContext.swift`, `GetUnread.swift`, `ListChats.swift`, `Search.swift`

---

**3b. DisplayNameGenerator** — new `Utilities/DisplayNameGenerator.swift`

Unify 5 variants with a single `[String]` names parameter.

```swift
enum DisplayNameGenerator {
    /// Generate a display name from an array of resolved participant names.
    /// Always uses first names. Callers extract names from their domain types.
    static func fromNames(_ names: [String]) -> String {
        if names.isEmpty { return "Unknown Chat" }
        if names.count <= 4 {
            return names.joined(separator: ", ")
        }
        let first3 = names.prefix(3).joined(separator: ", ")
        return "\(first3) and \(names.count - 3) others"
    }

    /// Resolve handles to first names, then generate display name.
    static func fromHandles(
        _ handles: [String],
        resolver: ContactResolver
    ) async -> String {
        var names: [String] = []
        for handle in handles {
            if let name = await resolver.resolve(handle) {
                names.append(name.split(separator: " ").first.map(String.init) ?? name)
            } else {
                names.append(PhoneUtils.formatDisplay(handle))
            }
        }
        return fromNames(names)
    }
}
```

### Research Insights — Phase 3b

**Simplification (Code Simplicity + Architecture):** Drop the `firstNameOnly: Bool = true` parameter — every current caller uses first names only. If someone needs full names later, they can add the parameter then. YAGNI.

**Input type (Architecture Strategist):** Accept `[String]` (not a protocol or specific model type). The function's core logic is: "join names with commas; if more than N, show first 3 and 'and X others'". Let callers extract the name array from their domain-specific types. This keeps the utility dependency-free.

**Behavioral variant (Pattern Recognition):** `GetUnread.swift` uses `&` instead of `,` for 2-name chats. Drop this special case for consistency — all other implementations use commas.

Remove from: `FindChat.swift`, `GetMessages.swift`, `GetActiveConversations.swift`, `GetUnread.swift`, `ListChats.swift`

---

**3c. Move AttachmentType to Models/** — `Models/AttachmentType.swift`

Move the existing `AttachmentType` enum from `ListAttachments.swift` to `Models/` (which already exists with `Attachment.swift`, `Chat.swift`, `Message.swift`, `Participant.swift`, `Reactions.swift`) and use it in `GetMessages.swift` and `GetAttachment.swift` (replacing their inline `getAttachmentType()` functions that return `String`).

### Research Insights — Phase 3c

**Architecture (Architecture Strategist):** `Models/` already exists with 5 files. `AttachmentType` is a domain model type, not a utility — it belongs with `Attachment.swift` and `Reactions.swift`.

**Consolidation (Pattern Recognition):** Use the `ListAttachments` version (returns `AttachmentType` enum) as the canonical implementation — it's the most complete. The string-returning versions in `GetMessages.swift` and `GetAttachment.swift` lack some cases (e.g., `GetAttachment` checks for `heic` but `GetMessages` doesn't).

---

**3d. FormatUtils** — new `Utilities/FormatUtils.swift`

Extract `formatFileSize` from 3 files. Also extract `encodeJSON` from 4 files.

```swift
enum FormatUtils {
    static func fileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        else if bytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024.0) }
        else { return String(format: "%.1fMB", Double(bytes) / (1024.0 * 1024.0)) }
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
```

### Research Insights — Phase 3d

**Format consistency (Pattern Recognition):** `GetAttachment.formatSize` uses `"45KB"` (no space) while `GetMessages.formatFileSize` uses `"45.0 KB"` (with space). Use the compact form without spaces — it's more token-efficient for AI consumption.

**encodeJSON scope (Pattern Recognition + Architecture):** `encodeJSON` is duplicated in 4 files (`GetMessages.swift`, `FindChat.swift`, `Send.swift`, `Update.swift`) with identical implementations. Add it to `FormatUtils` for consolidation.

Remove `formatFileSize` from: `GetMessages.swift`, `ListAttachments.swift`, `GetAttachment.swift`
Remove `encodeJSON` from: `GetMessages.swift`, `FindChat.swift`, `Send.swift`, `Update.swift`

---

#### Phase 4: HTTP Transport Spec Compliance (PR 4)

**4a. Remove Batch Support** — `Server/HTTPTransport.swift`

Delete `handleBatchRequest()` method (~60 lines). Change JSON array detection to return 400 with JSON-RPC error body:

```swift
// In handlePost, where batch is currently detected:
if jsonString.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
    return errorResponse(
        status: .badRequest,
        message: "Batch requests are not supported",
        code: -32600
    )
}
```

Also remove: `.batch` case from `JSONRPCMessageType` enum, batch-related switch cases.

### Research Insights — Phase 4a

**Spec confirmation (MCP Protocol Research):** Batch support was officially removed in MCP spec 2025-06-18 (PR #416). The 2025-11-25 spec states: "The body of the POST request MUST be a single JSON-RPC request, notification, or response."

**Client compatibility (Agent Native):** No known MCP client (Claude Desktop, Cursor, MCP Router, Windsurf, Cline) sends batch requests. Safe to remove.

---

**4b. Validate MCP-Protocol-Version Header** — `Server/HTTPTransport.swift`

**CORRECTION: This is a CLIENT request header, not a server response header.** The server must validate it on incoming requests.

```swift
// In handlePost, after reading the request:
if let versionHeader = request.headerFields[.mcpProtocolVersion] {
    let supportedVersions: Set<String> = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    guard supportedVersions.contains(versionHeader) else {
        return errorResponse(
            status: .badRequest,
            message: "Unsupported protocol version: \(versionHeader)",
            code: -32600
        )
    }
}
// If header is absent, assume 2025-03-26 for backwards compatibility (per spec)
```

### Research Insights — Phase 4b

**Critical correction (MCP Protocol Research):** The original plan was WRONG. Per the MCP spec: "The client MUST include the `MCP-Protocol-Version` header on all subsequent requests." The server must VALIDATE it and return 400 for unsupported versions. If absent, the server SHOULD assume `2025-03-26` for backwards compatibility.

**Spec reference:** Introduced in spec 2025-06-18 (PR #548).

---

**4c. Graceful Shutdown** — `main.swift`

Replace the never-resuming continuation with Hummingbird's built-in service lifecycle.

```swift
// BEFORE:
try await transport.connect()
await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
    // Server runs indefinitely
}

// AFTER (use Hummingbird's built-in ServiceGroup):
import ServiceLifecycle

let app = Application(
    router: router,
    configuration: .init(address: .hostname(host, port: port))
)

let serviceGroup = ServiceGroup(
    configuration: .init(
        services: [.init(service: app)],
        gracefulShutdownSignals: [.sigterm, .sigint],
        logger: logger
    )
)
try await serviceGroup.run()
```

### Research Insights — Phase 4c

**Better approach (Security Best Practices + Code Simplicity):** Do NOT hand-roll `DispatchSource.makeSignalSource` handlers. Hummingbird 2.x already depends on `swift-service-lifecycle`. Use `ServiceGroup` which handles SIGTERM/SIGINT automatically and provides proper graceful shutdown (stop accepting new connections, complete in-flight requests, then terminate).

**Architecture (Architecture Strategist):** Signal handlers belong in `main.swift` (the process entry point). The transport should expose a `gracefulShutdown()` method that cleanup code calls, not manage the process lifecycle itself.

**Safety (Security Best Practices):** Traditional signal handlers are limited to async-signal-safe functions. An Apple DTS engineer warned that "malloc isn't async signal safe, and neither is the Swift or Objective-C runtimes." `ServiceGroup` solves this cleanly.

Files:
- `main.swift` — replace continuation with ServiceGroup (~15 lines)

---

**4d. Fix Thread.sleep** — `Tools/GetAttachment.swift`

```swift
// BEFORE:
for _ in 0..<10 {
    Thread.sleep(forTimeInterval: 0.5)
    if FileManager.default.fileExists(atPath: url.path) { return true }
}

// AFTER:
for _ in 0..<10 {
    try? await Task.sleep(nanoseconds: 500_000_000)
    if FileManager.default.fileExists(atPath: url.path) { return true }
}
```

This requires making `tryDownloadFromiCloud` async, which cascades to `execute()`. The registration closure is already implicitly async.

### Research Insights — Phase 4d

**Critical for HTTP mode (Performance Oracle):** This loop blocks a thread for up to 5 seconds. In HTTP mode, the cooperative thread pool is typically 8-10 threads. If 2-3 concurrent `get_attachment` requests hit iCloud-offloaded files, you could exhaust the pool, causing ALL other tool calls and SSE keep-alives to stall. This is textbook priority inversion.

---

#### Phase 5: SDK Upgrade + Hardening (PR 5)

**5a. SDK Upgrade** — `Package.swift`

```swift
// swift-tools-version: 6.1  // CHANGED from 6.0 — required by SDK 0.11.0

.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
```

Then `swift package resolve && swift build -c release` to verify.

### Research Insights — Phase 5a

**Breaking change (MCP Protocol Research):** SDK 0.11.0 requires `swift-tools-version: 6.1`. The `Package.swift` header must be updated.

**New dependencies (MCP Protocol Research):** SDK 0.11.0 pulls in `swift-nio`, `eventsource`, `swift-async-algorithms`, `swift-system` transitively. Verify no conflicts with Hummingbird's own `swift-nio` dependency.

**Tool constructor change (MCP Protocol Research):** The `Tool` init signature now includes `title`, `outputSchema`, and `icons` parameters. Existing tool registrations should still compile (they use defaults), but verify.

**New SDK features available:**
- `Tool.Annotations` now fully supports `title`, `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`
- Structured tool output (`outputSchema` + `structuredContent`) — consider for future PR
- `Icon` support for tools and server — consider for future PR

---

**5b. Session Cap** — `Server/SessionManager.swift`

```swift
private let maxSessions = 100

func createSession(...) async -> MCPSessionState? {
    guard sessions.count < maxSessions else {
        return nil  // Caller returns 503 Service Unavailable
    }
    // ... existing creation logic
}
```

### Research Insights — Phase 5b

**Limit assessment (All agents agree):** 100 is generous for a local MCP server (realistic max is 3-5 concurrent clients). But 100 does no harm, prevents resource exhaustion from misbehaving clients, and avoids false limits.

---

**5c. Body Size Limit** — `Server/HTTPTransport.swift`

```swift
// BEFORE:
let body = try await request.body.collect(upTo: 10 * 1024 * 1024)

// AFTER:
let body = try await request.body.collect(upTo: 512 * 1024)  // 512KB
```

### Research Insights — Phase 5c

**Request-only (Performance Oracle):** This is the REQUEST body limit (client → server). Do NOT apply to responses. The `get_attachment` tool returns base64-encoded images that can easily be 2-5MB. Server responses are not limited by this.

**Appropriate size (All agents agree):** Even a 20,000-character message in a full JSON-RPC envelope is under 100KB. 512KB provides 5x headroom.

---

**5d. SSE Connection Limits** — ~~`Server/SSEConnection.swift`~~ **REMOVED**

### Research Insights — Phase 5d

**YAGNI (Code Simplicity):** The session cap (100) is sufficient protection. A well-behaved MCP client opens 1 SSE connection per session. Adding per-session and total SSE limits adds ~15 lines of guard logic for a scenario that will not occur on a single-user localhost server. If this ever becomes a networked server, add limits then.

---

**5e. Non-localhost Warning** — `main.swift`

```swift
if host != "127.0.0.1" && host != "::1" && host != "localhost" {
    FileHandle.standardError.write(
        "[WARNING] Binding to '\(host)' exposes iMessage data to the network. Use 127.0.0.1 for local-only access.\n"
            .data(using: .utf8)!)
}
```

---

**5f. Complete Tool Annotations** — all tool registration files

Standardize annotations across all 12 tools and add `title` field.

```swift
// Read-only tools (find_chat, get_messages, get_context, search, list_chats,
// get_active_conversations, list_attachments, get_unread, get_attachment, diagnose)
Tool.Annotations(
    title: "Find Chat",  // human-readable per tool
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
)

// send
Tool.Annotations(
    title: "Send Message",
    readOnlyHint: false,
    destructiveHint: false,   // Sending is a mutation but not destructive
    idempotentHint: false,    // Sending twice creates two messages
    openWorldHint: true       // Sends to external recipients
)

// update (marks messages as read + updates binary via Homebrew)
Tool.Annotations(
    title: "Update iMessage Max",
    readOnlyHint: false,
    destructiveHint: true,    // Replaces installed binary
    idempotentHint: true,     // Updating twice is same as once
    openWorldHint: true       // Network call to Homebrew
)
```

### Research Insights — Phase 5f

**Agent Native (Agent Native Reviewer + MCP Best Practices):** Claude Desktop uses `readOnlyHint: true` to auto-approve tool calls without user confirmation. Setting this correctly on all read tools reduces friction. The `send` tool is currently missing `destructiveHint`, `idempotentHint`, and `openWorldHint`.

**SDK 0.11.0 (MCP Protocol Research):** Now fully supports `title` field on `Tool.Annotations`. Add human-readable titles to all 12 tools.

---

#### Phase 6: Version Bump (PR 6)

- `Server/Version.swift`: `Version.current = "1.2.0"`
- `Info.plist`: Update CFBundleShortVersionString

### Research Insights — Phase 6

**Combine with Phase 5 (Code Simplicity):** Consider merging this into PR 5. A standalone version bump PR creates unnecessary review overhead. The version bump should be the last commit of the release PR.

---

## System-Wide Impact

### Interaction Graph

- PR 1 (AppleScript): Only affects `send` tool → `AppleScript.swift` → `osascript` process. No other tools impacted.
- PR 2 (Bug fixes): Search, OriginValidation, GetContext, **GetActiveConversations**, **Search** people keys, display names — all independent, no cross-impact.
- PR 3 (Deduplication): Touches all 12 tools at the import level but doesn't change behavior — pure extraction. **Also fixes `ListChats.swift` reversed priority bug.**
- PR 4 (Transport): HTTPTransport handles all tools equally — batch removal + header validation affect all HTTP requests uniformly.
- PR 5 (Hardening): Session cap applies at session layer before any tool execution. Tool annotations are cosmetic metadata.

### Error Propagation

- AppleScript env var failure: `system attribute` returns error → `osascript` exits non-zero → `SendError.failed` returned to client
- Search param fix: Eliminates silent param misalignment → queries return correct results instead of wrong ones
- Session cap exceeded: `createSession` returns nil → HTTPTransport returns 503 → client retries or reports
- Invalid `MCP-Protocol-Version` header: → HTTPTransport returns 400 Bad Request

### State Lifecycle Risks

- No state changes — all tools are read-only against chat.db except `send` (which delegates to Messages.app)
- Session cleanup already has 1-hour timeout + 5-minute sweep — no change needed
- Graceful shutdown via `ServiceGroup` ensures in-flight requests complete before termination

### API Surface Parity

- `get_context`, `get_active_conversations`, `search` people keys will change from `p1/p2` to `nick/andrew` — this is intentional and matches `get_messages` and `list_attachments`
- Message ID format standardized to `msg_123` across all tools
- No other response format changes

## Acceptance Criteria

### Functional Requirements

- [ ] `send` tool works with emoji, CJK, quotes, newlines, backslashes in message text
- [ ] `send` rejects messages > 20,000 chars and recipients > 100 chars
- [ ] `search(has: "link", from_person: "me")` returns correct results
- [ ] IPv6 localhost connections are properly validated (not rejected)
- [ ] Requests with invalid Origin return 403 Forbidden
- [ ] Requests without Host header are rejected
- [ ] `get_context` returns name-based people keys consistent with `get_messages`
- [ ] `get_active_conversations` returns name-based people keys (not `p0/p1/p2`)
- [ ] `search` returns name-based people keys (not `p1/p2/p3`)
- [ ] Unnamed group chats show participant names in `list_chats` and `get_messages`
- [ ] `extractTextFromTypedstream` exists in exactly 1 file
- [ ] `generateDisplayName` exists in exactly 1 file
- [ ] `encodeJSON` exists in exactly 1 file
- [ ] Batch POST requests return 400 with JSON-RPC error body
- [ ] Invalid `MCP-Protocol-Version` header returns 400; absent header accepted (assume 2025-03-26)
- [ ] SIGTERM/SIGINT triggers graceful shutdown via ServiceGroup
- [ ] `swift build -c release` succeeds with SDK 0.11.0 and swift-tools-version 6.1
- [ ] Session creation rejected at 100 concurrent sessions (returns 503)
- [ ] All 12 tools have complete annotations with `title`
- [ ] `send` annotations: `readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true`

### Quality Gates

- [ ] `swift build -c release` succeeds with zero warnings
- [ ] `swift test` passes
- [ ] Manual test: stdio mode with `echo '...' | ./.build/release/imessage-max`
- [ ] Manual test: HTTP mode with `curl` against all 12 tools
- [ ] Verify message ID format is `msg_123` in all tool responses

## Dependencies & Prerequisites

- PRs must be merged in order: 1 → 2 → 3 → 4 → 5 (with 6 merged into 5)
- PR 3 (deduplication) depends on PR 2 (bug fixes) being validated first
- **Before starting PR 5:** Review SDK 0.11.0 changelog for `Transport` protocol changes. If the protocol signature changes, the custom `HTTPTransport`, `SessionTransportAdapter`, and `SSEConnection` will need updates.
- PR 5 requires bumping `swift-tools-version` from 6.0 to 6.1

## Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| SDK 0.11.0 breaks `Transport` protocol | Medium | High | Review changelog before starting PR 4; combine PRs 4+5 if overlap is significant |
| `swift-tools-version: 6.1` breaks CI/local builds | Low | Medium | Verify Xcode/Swift toolchain version before starting |
| ServiceGroup conflicts with existing Hummingbird setup | Low | Medium | Test graceful shutdown path thoroughly |
| People key change confuses existing AI clients | Very Low | Low | AI clients already handle variable key formats |

## Success Metrics

- Zero CRITICAL/HIGH security findings on re-audit
- All 12 tools return correct results in manual testing
- Build succeeds on first try after each PR
- No regressions in stdio mode (Claude Desktop) or HTTP mode (MCP Router)

## Future Considerations (Out of Scope)

These items were identified by research agents but are deferred to future PRs:

- **Tool name prefix** (`imessage_find_chat`) — would prevent namespace collision with other MCP servers but is a breaking change
- **Pagination implementation** — cursors are always nil in `list_chats`, `list_attachments`, etc.
- **Rate limiting** — per-session request throttling for HTTP mode
- **`GetUnread` Codable refactor** — only tool using `[String: Any]` instead of Codable structs
- **Connection pooling** — Database opens/closes SQLite connection per query (N+1 in Search's `unanswered` filter)
- **CIContext sharing** — `GetAttachment` creates expensive `CIContext` per call (10-50ms init)
- **`parseChatId` deduplication** — duplicated in 4 files with slight variants
- **DispatchSemaphore → async** — `AppleScript.swift` blocks cooperative thread with semaphore
- **`isError: true` on error responses** — tools return errors as text, not flagged with `isError`
- **Structured output** (`outputSchema` + `structuredContent`) — available in SDK 0.11.0
- **GUID LIKE wildcard injection** — `parseChatId` wraps user input in `%...%` without escaping LIKE wildcards

## Sources & References

### Internal References

- Code reviewer findings: 10 confirmed issues with severity ratings
- Architect assessment: 4-tier prioritization with "what NOT to do" guidance
- Security review: 12 findings (1 Critical, 3 High, 5 Medium, 3 Low)
- Planner output: 7-phase implementation plan with PR sequence
- Live testing results: Confirmed bugs in search, get_context, find_chat

### External References

- [MCP Specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25)
- [MCP 2025-06-18 Changelog](https://modelcontextprotocol.io/specification/2025-06-18/changelog) — batch removal, protocol version header, structured output
- [MCP 2025-11-25 Changelog](https://modelcontextprotocol.io/specification/2025-11-25/changelog) — tasks, icons, SSE polling, origin validation clarification
- [Swift SDK 0.11.0 Release](https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.11.0) — released 2026-02-19
- [MCP Transports Spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) — protocol version header requirements

### Key File Paths

| File | Lines | Changes |
|------|-------|---------|
| `Utilities/AppleScript.swift` | 119 | Rewrite send(), delete escape(), add input validation |
| `Tools/Search.swift` | 1215 | Refactor buildQuery(), fix people keys |
| `Server/OriginValidationMiddleware.swift` | 94 | Fix host extraction, return 403 |
| `Tools/GetContext.swift` | 548 | Fix people keys, standardize message IDs |
| `Tools/GetActiveConversations.swift` | ~400 | Fix people keys |
| `Tools/ListChats.swift` | 560 | Fix empty name check |
| `Tools/GetMessages.swift` | 1052 | Fix empty name, remove duplication |
| `Server/HTTPTransport.swift` | 638 | Remove batch, validate protocol version header, reduce body limit |
| `main.swift` | 60 | ServiceGroup shutdown, non-localhost warning |
| `Tools/GetAttachment.swift` | 352 | Fix Thread.sleep |
| `Server/SessionManager.swift` | 200 | Add session cap |
| `Package.swift` | 34 | SDK version bump, swift-tools-version 6.1 |
| `Server/Version.swift` | 10 | Version bump |
| All 12 tool files | various | Complete annotations with title |
| **NEW** `Utilities/MessageTextExtractor.swift` | ~55 | Shared text extraction with FFFC handling |
| **NEW** `Utilities/DisplayNameGenerator.swift` | ~25 | Shared display name generation |
| **NEW** `Utilities/FormatUtils.swift` | ~20 | Shared file size formatting + encodeJSON |
| **MOVED** `Models/AttachmentType.swift` | ~35 | Moved from ListAttachments |

# Plan 018: IMCore helper socket protocol + HelperBridge (Swift foundation)

> **For agentic workers:** REQUIRED SUB-SKILL: use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.
>
> **Executor instructions**: BASE CHECK FIRST — run
> `ls plans/018-imcore-helper-bridge-protocol.md` and confirm the title says
> "IMCore helper socket protocol + HelperBridge". Branch
> `advisor/018-imcore-helper-bridge`. Follow exactly; verify every step;
> in-scope files only; do not edit `plans/README.md`. Report: STATUS / STEPS /
> STOPPED BECAUSE / FILES CHANGED / NOTES.

**Goal:** Build the Swift-side, transport-abstracted client (`HelperBridge`)
and versioned JSON wire protocol that will talk to the injected IMCore helper
dylib — fully unit-testable with no SIP, no dylib, and no Messages.app.

**Architecture:** A `HelperTransport` protocol abstracts the byte round-trip
(exactly as `ScriptRunning` abstracts `osascript`). `HelperBridge` is an actor
that speaks a versioned, newline-delimited JSON protocol over any transport and
maps wire errors to a typed `HelperError`. Tests inject a stub transport; a real
`UnixSocketTransport` (POSIX) is included and verified over an in-process
`socketpair()` loopback. Nothing in this plan calls a private framework or
requires SIP.

**Tech Stack:** Swift 6.1, SwiftPM, XCTest, Foundation, POSIX sockets.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW (new, isolated files; no send-path or private-API changes yet)
- **Depends on**: nothing (foundation of the 018–021 sequence)
- **Category**: feature / infrastructure
- **Planned at**: 2026-07-04 (from
  `docs/plans/2026-07-04-group-chat-creation-imcore-design.md`)

## Plan sequence (context — do not implement 019–021 here)

This is plan 1 of 4 realizing the group-creation design. Later plans depend on
the interfaces this one **Produces**:

- **018 (this plan):** wire protocol + `HelperBridge` + transports (Swift). ← now
- **019:** `imessage-max-helper` dylib (Objective-C) implementing the protocol
  against IMCore (`chatForIMHandles:`, `[chat sendMessage:]`); on-device tested.
- **020:** `MessagesLifecycle` (server owns Messages + `DYLD_INSERT_LIBRARIES`),
  `IMCoreScriptRunner` (conforms to `ScriptRunning`), backend-selection flag with
  dormant AppleScript fallback, multi-recipient `to` + exact-participant group
  reuse/creation in `SendResolver`, `send` tool schema update, capability gating.
- **021:** build/install/docs — `make install` builds+places the dylib, SIP &
  library-validation setup docs in `AGENTS.md`/`README.md`, capability surface.

## Global Constraints

- Swift tools version: **6.1** (`swift/Package.swift`). All new files compile
  under Swift 6 strict concurrency; shared mutable types are `actor` or
  `Sendable`.
- Protocol version constant: **`helperProtocolVersion = 1`** — every request and
  response carries `"v": 1`. A response whose `v` != the client's version is a
  hard `HelperError.protocolMismatch`.
- Wire framing: **one JSON object per line, `\n`-delimited, UTF-8**. No embedded
  newlines in serialized objects (Foundation `JSONEncoder` default emits none).
- Verification baseline (CI parity): `cd swift && swift build && swift test`.
- New source files live under `swift/Sources/iMessageMax/Helper/`; new tests
  under `swift/Tests/iMessageMaxTests/`. SwiftPM auto-globs both — no
  `Package.swift` edit is required or permitted in this plan.
- In-scope files only: the four `Helper/` sources and two test files below.
  Do **not** modify `Send.swift`, `SendResolution.swift`, `AppleScript.swift`,
  or any tool — that is plan 020.

---

### Task 1: Wire protocol types

**Files:**
- Create: `swift/Sources/iMessageMax/Helper/HelperProtocol.swift`
- Test: `swift/Tests/iMessageMaxTests/HelperProtocolTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `let helperProtocolVersion = 1`
  - `enum HelperCommand: String, Codable { case ping, createChat = "create-chat", sendText = "send-text", sendFile = "send-file" }`
  - `struct HelperRequest: Codable, Equatable` with fields
    `v: Int`, `id: String`, `cmd: HelperCommand`, `addresses: [String]?`,
    `service: String?`, `chatGuid: String?`, `body: String?`, `path: String?`
    (CodingKeys map `chatGuid` → `chat_guid`). Factory helpers:
    `static func ping(id:) -> HelperRequest`,
    `static func createChat(id:addresses:service:) -> HelperRequest`,
    `static func sendText(id:chatGuid:body:) -> HelperRequest`,
    `static func sendFile(id:chatGuid:path:) -> HelperRequest`.
  - `struct HelperWireError: Codable, Equatable { let code: String; let message: String }`
  - `struct HelperResponse: Codable, Equatable { let v: Int; let id: String; let ok: Bool; let chatGuid: String?; let error: HelperWireError? }`
    (CodingKeys map `chatGuid` → `chat_guid`).
  - `enum HelperWire` namespace with
    `static func encode(_ request: HelperRequest) throws -> Data` (appends `\n`)
    and `static func decode(_ line: Data) throws -> HelperResponse`.

- [ ] **Step 1: Write the failing test**

```swift
// swift/Tests/iMessageMaxTests/HelperProtocolTests.swift
import XCTest
@testable import iMessageMax

final class HelperProtocolTests: XCTestCase {
    func testCreateChatRequestEncodesWithSnakeCaseAndTrailingNewline() throws {
        let req = HelperRequest.createChat(
            id: "abc", addresses: ["+15550000001", "+15550000002"], service: "iMessage")
        let data = try HelperWire.encode(req)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\n"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["cmd"] as? String, "create-chat")
        XCTAssertEqual(obj["addresses"] as? [String], ["+15550000001", "+15550000002"])
        XCTAssertEqual(obj["service"] as? String, "iMessage")
    }

    func testDecodeSuccessResponseMapsChatGuid() throws {
        let line = Data(#"{"v":1,"id":"abc","ok":true,"chat_guid":"iMessage;+;g"}"#.utf8)
        let resp = try HelperWire.decode(line)
        XCTAssertEqual(resp, HelperResponse(v: 1, id: "abc", ok: true,
                                            chatGuid: "iMessage;+;g", error: nil))
    }

    func testDecodeErrorResponse() throws {
        let line = Data(#"{"v":1,"id":"x","ok":false,"error":{"code":"handle_not_found","message":"no"}}"#.utf8)
        let resp = try HelperWire.decode(line)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error, HelperWireError(code: "handle_not_found", message: "no"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift && swift test --filter HelperProtocolTests`
Expected: FAIL — `cannot find 'HelperRequest' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// swift/Sources/iMessageMax/Helper/HelperProtocol.swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swift && swift test --filter HelperProtocolTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/iMessageMax/Helper/HelperProtocol.swift \
        swift/Tests/iMessageMaxTests/HelperProtocolTests.swift
git commit -m "feat(helper): versioned JSON wire protocol for IMCore helper"
```

---

### Task 2: HelperError + HelperTransport abstraction

**Files:**
- Create: `swift/Sources/iMessageMax/Helper/HelperError.swift`
- Create: `swift/Sources/iMessageMax/Helper/HelperTransport.swift`

**Interfaces:**
- Consumes: `HelperWireError` (Task 1).
- Produces:
  - `enum HelperError: Error, Equatable` cases: `notConnected`,
    `timeout`, `protocolMismatch(expected: Int, got: Int)`,
    `idMismatch(expected: String, got: String)`, `malformedResponse(String)`,
    `remote(code: String, message: String)`.
  - `protocol HelperTransport: Sendable { func roundTrip(_ request: Data, timeout: TimeInterval) async throws -> Data; func isConnected() async -> Bool }`
    — `roundTrip` writes one framed request and returns exactly one response
    line (without the trailing `\n`). Throws `HelperError.notConnected` /
    `HelperError.timeout`.

- [ ] **Step 1: Write the implementation (no test yet — pure declarations)**

```swift
// swift/Sources/iMessageMax/Helper/HelperError.swift
import Foundation

enum HelperError: Error, Equatable {
    case notConnected
    case timeout
    case protocolMismatch(expected: Int, got: Int)
    case idMismatch(expected: String, got: String)
    case malformedResponse(String)
    case remote(code: String, message: String)
}
```

```swift
// swift/Sources/iMessageMax/Helper/HelperTransport.swift
import Foundation

/// Abstraction over the byte round-trip to the injected helper. Production uses
/// UnixSocketTransport; tests inject a stub. Mirrors how ScriptRunning abstracts
/// osascript.
protocol HelperTransport: Sendable {
    /// Writes one framed request line and returns exactly one response line
    /// (trailing newline stripped). Throws HelperError.notConnected/.timeout.
    func roundTrip(_ request: Data, timeout: TimeInterval) async throws -> Data
    func isConnected() async -> Bool
}
```

- [ ] **Step 2: Verify it builds**

Run: `cd swift && swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add swift/Sources/iMessageMax/Helper/HelperError.swift \
        swift/Sources/iMessageMax/Helper/HelperTransport.swift
git commit -m "feat(helper): HelperError + HelperTransport abstraction"
```

---

### Task 3: HelperBridge (command surface over any transport)

**Files:**
- Create: `swift/Sources/iMessageMax/Helper/HelperBridge.swift`
- Test: `swift/Tests/iMessageMaxTests/HelperBridgeTests.swift`

**Interfaces:**
- Consumes: `HelperRequest`, `HelperResponse`, `HelperWire`,
  `helperProtocolVersion` (Task 1); `HelperTransport`, `HelperError` (Task 2).
- Produces:
  - `actor HelperBridge` with `init(transport: HelperTransport, timeout: TimeInterval = 10, idFactory: @Sendable () -> String = { UUID().uuidString })`.
  - `func createGroupChat(addresses: [String], service: String = "iMessage") async -> Result<String, HelperError>` — returns the new `chat_guid`.
  - `func sendText(chatGuid: String, body: String) async -> Result<Void, HelperError>`
  - `func sendFile(chatGuid: String, path: String) async -> Result<Void, HelperError>`
  - `func probe() async -> Bool` — sends `ping`; true iff transport connected
    and an `ok` pong returns before timeout.
  - Private `send(_ request:) async -> Result<HelperResponse, HelperError>` that
    encodes, round-trips, decodes, and validates `v` and `id`.

**Interface note for plan 020:** `IMCoreScriptRunner` will wrap these methods to
conform to `ScriptRunning`; keep these signatures stable.

- [ ] **Step 1: Write the failing test**

```swift
// swift/Tests/iMessageMaxTests/HelperBridgeTests.swift
import XCTest
@testable import iMessageMax

/// In-memory transport: returns a canned response line for each request, or a
/// thrown error. Records requests for assertions.
final class StubHelperTransport: HelperTransport, @unchecked Sendable {
    private(set) var sentLines: [String] = []
    var connected = true
    /// Given the decoded request, produce the raw response line (no newline) or throw.
    var responder: (HelperRequest) throws -> String = { _ in "" }

    func roundTrip(_ request: Data, timeout: TimeInterval) async throws -> Data {
        guard connected else { throw HelperError.notConnected }
        let line = String(decoding: request, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        sentLines.append(line)
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: Data(line.utf8))
        return Data(try responder(decoded).utf8)
    }
    func isConnected() async -> Bool { connected }
}

final class HelperBridgeTests: XCTestCase {
    private func bridge(_ t: StubHelperTransport) -> HelperBridge {
        HelperBridge(transport: t, timeout: 1, idFactory: { "fixed-id" })
    }

    func testCreateGroupChatReturnsGuid() async {
        let t = StubHelperTransport()
        t.responder = { req in
            XCTAssertEqual(req.cmd, .createChat)
            XCTAssertEqual(req.addresses, ["+1", "+2"])
            return #"{"v":1,"id":"fixed-id","ok":true,"chat_guid":"iMessage;+;g"}"#
        }
        let result = await bridge(t).createGroupChat(addresses: ["+1", "+2"])
        XCTAssertEqual(result, .success("iMessage;+;g"))
    }

    func testRemoteErrorSurfacesAsHelperError() async {
        let t = StubHelperTransport()
        t.responder = { _ in
            #"{"v":1,"id":"fixed-id","ok":false,"error":{"code":"handle_not_found","message":"no such handle"}}"#
        }
        let result = await bridge(t).createGroupChat(addresses: ["+1", "+2"])
        XCTAssertEqual(result, .failure(.remote(code: "handle_not_found", message: "no such handle")))
    }

    func testProtocolVersionMismatchRejected() async {
        let t = StubHelperTransport()
        t.responder = { _ in #"{"v":2,"id":"fixed-id","ok":true}"# }
        let result = await bridge(t).sendText(chatGuid: "g", body: "hi")
        XCTAssertEqual(result, .failure(.protocolMismatch(expected: 1, got: 2)))
    }

    func testIdMismatchRejected() async {
        let t = StubHelperTransport()
        t.responder = { _ in #"{"v":1,"id":"WRONG","ok":true}"# }
        let result = await bridge(t).sendText(chatGuid: "g", body: "hi")
        XCTAssertEqual(result, .failure(.idMismatch(expected: "fixed-id", got: "WRONG")))
    }

    func testProbeTrueOnOkPong() async {
        let t = StubHelperTransport()
        t.responder = { req in
            XCTAssertEqual(req.cmd, .ping)
            return #"{"v":1,"id":"fixed-id","ok":true}"#
        }
        let ok = await bridge(t).probe()
        XCTAssertTrue(ok)
    }

    func testProbeFalseWhenDisconnected() async {
        let t = StubHelperTransport()
        t.connected = false
        let ok = await bridge(t).probe()
        XCTAssertFalse(ok)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift && swift test --filter HelperBridgeTests`
Expected: FAIL — `cannot find 'HelperBridge' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// swift/Sources/iMessageMax/Helper/HelperBridge.swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swift && swift test --filter HelperBridgeTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/iMessageMax/Helper/HelperBridge.swift \
        swift/Tests/iMessageMaxTests/HelperBridgeTests.swift
git commit -m "feat(helper): HelperBridge command surface with protocol/id validation"
```

---

### Task 4: UnixSocketTransport (POSIX) + loopback test

**Files:**
- Create: `swift/Sources/iMessageMax/Helper/UnixSocketTransport.swift`
- Modify: `swift/Tests/iMessageMaxTests/HelperBridgeTests.swift` (append a
  loopback integration test using `socketpair()`).

**Interfaces:**
- Consumes: `HelperTransport`, `HelperError` (Task 2).
- Produces:
  - `final class UnixSocketTransport: HelperTransport, @unchecked Sendable`
    with `init(path: String)` (production: connects lazily to the Unix domain
    socket at `path`) and a test seam
    `init(connectedFD fd: Int32)` that wraps an already-connected descriptor.
  - Reads one `\n`-delimited line per `roundTrip`; strips the newline.

**Note:** This transport is what plan 020's `MessagesLifecycle` points at once
the dylib (plan 019) is listening. In this plan it is verified only over an
in-process `socketpair()` so it needs neither the dylib nor SIP.

- [ ] **Step 1: Write the failing loopback test (append to HelperBridgeTests.swift)**

```swift
// Append inside HelperBridgeTests.swift
extension HelperBridgeTests {
    func testUnixSocketTransportRoundTripsOverSocketpair() async throws {
        var fds: [Int32] = [0, 0]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        try XCTSkipUnless(rc == 0, "socketpair unavailable")
        let clientFD = fds[0]
        let serverFD = fds[1]

        // Fake server: read one line, reply with a pong echoing the request id.
        let server = Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(serverFD, &buf, buf.count)
            let line = String(decoding: buf[0..<max(0, n)], as: UTF8.self)
            let req = try! JSONDecoder().decode(HelperRequest.self,
                                                from: Data(line.trimmingCharacters(in: .newlines).utf8))
            let reply = #"{"v":1,"id":"\#(req.id)","ok":true}\#("\n")"#
            _ = Data(reply.utf8).withUnsafeBytes { write(serverFD, $0.baseAddress, $0.count) }
            close(serverFD)
        }
        server.start()

        let transport = UnixSocketTransport(connectedFD: clientFD)
        let bridge = HelperBridge(transport: transport, timeout: 2, idFactory: { "pp" })
        let ok = await bridge.probe()
        XCTAssertTrue(ok)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift && swift test --filter testUnixSocketTransportRoundTripsOverSocketpair`
Expected: FAIL — `cannot find 'UnixSocketTransport' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// swift/Sources/iMessageMax/Helper/UnixSocketTransport.swift
import Foundation

/// POSIX Unix-domain-socket transport to the injected helper. Production
/// connects to `path`; tests wrap a pre-connected fd (e.g. from socketpair()).
final class UnixSocketTransport: HelperTransport, @unchecked Sendable {
    private let path: String?
    private var fd: Int32
    private let lock = NSLock()

    init(path: String) { self.path = path; self.fd = -1 }
    init(connectedFD fd: Int32) { self.path = nil; self.fd = fd }

    func isConnected() async -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ensureConnectedLocked()
    }

    func roundTrip(_ request: Data, timeout: TimeInterval) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard ensureConnectedLocked() else { throw HelperError.notConnected }

        // Apply send/recv timeout on the fd.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let wrote = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard wrote == request.count else { throw HelperError.notConnected }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { throw HelperError.timeout }
            if n == 0 { break } // peer closed
            out.append(contentsOf: buf[0..<n])
            if let nl = out.firstIndex(of: 0x0A) {
                return out.prefix(upToBoundary: nl)
            }
        }
        if let nl = out.firstIndex(of: 0x0A) { return out.prefix(upToBoundary: nl) }
        return out
    }

    /// Connects to `path` if not already connected. A wrapped fd is always
    /// considered connected. Returns false on failure.
    private func ensureConnectedLocked() -> Bool {
        if fd >= 0 { return true }
        guard let path else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            path.withCString { c in strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self),
                                            c, MemoryLayout.size(ofValue: addr.sun_path) - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) }
        }
        if rc != 0 { close(s); return false }
        fd = s
        return true
    }
}

private extension Data {
    /// Bytes before `boundary` (a `\n` index), excluding the newline.
    func prefix(upToBoundary boundary: Index) -> Data { subdata(in: startIndex..<boundary) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swift && swift test --filter HelperBridgeTests`
Expected: PASS (7 tests total, including the loopback case; it `XCTSkip`s only
if `socketpair` is unavailable, which it is not on macOS).

- [ ] **Step 5: Run the whole suite for regressions**

Run: `cd swift && swift build && swift test`
Expected: existing suite still green plus the new Helper tests.

- [ ] **Step 6: Commit**

```bash
git add swift/Sources/iMessageMax/Helper/UnixSocketTransport.swift \
        swift/Tests/iMessageMaxTests/HelperBridgeTests.swift
git commit -m "feat(helper): POSIX UnixSocketTransport verified over socketpair loopback"
```

---

## Self-Review

- **Spec coverage (018 slice of the design):** the design's U2 `HelperBridge`
  (`createGroupChat`, `sendText`, `sendFile`, `probe`) and the "socket, JSON
  commands, versioned so a newer server detects an older dylib" open question
  are implemented (Tasks 1, 3) with an explicit `v` check. Transport is
  abstracted (Task 2) and a real socket transport is provided and loopback-tested
  (Task 4). U1 (dylib), U3 (`MessagesLifecycle`), U4 (`IMCoreScriptRunner`),
  backend flag, tool-schema, and install/docs are **intentionally deferred** to
  plans 019–021 and named in the sequence block.
- **Placeholder scan:** none — every code step is complete and compilable.
- **Type consistency:** `HelperRequest`/`HelperResponse`/`HelperWire`/
  `HelperError`/`HelperTransport`/`HelperBridge` names and signatures match
  across Tasks 1–4; `chat_guid` snake-case mapping is consistent in both
  request and response; `helperProtocolVersion = 1` is the single source used by
  both encoder factories and the bridge validator.
- **Boundary check:** no send-path/private-API/`Package.swift` edits, per Global
  Constraints.

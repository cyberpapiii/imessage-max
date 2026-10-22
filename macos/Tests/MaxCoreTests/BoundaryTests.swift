import Foundation
import Testing

@testable import MaxCore

@Test func rejectsForeignAndToolErrorResponses() throws {
  for json in [
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"isError\":true}}",
    "{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":{}}",
    "{\"html\":\"another service\"}",
  ] {
    #expect(throws: (any Error).self) { try ServiceClient.decode(Data(json.utf8)) }
  }
}

@Test func decodesActualStructuredReply() throws {
  let payload = try JSONEncoder().encode(diagnosis())
  let object = try JSONSerialization.jsonObject(with: payload)
  let data = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0", "id": 1, "result": ["structuredContent": object],
  ])
  #expect(try ServiceClient.decode(data).version == "1.8.0")
}

@Test func honorsLocalPortAndRejectsNetworkHost() throws {
  let home = URL(fileURLWithPath: "/tmp/max-home")
  func plist(_ host: String) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": "local.imessage-max",
        "ProgramArguments": ["/tmp/imessage-max", "--http", "--host", host, "--port", "9191"],
      ], format: .xml, options: 0)
  }
  let local = try ServiceConfiguration(data: plist("127.0.0.1"), home: home)
  #expect(local.endpoint.port == 9191)
  #expect(throws: (any Error).self) { try ServiceConfiguration(data: plist("0.0.0.0"), home: home) }
}

@Test func supportsEqualsOptionsAndIPv6WithoutBypassingHostValidation() throws {
  func config(_ args: [String]) throws -> ServiceConfiguration {
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["Label": "local.imessage-max", "ProgramArguments": args], format: .xml,
      options: 0)
    return try ServiceConfiguration(data: data, home: URL(fileURLWithPath: "/tmp/home"))
  }
  #expect(try config(["/tmp/imessage-max", "--http", "--port=9191"]).endpoint.port == 9191)
  #expect(throws: (any Error).self) {
    try config(["/tmp/imessage-max", "--http", "--host=0.0.0.0", "--allow-external-bind"])
  }
  #expect(throws: (any Error).self) {
    try config(["/tmp/imessage-max", "--http", "--port", "8080", "--port=9191"])
  }
  #expect(
    try config(["/tmp/imessage-max", "--http", "--host=::1"]).endpoint.absoluteString
      == "http://[::1]:8080/")
}

@Test func distinguishesOwnedFailureFromForeignListener() {
  #expect(!ServiceController.hasForeignListener(ownedPID: 123, listeners: [123]))
  #expect(ServiceController.hasForeignListener(ownedPID: 123, listeners: [456]))
  #expect(ServiceController.hasForeignListener(ownedPID: nil, listeners: [456]))
  #expect(!ServiceController.hasForeignListener(ownedPID: 123, listeners: []))
}

@Test func cancellationActuallyEndsTheChild() async {
  let task = Task { try await ProcessRunner.run("/bin/sleep", arguments: ["10"], timeout: 20) }
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func cancellationTerminatesAnAlreadyRunningChild() async throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(
    "max-test-pid-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: file) }
  let task = Task {
    try await ProcessRunner.run(
      "/bin/sh", arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 10", "max-test", file.path],
      timeout: 15)
  }
  let deadline = Date().addingTimeInterval(2)
  while !FileManager.default.fileExists(atPath: file.path) && Date() < deadline {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
    }
  }
  let pidText = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(
    in: .whitespacesAndNewlines)
  let pid = try #require(Int32(pidText))
  #expect(kill(pid, 0) == 0)
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(kill(pid, 0) == -1)
}

@Test func rendersCanonicalTemplateWithoutDroppingKeepalive() throws {
  let template = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
      "swift/launchd/local.imessage-max.plist")
  let data = try ServiceConfiguration.renderTemplate(
    Data(contentsOf: template), binary: URL(fileURLWithPath: "/tmp/a & b/imessage-max"),
    home: URL(fileURLWithPath: "/tmp/home"))
  let plist = try #require(
    try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  #expect((plist["KeepAlive"] as? [String: Bool])?["Crashed"] == true)
  #expect((plist["ProgramArguments"] as? [String])?.first == "/tmp/a & b/imessage-max")
  #expect(plist["StandardErrorPath"] as? String == "/tmp/home/Library/Logs/imessage-max.stderr.log")
}

@Test func requestContainsRequiredModernMetadata() throws {
  let request = try ServiceClient.request(endpoint: URL(string: "http://127.0.0.1:8080")!)
  #expect(request.value(forHTTPHeaderField: "Mcp-Name") == "diagnose")
  #expect(request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2026-07-28")
  #expect(request.timeoutInterval == 5)
}

@Test func processTimeoutActuallyEndsTheChild() async throws {
  let started = ContinuousClock.now
  await #expect(throws: CoreError.self) {
    try await ProcessRunner.run("/bin/sleep", arguments: ["10"], timeout: 0.1)
  }
  #expect(started.duration(to: .now) < .seconds(3))
}

@Test func processCapturesLargeOutputWithoutPipeDeadlock() async throws {
  let result = try await ProcessRunner.run("/usr/bin/seq", arguments: ["1", "50000"], timeout: 3)
  #expect(result.exitCode == 0)
  #expect(result.output.utf8.count <= 65536)
}

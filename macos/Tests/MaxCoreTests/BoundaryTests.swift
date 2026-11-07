import Foundation
import IMessageMaxContract
import Testing
import MaxTestSupport

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

@Test func requestContainsRequiredModernMetadata() throws {
  let request = try ServiceClient.request(endpoint: URL(string: "http://127.0.0.1:47821")!, token: "secret")
  #expect(request.value(forHTTPHeaderField: "Mcp-Name") == "diagnose")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
  #expect(try ServiceClient.request(endpoint: URL(string: "http://127.0.0.1:47821")!, token: nil)
    .value(forHTTPHeaderField: "Authorization") == nil)
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
  let result = try await ProcessRunner.run("/usr/bin/seq", arguments: ["1", "200000"], timeout: 3)
  #expect(result.exitCode == 0)
  #expect(result.output.utf8.count > 65536 && result.output.utf8.count <= 1 << 20)
}

@Test func processHandsItsInputToTheChildOnStdin() async throws {
  let result = try await ProcessRunner.run("/bin/cat", arguments: [], input: Data("tok-123".utf8))
  #expect(result.exitCode == 0)
  #expect(result.output == "tok-123")
  let early = try await ProcessRunner.run("/usr/bin/true", arguments: [], input: Data("x".utf8))
  #expect(early.exitCode == 0, "a child that never reads its stdin still finishes")
}

@Test func tokenIsReadFreshFromTheFileTheHelperWrites() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent("token-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: file) }
  #expect(ServiceClient.readToken(file) == nil)
  try "abc\n".write(to: file, atomically: true, encoding: .utf8)
  #expect(ServiceClient.readToken(file) == "abc")
  #expect(ServiceClient().tokenFile.path.hasSuffix("/Library/Application Support/iMessage Max/token"))
}

import Foundation
import Testing

@testable import MaxCore

@Test func probeEnvironmentWithoutWorkingFolder() async throws {
  let result = try await ProcessRunner.run(
    "/usr/bin/true", arguments: [], environment: ["PATH": "/usr/bin"])
  #expect(result.exitCode == 0)
}

@Test func probeEnvironmentWithWorkingFolder() async throws {
  let result = try await ProcessRunner.run(
    "/usr/bin/true", arguments: [], environment: ["HOME": NSTemporaryDirectory()])
  #expect(result.exitCode == 0)
}

@Test func probeDefaultRunClosure() async throws {
  let context = ClientContext(
    home: URL(fileURLWithPath: NSTemporaryDirectory()), application: { _ in nil },
    open: { _, _ in }, run: ClientContext.runProcess,
    scratch: URL(fileURLWithPath: NSTemporaryDirectory()))
  let result = try await context.run("/usr/bin/true", [], [:])
  #expect(result.exitCode == 0)
}

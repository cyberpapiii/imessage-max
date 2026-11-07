import Foundation
import IMessageMaxContract
import MaxCore
import MaxTestSupport
import Testing

@testable import iMessageMaxMenu

/// A macOS whose SMAppService calls and helper permission requests never
/// answer, as when a prompt is left open or the service manager stalls.
private actor StuckSystem: ServiceSystem {
  let running: Bool
  private var parked: [CheckedContinuation<Void, Never>] = []

  init(running: Bool) { self.running = running }

  func agentStatus(plistName: String) async -> AgentStatus { running ? .enabled : .notRegistered }
  func job(label: String) async -> Job? { running && label != LegacyInstall.label ? Job(pid: 300) : nil }
  func diagnose(endpoint: URL) async -> DiagnoseResult? {
    running ? try? diagnosis(automation: "permission-gated", processID: 300) : nil
  }
  func listeners(port: Int) async -> Set<Int32> { running ? [300] : [] }
  func run(_ command: SystemCommand) async throws { await hang() }
  func isOutdated(pid: Int32, executable: URL) async -> Bool { false }
  func requestContactsAccess() async -> PermissionStatus {
    await hang()
    return .notDetermined
  }
  func requestHelperPermission(_ permission: SetupPermission, endpoint: URL, processID: Int32)
    async throws -> SetupPermissionReply
  {
    await hang()
    throw CoreError.invalidResponse
  }
  func pause() async {}

  func release() {
    parked.forEach { $0.resume() }
    parked = []
  }

  private func hang() async { await withCheckedContinuation { parked.append($0) } }
}

@MainActor
private func model(_ system: StuckSystem) throws -> AppModel {
  let plist = try PropertyListSerialization.data(
    fromPropertyList: [
      "Label": ServiceDefaults.launchdLabel, "BundleProgram": ServiceDefaults.helperBundlePath,
      "AssociatedBundleIdentifiers": [ServiceDefaults.companionBundleID],
      "ProgramArguments": [ServiceDefaults.executableName, "--http", "--port", "8080"],
    ], format: .xml, options: 0)
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let configuration = try ServiceConfiguration(
    plist: plist, plistName: "\(ServiceDefaults.launchdLabel).plist",
    bundleIdentifier: ServiceDefaults.companionBundleID,
    bundleURL: URL(fileURLWithPath: "/Applications/iMessage Max.app"),
    home: home)
  return AppModel(
    controller: ServiceController(configuration: configuration, system: system, home: home),
    milestones: Milestones(defaults: nil), prepareMessages: {},
    changeDeadline: 0.3, permissionDeadline: 0.3)
}

@MainActor @Test func aServiceChangeThatNeverAnswersFreesTheButtons() async throws {
  let system = StuckSystem(running: false)
  let model = try model(system)
  model.perform(.start)
  #expect(model.busy == .starting)
  await model.prepareToQuit()
  #expect(model.busy == nil)
  #expect(model.problem == CoreError.timeout.localizedDescription)
  #expect(model.service == .notRegistered)
  await system.release()
}

@MainActor @Test func aPermissionPromptThatNeverAnswersFreesTheButtons() async throws {
  let system = StuckSystem(running: true)
  let model = try model(system)
  await model.refresh()
  #expect(model.service?.diagnosis != nil)
  model.request(.automation)
  #expect(model.busy == .askingPermission)
  await model.prepareToQuit()
  #expect(model.busy == nil)
  #expect(model.problem == CoreError.timeout.localizedDescription)
  await system.release()
}

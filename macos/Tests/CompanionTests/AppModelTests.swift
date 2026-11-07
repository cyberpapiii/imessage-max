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
  func diagnose(endpoint: URL) async -> DiagnoseReply {
    guard running, let result = try? diagnosis(automation: "permission-gated", processID: 300)
    else { return .silent }
    return .answered(result)
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
private func model(_ system: any ServiceSystem, milestones: Milestones = Milestones(defaults: nil)) throws -> AppModel {
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
    milestones: milestones, prepareMessages: {},
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

/// A running helper that, like the real one, sees Full Disk Access only as it
/// was at its launch, and counts tool calls from zero after every launch.
private actor LaunchGrantSystem: ServiceSystem {
  var fullDiskOn: Bool
  var assistantCalls = 0
  private(set) var restarts = 0
  private var pid: Int32 = 400
  private var launchedWithFullDisk: Bool
  private var launchedAt = Date.distantPast

  init(fullDiskOn: Bool) {
    self.fullDiskOn = fullDiskOn
    launchedWithFullDisk = fullDiskOn
  }

  func turnOnFullDisk() { fullDiskOn = true }
  func call() { assistantCalls += 1 }

  func agentStatus(plistName: String) async -> AgentStatus { .enabled }
  func job(label: String) async -> Job? { label == LegacyInstall.label ? nil : Job(pid: pid) }
  func diagnose(endpoint: URL) async -> DiagnoseReply {
    guard
      let result = try? diagnosis(
        database: launchedWithFullDisk, processID: pid, assistantCalls: assistantCalls)
    else { return .silent }
    return .answered(result)
  }
  func listeners(port: Int) async -> Set<Int32> { [pid] }
  func run(_ command: SystemCommand) async throws {
    guard case .kickstart = command else { return }
    restarts += 1
    pid += 1
    launchedWithFullDisk = fullDiskOn
    assistantCalls = 0
    launchedAt = .now
  }
  func startTime(pid: Int32) async -> Date? { launchedAt }
  func isOutdated(pid: Int32, executable: URL) async -> Bool { false }
  func requestContactsAccess() async -> PermissionStatus { .authorized }
  func requestHelperPermission(_ permission: SetupPermission, endpoint: URL, processID: Int32)
    async throws -> SetupPermissionReply
  {
    throw CoreError.invalidResponse
  }
  func pause() async {}
}

@MainActor @Test func openingThePanelRestartsTheHelperToSeeAFullDiskGrant() async throws {
  let system = LaunchGrantSystem(fullDiskOn: false)
  let model = try model(system)
  await model.refresh()
  #expect(model.state.phase == .setup(.readMessages))
  await system.turnOnFullDisk()
  await model.panelOpened()
  await model.prepareToQuit()
  #expect(await system.restarts == 1)
  #expect(model.state.phase == .setup(.connectAssistant))
  #expect(model.notice == nil)
}

@MainActor @Test func checkAgainWithoutTheGrantSaysTheStepIsUnfinished() async throws {
  let system = LaunchGrantSystem(fullDiskOn: false)
  let model = try model(system)
  await model.refresh()
  model.recheck()
  #expect(model.busy == .checkingAccess)
  await model.prepareToQuit()
  #expect(await system.restarts == 1)
  #expect(model.state.phase == .setup(.readMessages))
  #expect(model.notice == .setupUnfinished)
  // A panel opened right after holds off: launchd would throttle the restart.
  await model.panelOpened()
  await model.prepareToQuit()
  #expect(await system.restarts == 1)
}

@MainActor @Test func aStepThatNeedsNoRestartOnlyChecks() async throws {
  let system = LaunchGrantSystem(fullDiskOn: true)
  let model = try model(system)
  await model.panelOpened()
  await model.prepareToQuit()
  #expect(await system.restarts == 0)
  #expect(model.state.phase == .setup(.connectAssistant))
}

@MainActor @Test func theFirstAssistantCallFinishesSetupAndOutlivesTheHelper() async throws {
  let system = LaunchGrantSystem(fullDiskOn: true)
  let milestones = Milestones(defaults: nil)
  let app = try model(system, milestones: milestones)
  await app.refresh()
  #expect(app.state.phase == .setup(.connectAssistant))
  await system.call()
  await app.refresh()
  #expect(app.state.phase == .ready)
  #expect(app.notice == .tried)
  #expect(app.celebration == 1)

  try await system.run(.kickstart(label: ServiceDefaults.launchdLabel, restart: true))
  await app.refresh()
  #expect(app.state.phase == .ready)
  #expect(app.celebration == 1)
  let reopened = try model(system, milestones: milestones)
  await reopened.refresh()
  #expect(reopened.state.phase == .ready)
}

@MainActor @Test func anAssistantCallBeforeTheGrantsAreDoneIsKeptQuietly() async throws {
  let system = LaunchGrantSystem(fullDiskOn: false)
  let app = try model(system)
  await system.call()
  await app.refresh()
  #expect(app.tried)
  #expect(app.state.phase == .setup(.readMessages))
  #expect(app.notice == nil)
  #expect(app.celebration == 0)
}

@MainActor @Test func reopeningResumesAtTheFirstUnfinishedStep() async throws {
  let system = LaunchGrantSystem(fullDiskOn: true)
  let milestones = Milestones(defaults: nil)
  let first = try model(system, milestones: milestones)
  await first.refresh()
  first.skipConnect(true)
  #expect(first.state.phase == .setup(.tryIt))
  let reopened = try model(system, milestones: milestones)
  await reopened.refresh()
  #expect(reopened.state.phase == .setup(.tryIt))
  reopened.skipConnect(false)
  #expect(reopened.state.phase == .setup(.connectAssistant))
  #expect(!milestones.reached(.skippedConnect))
}

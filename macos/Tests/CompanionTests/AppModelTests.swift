import AppKit
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
private func model(
  _ system: any ServiceSystem, milestones: Milestones = Milestones(defaults: nil),
  home: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
) throws -> AppModel {
  let plist = try PropertyListSerialization.data(
    fromPropertyList: [
      "Label": ServiceDefaults.launchdLabel, "BundleProgram": ServiceDefaults.helperBundlePath,
      "AssociatedBundleIdentifiers": [ServiceDefaults.companionBundleID],
      "ProgramArguments": [ServiceDefaults.executableName, "--http", "--port", "8080"],
    ], format: .xml, options: 0)
  let configuration = try ServiceConfiguration(
    plist: plist, plistName: "\(ServiceDefaults.launchdLabel).plist",
    bundleIdentifier: ServiceDefaults.companionBundleID,
    bundleURL: URL(fileURLWithPath: "/Applications/iMessage Max.app"),
    home: home)
  // These helpers run under the plist this app registered.
  try RegisteredAgent(configuration: configuration).save()
  return AppModel(
    controller: ServiceController(configuration: configuration, system: system, home: home),
    milestones: milestones,
    changeDeadline: 0.3, permissionDeadline: 0.3)
}

@Suite struct AppModelTests {
  @MainActor @Test func keepRunningIsOnUntilTheUserTurnsItOff() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let marker = home.appendingPathComponent(ServiceDefaults.tokenPath).deletingLastPathComponent()
      .appendingPathComponent(ServiceDefaults.stayStoppedFileName)
    let first = try model(StuckSystem(running: false), home: home)
    #expect(first.keepRunning == true)

    first.setKeepRunning(false)
    #expect(first.keepRunning == false)
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(try model(StuckSystem(running: false), home: home).keepRunning == false)

    first.setKeepRunning(true)
    #expect(first.keepRunning == true)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(first.problem == nil)
  }

  @MainActor @Test func keepRunningIsHiddenWithoutAHelperToKeep() {
    let model = AppModel(
      controller: nil, milestones: Milestones(defaults: nil))
    #expect(model.keepRunning == nil)
    model.setKeepRunning(false)
    #expect(model.keepRunning == nil)
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

  @MainActor @Test func comingBackRestartsTheHelperToSeeAFullDiskGrant() async throws {
    let system = LaunchGrantSystem(fullDiskOn: false)
    let model = try model(system)
    await model.refresh()
    #expect(model.state.phase == .setup(.fullDiskAccess))
    await system.turnOnFullDisk()
    await model.opened()
    await model.prepareToQuit()
    #expect(await system.restarts == 1)
    #expect(model.state.phase == .ready)
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
    #expect(model.state.phase == .setup(.fullDiskAccess))
    #expect(model.notice == .setupUnfinished)
    // Coming back right after holds off: launchd would throttle the restart.
    await model.opened()
    await model.prepareToQuit()
    #expect(await system.restarts == 1)
  }

  @MainActor @Test func aStepThatNeedsNoRestartOnlyChecks() async throws {
    let system = LaunchGrantSystem(fullDiskOn: true)
    let model = try model(system)
    await model.opened()
    await model.prepareToQuit()
    #expect(await system.restarts == 0)
    #expect(model.state.phase == .ready)
  }

  @MainActor @Test func theFirstAssistantCallCelebratesOnceAndOutlivesTheHelper() async throws {
    let system = LaunchGrantSystem(fullDiskOn: true)
    let milestones = Milestones(defaults: nil)
    let app = try model(system, milestones: milestones)
    await app.refresh()
    #expect(!app.triedNews)
    await system.call()
    await app.refresh()
    #expect(app.triedNews)
    #expect(app.celebration == 1)
    app.newsSeen()
    #expect(!app.triedNews)

    try await system.run(.kickstart(label: ServiceDefaults.launchdLabel, restart: true))
    await app.refresh()
    #expect(app.celebration == 1)
    let reopened = try model(system, milestones: milestones)
    await reopened.refresh()
    #expect(reopened.tried)
    #expect(reopened.celebration == 0)
  }

  @MainActor @Test func anAssistantCallBeforeTheGrantsAreDoneIsKeptQuietly() async throws {
    let system = LaunchGrantSystem(fullDiskOn: false)
    let app = try model(system)
    await system.call()
    await app.refresh()
    #expect(app.tried)
    #expect(app.state.phase == .setup(.fullDiskAccess))
    #expect(!app.triedNews)
    #expect(app.celebration == 0)
  }

  @MainActor @Test func notNowRetiresTheConnectPromptAcrossLaunches() async throws {
    let system = LaunchGrantSystem(fullDiskOn: true)
    let milestones = Milestones(defaults: nil)
    let first = try model(system, milestones: milestones)
    await first.refreshClients()
    await first.refresh()
    #expect(first.state.offersConnect)
    #expect(first.state.connections == "None")
    first.dismissConnect()
    #expect(!first.state.offersConnect)
    let reopened = try model(system, milestones: milestones)
    await reopened.refreshClients()
    await reopened.refresh()
    #expect(reopened.state.phase == .ready)
    #expect(!reopened.state.offersConnect)
  }

  @MainActor @Test func anAssistantCallRetiresTheConnectPrompt() async throws {
    let system = LaunchGrantSystem(fullDiskOn: true)
    let app = try model(system)
    await app.refreshClients()
    await app.refresh()
    #expect(app.state.offersConnect)
    await system.call()
    await app.refresh()
    #expect(!app.state.offersConnect)
  }

  /// Lets queued main-queue work, such as a menu choice, run.
  @MainActor private func drainMainQueue() async {
    await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
  }

  @MainActor @Test func theStatusMenuNamesTheNextStepAndOpensItsPage() async throws {
    let system = LaunchGrantSystem(fullDiskOn: false)
    let app = try model(system)
    await app.refreshClients()
    await app.refresh()
    var opened: [SettingsPage?] = []
    let status = StatusMenuController(model: app) { opened.append($0) }
    status.menuNeedsUpdate(status.menu)
    #expect(status.menu.items.map(\.title) == [
      "iMessage Max", "Turn on Full Disk Access", "", "Connections: None", "", "Settings…", "",
      "Quit iMessage Max",
    ])
    #expect(status.menu.items[5].keyEquivalent == ",")
    #expect(status.menu.items[7].keyEquivalent == "q")
    status.menu.performActionForItem(at: 1)
    status.menu.performActionForItem(at: 3)
    status.menu.performActionForItem(at: 5)
    await drainMainQueue()
    #expect(opened == [.permissions, .connections, nil])

    await system.turnOnFullDisk()
    await app.opened()
    await app.prepareToQuit()
    await drainMainQueue()
    #expect(status.menu.items.map(\.title).contains("Turn on Full Disk Access") == false)
  }

  @MainActor @Test func theMenuHeaderNewsLastsUntilTheMenuCloses() async throws {
    let system = LaunchGrantSystem(fullDiskOn: true)
    let app = try model(system)
    await app.refresh()
    await system.call()
    await app.refresh()
    let status = StatusMenuController(model: app) { _ in }
    status.menuWillOpen(status.menu)
    #expect(app.menuOpen && app.triedNews)
    status.menuDidClose(status.menu)
    #expect(!app.menuOpen && !app.triedNews)
  }
}

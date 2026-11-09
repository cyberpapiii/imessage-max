import Foundation
import IMessageMaxContract
import MaxCore
import MaxTestSupport
import Testing

@testable import iMessageMaxMenu

/// A helper an update left on the old binary: running as pid 300, answering
/// or not, until a kickstart starts the new binary as pid 301.
private actor UpdatedSystem: ServiceSystem {
  var answering: Bool
  private var pid: Int32 = 300
  private var outdated = true
  private(set) var commands: [SystemCommand] = []

  init(answering: Bool) { self.answering = answering }

  func agentStatus(plistName: String) async -> AgentStatus { .enabled }
  func job(label: String) async -> Job? { label == LegacyInstall.label ? nil : Job(pid: pid) }
  func diagnose(endpoint: URL) async -> DiagnoseReply {
    guard answering, let result = try? diagnosis(processID: pid) else { return .silent }
    return .answered(result)
  }
  func listeners(port: Int) async -> Set<Int32> { answering ? [pid] : [] }
  func run(_ command: SystemCommand) async throws {
    commands.append(command)
    if case .kickstart = command {
      pid += 1
      outdated = false
      answering = true
    }
  }
  func isOutdated(pid: Int32, executable: URL) async -> Bool { outdated }
  func requestContactsAccess() async -> PermissionStatus { .authorized }
  func requestHelperPermission(_ permission: SetupPermission, endpoint: URL, processID: Int32)
    async throws -> SetupPermissionReply
  {
    SetupPermissionReply(
      permission: permission, authorized: true, status: .authorized, processID: processID)
  }
  func pause() async {}
}

@MainActor
private func model(
  _ system: any ServiceSystem, registered: Bool = true, updateGrace: Duration = .zero
) throws -> AppModel {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let plist = try PropertyListSerialization.data(
    fromPropertyList: [
      "Label": ServiceDefaults.launchdLabel, "BundleProgram": ServiceDefaults.helperBundlePath,
      "AssociatedBundleIdentifiers": [ServiceDefaults.companionBundleID],
      "ProgramArguments": [ServiceDefaults.executableName, "--http", "--port", "8080"],
    ], format: .xml, options: 0)
  let configuration = try ServiceConfiguration(
    plist: plist, plistName: "\(ServiceDefaults.launchdLabel).plist",
    bundleIdentifier: ServiceDefaults.companionBundleID,
    bundleURL: URL(fileURLWithPath: "/Applications/iMessage Max.app"), home: home)
  if registered { try RegisteredAgent(configuration: configuration).save() }
  return AppModel(
    controller: ServiceController(configuration: configuration, system: system, home: home),
    milestones: Milestones(defaults: nil), updateGrace: updateGrace)
}

/// The companion's minute check moves a helper an update left behind to the
/// new binary and plist, so an update takes effect with the companion in the
/// background, even when that helper no longer answers (088 #19).
@Suite struct UpdateCheckTests {
  @MainActor @Test func thePeriodicCheckRestartsAnOutdatedHelper() async throws {
    let system = UpdatedSystem(answering: true)
    let model = try model(system)
    await model.periodicCheck()
    await model.prepareToQuit()
    #expect(await system.commands == [.kickstart(label: ServiceDefaults.launchdLabel, restart: true)])
    #expect(model.diagnosis?.processID == 301)

    await model.periodicCheck()
    await model.prepareToQuit()
    #expect(await system.commands.count == 1, "an up-to-date helper is left alone")
  }

  @MainActor @Test func aHelperThatDoesNotAnswerIsRestartedToo() async throws {
    let system = UpdatedSystem(answering: false)
    let model = try model(system)
    await model.periodicCheck()
    await model.prepareToQuit()
    #expect(await system.commands == [.kickstart(label: ServiceDefaults.launchdLabel, restart: true)])
    #expect(model.diagnosis?.processID == 301)
  }

  /// The helper restarts itself on a new binary once idle, so the companion
  /// waits before it kills one that may be finishing a call.
  @MainActor @Test func aNewBinaryGetsTheHelperTimeToRestartItself() async throws {
    let system = UpdatedSystem(answering: true)
    let model = try model(system, updateGrace: .seconds(3600))
    await model.periodicCheck()
    await model.periodicCheck()
    await model.prepareToQuit()
    #expect(await system.commands.isEmpty)
  }

  /// Only a registration loads a changed plist, and only the app can do it.
  @MainActor @Test func aChangedPlistIsRegisteredAtOnce() async throws {
    let system = UpdatedSystem(answering: true)
    let model = try model(system, registered: false, updateGrace: .seconds(3600))
    await model.periodicCheck()
    await model.prepareToQuit()
    #expect(
      await system.commands.prefix(2) == [
        .unregister(plistName: "\(ServiceDefaults.launchdLabel).plist"),
        .register(plistName: "\(ServiceDefaults.launchdLabel).plist"),
      ])
  }
}

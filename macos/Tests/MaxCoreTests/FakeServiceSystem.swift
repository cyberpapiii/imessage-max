import Foundation
import IMessageMaxContract
import MaxCore
import MaxTestSupport

/// A small launchd and SMAppService: commands change the world the way the
/// real ones do, and every command is recorded.
actor FakeServiceSystem: ServiceSystem {
  var agent: AgentStatus = .notRegistered
  var loaded = false
  var pid: Int32?
  var answering = true
  /// The helper holds another token than the app reads, so it answers 401.
  var refusing = false
  var legacyLoaded = false
  var foreign: Set<Int32> = []
  var contactsAnswer: PermissionStatus = .authorized
  var contactsGranted = false
  var outdated = false
  var failNextRegister = false
  /// Registering leaves the helper off in Login Items, as after the user
  /// turned it off there.
  var registerNeedsApproval = false
  /// The plist the app bundles now. launchd loads it only when an agent that
  /// is not registered registers: registering again keeps `loadedPlist`.
  var bundledPlist = "A"
  private(set) var loadedPlist: String?
  private(set) var commands: [SystemCommand] = []
  private(set) var contactRequests = 0
  private(set) var pauses = 0
  private var nextPID: Int32 = 200

  func set(_ change: @Sendable (isolated FakeServiceSystem) -> Void) { change(self) }

  /// A registered, running helper.
  func startRunning() {
    agent = .enabled
    loadedPlist = bundledPlist
    loaded = true
    launch()
  }

  func agentStatus(plistName: String) async -> AgentStatus { agent }

  func job(label: String) async -> Job? {
    if label == LegacyInstall.label { return legacyLoaded ? Job(pid: 77) : nil }
    return loaded ? Job(pid: pid) : nil
  }

  func diagnose(endpoint: URL) async -> DiagnoseReply {
    guard let pid else { return .silent }
    if refusing { return .refused }
    guard answering, let result = try? diagnosis(contacts: contactsGranted, processID: pid) else {
      return .silent
    }
    return .answered(result)
  }

  func listeners(port: Int) async -> Set<Int32> {
    foreign.union(legacyLoaded && port == ServiceDefaults.port ? [77] : [])
      .union(pid.map { [$0] } ?? [])
  }

  func run(_ command: SystemCommand) async throws {
    commands.append(command)
    switch command {
    case .register:
      if failNextRegister {
        failNextRegister = false
        throw CoreError.commandFailed("register failed")
      }
      if agent == .notRegistered { loadedPlist = bundledPlist }
      if registerNeedsApproval {
        agent = .requiresApproval
        return
      }
      agent = .enabled
      loaded = true
      launch()
    case .unregister:
      agent = .notRegistered
      loadedPlist = nil
      loaded = false
      pid = nil
    case .kickstart(_, let restart):
      guard loaded else { throw CoreError.commandFailed("no such job") }
      if restart || pid == nil { launch() }
    case .bootout(let label):
      if label == LegacyInstall.label {
        legacyLoaded = false
      } else {
        loaded = false
        pid = nil
      }
    }
  }

  func isOutdated(pid: Int32, executable: URL) async -> Bool { outdated }

  func requestContactsAccess() async -> PermissionStatus {
    contactRequests += 1
    if PermissionStatus.namesAvailable.contains(contactsAnswer) { contactsGranted = true }
    return contactsAnswer
  }

  func requestHelperPermission(_ permission: SetupPermission, endpoint: URL, processID: Int32)
    async throws -> SetupPermissionReply
  {
    SetupPermissionReply(
      permission: permission, authorized: true, status: .authorized, processID: processID)
  }

  func pause() async { pauses += 1 }

  /// A helper reads Contacts access and its token once, at launch.
  private func launch() {
    refusing = false
    pid = nextPID
    nextPID += 1
  }
}

func temporaryHome() throws -> URL {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(
    "max-home-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  return home
}

func agentPlist(
  label: String = ServiceDefaults.launchdLabel, bundleID: String = ServiceDefaults.companionBundleID,
  arguments: [String] = [ServiceDefaults.executableName, "--http", "--port", "8080"],
  program: String = ServiceDefaults.helperBundlePath
) throws -> Data {
  try PropertyListSerialization.data(
    fromPropertyList: [
      "Label": label, "BundleProgram": program, "AssociatedBundleIdentifiers": [bundleID],
      "ProgramArguments": arguments,
    ], format: .xml, options: 0)
}

func configuration(
  label: String = ServiceDefaults.launchdLabel, bundleID: String = ServiceDefaults.companionBundleID,
  port: Int = 8080, app: String = "/Applications/iMessage Max.app", home: URL
) throws -> ServiceConfiguration {
  try ServiceConfiguration(
    plist: agentPlist(
      label: label, bundleID: bundleID,
      arguments: [ServiceDefaults.executableName, "--http", "--port", String(port)]),
    plistName: "\(label).plist", bundleIdentifier: bundleID,
    bundleURL: URL(fileURLWithPath: app), home: home)
}

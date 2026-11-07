import Foundation
import IMessageMaxContract
import MaxTestSupport
import Testing

@testable import MaxCore

@Test func everyStateComesFromOneRule() throws {
  let mine = try diagnosis(processID: 200)
  let theirs = try diagnosis(processID: 999)
  let running = Job(pid: 200)
  let table: [(ServiceObservation, ServiceState)] = [
    (.init(location: .translocated, legacy: true, agent: .enabled), .misplaced(translocated: true)),
    (.init(location: .elsewhere, agent: .notRegistered), .misplaced(translocated: false)),
    (.init(legacy: true, agent: .requiresApproval, foreignListener: true), .legacyInstall),
    (.init(agent: .requiresApproval, foreignListener: true), .blockedInLoginItems),
    (.init(agent: .notRegistered, foreignListener: true), .portConflict),
    (.init(agent: .enabled, job: running, diagnosis: theirs, foreignListener: true), .portConflict),
    (.init(agent: .notRegistered), .notRegistered),
    (.init(agent: .enabled), .stopped),
    (.init(agent: .enabled, job: Job(pid: nil)), .stopped),
    (.init(agent: .enabled, job: running), .unresponsive),
    (.init(agent: .enabled, job: running, refused: true), .tokenRejected),
    (.init(agent: .enabled, refused: true, foreignListener: true), .portConflict),
    (.init(agent: .enabled, job: running, diagnosis: mine), .running(mine)),
  ]
  for (observation, expected) in table {
    #expect(ServiceState(observation) == expected, "\(observation)")
  }
}

@Test func onlyRegisteredStatesShowTheSwitch() throws {
  let running = ServiceState.running(try diagnosis())
  #expect(running.isRegistered && running.isRunning)
  #expect(ServiceState.unresponsive.isRegistered && ServiceState.unresponsive.isRunning)
  #expect(ServiceState.tokenRejected.isRegistered && ServiceState.tokenRejected.isRunning)
  #expect(ServiceState.stopped.isRegistered && !ServiceState.stopped.isRunning)
  for state in [ServiceState.notRegistered, .blockedInLoginItems, .legacyInstall, .portConflict] {
    #expect(!state.isRegistered)
  }
}

@Test func appLocationAcceptsOnlyApplicationsFolders() {
  let home = URL(fileURLWithPath: "/Users/someone")
  func location(_ path: String) -> AppLocation {
    AppLocation(bundleURL: URL(fileURLWithPath: path), home: home)
  }
  #expect(location("/Applications/iMessage Max.app") == .installed)
  #expect(location("/Applications/Tools/iMessage Max.app") == .installed)
  #expect(location("/Users/someone/Applications/iMessage Max.app") == .installed)
  #expect(location("/Users/someone/Downloads/iMessage Max.app") == .elsewhere)
  #expect(location("/Applications Old/iMessage Max.app") == .elsewhere)
  #expect(
    location("/private/var/folders/x/T/AppTranslocation/ABCD/d/iMessage Max.app") == .translocated)
}

@Test func readsTheRunningPidFromLaunchctl() {
  #expect(Job(launchctlPrint: "gui/501/x = {\n\tstate = running\n\tpid = 4242\n}").pid == 4242)
  #expect(Job(launchctlPrint: "gui/501/x = {\n\tstate = not running\n}").pid == nil)
}

@Test func configurationComesFromTheBundledPlist() throws {
  let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/LaunchAgents/\(ServiceDefaults.launchdLabel).plist")
  let home = URL(fileURLWithPath: "/Users/someone")
  let config = try ServiceConfiguration(
    plist: Data(contentsOf: source), plistName: source.lastPathComponent,
    bundleIdentifier: ServiceDefaults.companionBundleID,
    bundleURL: URL(fileURLWithPath: "/Applications/iMessage Max.app"), home: home)
  #expect(config.label == ServiceDefaults.launchdLabel)
  #expect(config.endpoint.absoluteString == "http://127.0.0.1:\(ServiceDefaults.port)/")
  #expect(config.log.path == "/Users/someone/\(ServiceDefaults.logPath)")
  #expect(config.tokenFile.path == "/Users/someone/\(ServiceDefaults.tokenPath)")
  #expect(config.helper.path == "/Applications/iMessage Max.app/Contents/MacOS/imessage-max")
  #expect(config.isProduction)

  let test = try configuration(
    label: "com.cyberpapiii.imessage-max.p3test.helper",
    bundleID: "com.cyberpapiii.imessage-max.p3test", port: 18383, home: home)
  #expect(test.port == 18383)
  #expect(!test.isProduction)
}

@Test func rejectsAPlistThatDoesNotDescribeThisApp() throws {
  let home = URL(fileURLWithPath: "/tmp/home")
  func parse(_ data: Data, name: String = "\(ServiceDefaults.launchdLabel).plist") throws {
    _ = try ServiceConfiguration(
      plist: data, plistName: name, bundleIdentifier: ServiceDefaults.companionBundleID,
      bundleURL: URL(fileURLWithPath: "/Applications/iMessage Max.app"), home: home)
  }
  try parse(agentPlist())
  let ipv6 = try ServiceConfiguration(
    plist: agentPlist(arguments: ["imessage-max", "--http", "--host=::1", "--port=9191"]),
    plistName: "\(ServiceDefaults.launchdLabel).plist",
    bundleIdentifier: ServiceDefaults.companionBundleID,
    bundleURL: URL(fileURLWithPath: "/Applications/iMessage Max.app"), home: home)
  #expect(ipv6.endpoint.absoluteString == "http://[::1]:9191/")
  try parse(agentPlist(arguments: ["imessage-max", "--http", "--socket-path", "/tmp/test/mcp.sock"]))
  let custom = try ServiceConfiguration(
    plist: agentPlist(arguments: ["imessage-max", "--http", "--token-file", "~/test/token"]),
    plistName: "\(ServiceDefaults.launchdLabel).plist",
    bundleIdentifier: ServiceDefaults.companionBundleID,
    bundleURL: URL(fileURLWithPath: "/Applications/iMessage Max.app"), home: home)
  #expect(custom.tokenFile.path == "/tmp/home/test/token")
  #expect(throws: CoreError.self) { try parse(agentPlist(), name: "other.plist") }
  #expect(throws: CoreError.self) { try parse(agentPlist(bundleID: "com.example.other")) }
  #expect(throws: CoreError.self) { try parse(agentPlist(program: "Contents/MacOS/other")) }
  #expect(throws: CoreError.self) {
    try parse(agentPlist(arguments: ["imessage-max", "--http", "--host=0.0.0.0", "--allow-external-bind"]))
  }
  #expect(throws: CoreError.self) {
    try parse(agentPlist(arguments: ["imessage-max", "--http", "--port", "8080", "--port=9191"]))
  }
  #expect(throws: CoreError.self) { try parse(agentPlist(arguments: ["imessage-max"])) }
}

@Test func aBundleNeedsExactlyOneAgentPlist() throws {
  let bundle = try temporaryHome().appendingPathComponent("Test.app")
  let agents = bundle.appendingPathComponent(ServiceDefaults.agentPlistDirectory)
  try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": ServiceDefaults.companionBundleID], format: .xml,
    options: 0
  ).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
  try agentPlist().write(to: agents.appendingPathComponent("\(ServiceDefaults.launchdLabel).plist"))
  let loaded = try ServiceConfiguration.load(bundle: try #require(Bundle(url: bundle)))
  #expect(loaded.label == ServiceDefaults.launchdLabel)
  try agentPlist(label: "second").write(to: agents.appendingPathComponent("second.plist"))
  #expect(throws: CoreError.self) {
    try ServiceConfiguration.load(bundle: try #require(Bundle(url: bundle)))
  }
}

@Test func controllerRegistersStartsStopsAndRestarts() async throws {
  let system = FakeServiceSystem()
  let controller = ServiceController(
    configuration: try configuration(home: try temporaryHome()), system: system,
    home: try temporaryHome())
  #expect(await controller.inspect() == .notRegistered)

  let started = try await controller.perform(.start)
  #expect(started.diagnosis?.processID == 200)
  #expect(try await controller.perform(.start) == started, "starting a running helper changes nothing")

  #expect(try await controller.perform(.stop) == .stopped)
  #expect(try await controller.perform(.start).diagnosis?.processID == 201)
  #expect(try await controller.perform(.restart).diagnosis?.processID == 202)

  let plist = "\(ServiceDefaults.launchdLabel).plist"
  let label = ServiceDefaults.launchdLabel
  #expect(
    await system.commands == [
      .register(plistName: plist),
      .bootout(label: label),
      .unregister(plistName: plist), .register(plistName: plist),
      .kickstart(label: label, restart: true),
    ],
    "a stop unloads the job, so the next start registers it again")
}

@Test func blockedStatesChangeNothing() async throws {
  let home = try temporaryHome()
  let blocked = FakeServiceSystem()
  await blocked.set { $0.agent = .requiresApproval }
  let taken = FakeServiceSystem()
  await taken.set { $0.foreign = [999] }
  for (system, expected) in [
    (blocked, ServiceState.blockedInLoginItems), (taken, .portConflict),
  ] {
    let controller = ServiceController(
      configuration: try configuration(home: home), system: system, home: home)
    await #expect(throws: CoreError.notReady(expected)) { try await controller.perform(.start) }
    #expect(await system.commands.isEmpty)
  }
  let misplaced = ServiceController(
    configuration: try configuration(app: "/Users/x/Downloads/iMessage Max.app", home: home),
    system: FakeServiceSystem(), home: home)
  await #expect(throws: CoreError.notReady(.misplaced(translocated: false))) {
    try await misplaced.perform(.start)
  }
}

@Test func contactsAreAskedInTheAppThenTheHelperRestarts() async throws {
  let system = FakeServiceSystem()
  await system.startRunning()
  let home = try temporaryHome()
  let controller = ServiceController(
    configuration: try configuration(home: home), system: system, home: home)

  let reply = try await controller.requestPermission(.contacts)
  #expect(reply.authorized && reply.processID == 201)
  #expect(await controller.inspect().diagnosis?.grants(.contacts) == true)
  #expect(
    await system.commands == [.kickstart(label: ServiceDefaults.launchdLabel, restart: true)])

  let again = try await controller.requestPermission(.contacts)
  #expect(again.authorized && again.processID == 201)
  #expect(await system.contactRequests == 1, "a granted permission is not asked again")
}

@Test func deniedContactsDoNotRestartTheHelper() async throws {
  let system = FakeServiceSystem()
  await system.startRunning()
  await system.set { $0.contactsAnswer = .denied }
  let home = try temporaryHome()
  let controller = ServiceController(
    configuration: try configuration(home: home), system: system, home: home)
  let reply = try await controller.requestPermission(.contacts)
  #expect(!reply.authorized && reply.status == .denied)
  #expect(await system.commands.isEmpty)
}

@Test func automationIsAskedByTheHelper() async throws {
  let system = FakeServiceSystem()
  await system.startRunning()
  let home = try temporaryHome()
  let controller = ServiceController(
    configuration: try configuration(home: home), system: system, home: home)
  let reply = try await controller.requestPermission(.automation)
  #expect(reply.processID == 200)
  #expect(await system.contactRequests == 0)
}

@Test func anOutdatedHelperRestartsOnTheNewBinary() async throws {
  let system = FakeServiceSystem()
  await system.startRunning()
  let home = try temporaryHome()
  let controller = ServiceController(
    configuration: try configuration(home: home), system: system, home: home)
  #expect(try await controller.restartIfOutdated().diagnosis?.processID == 200)
  await system.set { $0.outdated = true }
  #expect(try await controller.restartIfOutdated().diagnosis?.processID == 201)
}

@Test func turnedOffInLoginItemsEndsTheWaitAtOnce() async throws {
  let home = try temporaryHome()
  let system = FakeServiceSystem()
  await system.set { $0.registerNeedsApproval = true }
  let controller = ServiceController(
    configuration: try configuration(home: home), system: system, home: home)
  await #expect(throws: CoreError.notReady(.blockedInLoginItems)) {
    try await controller.perform(.start)
  }
  #expect(await system.pauses == 0)
}

@Test func aHelperThatRefusesTheTokenAsksForARestartThatClearsIt() async throws {
  let home = try temporaryHome()
  let system = FakeServiceSystem()
  await system.set {
    $0.startRunning()
    $0.refusing = true
  }
  let controller = ServiceController(
    configuration: try configuration(home: home), system: system, home: home)
  #expect(await controller.inspect() == .tokenRejected)
  let restarted = try await controller.perform(.restart)
  #expect(restarted.diagnosis != nil)
}

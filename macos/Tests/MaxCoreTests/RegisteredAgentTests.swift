import Foundation
import IMessageMaxContract
import Testing

@testable import MaxCore

/// An update that changes the agent plist must reach launchd, which keeps a
/// registered job on the plist it loaded first. The fake models that: only a
/// register after an unregister loads `bundledPlist`.
@Suite struct RegisteredAgentTests {
  private let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("registered-agent-\(UUID().uuidString)")
  private let plist = "\(ServiceDefaults.launchdLabel).plist"
  private let label = ServiceDefaults.launchdLabel

  /// The plist before and after the update: 2.0.0 also relaunched on a crash.
  private func configuration(crashed: Bool, _ extra: [String] = []) throws -> ServiceConfiguration {
    var keepAlive: [String: Bool] = ["SuccessfulExit": false]
    if crashed { keepAlive["Crashed"] = true }
    let data = try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": label, "BundleProgram": ServiceDefaults.helperBundlePath,
        "AssociatedBundleIdentifiers": [ServiceDefaults.companionBundleID],
        "ProgramArguments": [ServiceDefaults.executableName, "--http", "--port", "8080"] + extra,
        "KeepAlive": keepAlive,
      ], format: .xml, options: 0)
    return try ServiceConfiguration(
      plist: data, plistName: plist, bundleIdentifier: ServiceDefaults.companionBundleID,
      bundleURL: URL(fileURLWithPath: "/Applications/iMessage Max.app"), home: home)
  }

  private func controller(_ system: FakeServiceSystem, crashed: Bool) throws -> ServiceController {
    ServiceController(configuration: try configuration(crashed: crashed), system: system, home: home)
  }

  /// Installs the old app and registers it, then puts the new app in place.
  private func updated() async throws -> (FakeServiceSystem, ServiceController) {
    let system = FakeServiceSystem()
    #expect(try await controller(system, crashed: true).perform(.start).diagnosis != nil)
    await system.set { $0.bundledPlist = "B" }
    return (system, try controller(system, crashed: false))
  }

  @Test func anAppLaunchAfterAnUpdateLoadsTheChangedPlistOnce() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let (system, controller) = try await updated()
    #expect(!controller.definitionIsCurrent)

    #expect(try await controller.restartIfOutdated().diagnosis?.processID == 201)
    #expect(await system.loadedPlist == "B")
    #expect(controller.definitionIsCurrent)
    #expect(
      await system.commands == [
        .register(plistName: plist), .unregister(plistName: plist), .register(plistName: plist),
      ])

    #expect(try await controller.restartIfOutdated().diagnosis?.processID == 201)
    #expect(await system.commands.count == 3, "a second launch registers nothing")
  }

  @Test func registerHelperAfterAnUpdateLoadsTheChangedPlist() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let (system, controller) = try await updated()
    // `--register-helper` restarts a registered helper.
    #expect(try await controller.perform(.restart).diagnosis?.processID == 201)
    #expect(await system.loadedPlist == "B")
    #expect(Array(await system.commands.dropFirst()) == [
      .unregister(plistName: plist), .register(plistName: plist),
    ])

    #expect(try await controller.perform(.restart).diagnosis?.processID == 202)
    #expect(
      await system.commands.last == .kickstart(label: label, restart: true),
      "with the plist loaded, a restart is a kickstart again")
  }

  @Test func anUnchangedPlistIsNeverRegisteredAgain() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let system = FakeServiceSystem()
    let first = try controller(system, crashed: false)
    _ = try await first.perform(.start)
    // The same plist bytes in a new build: an update that left it alone.
    let controller = try controller(system, crashed: false)
    #expect(controller.definitionIsCurrent)

    #expect(try await controller.restartIfOutdated().diagnosis?.processID == 200)
    await system.set { $0.outdated = true }
    #expect(try await controller.restartIfOutdated().diagnosis?.processID == 201)
    #expect(try await controller.perform(.restart).diagnosis?.processID == 202)
    #expect(
      await system.commands == [
        .register(plistName: plist),
        .kickstart(label: label, restart: true), .kickstart(label: label, restart: true),
      ])
  }

  @Test func aHelperRegisteredBeforeTheRecordIsRegisteredAgainOnce() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let system = FakeServiceSystem()
    await system.startRunning()
    let controller = try controller(system, crashed: false)
    #expect(!controller.definitionIsCurrent, "no record: launchd may hold 2.0.0's plist")

    #expect(try await controller.restartIfOutdated().diagnosis?.processID == 201)
    #expect(await system.commands == [.unregister(plistName: plist), .register(plistName: plist)])
    let record = RegisteredAgent(configuration: controller.configuration)
    let saved = try String(contentsOf: record.file, encoding: .utf8)
    #expect(saved == "\(controller.configuration.plistDigest)\n")

    #expect(try await controller.restartIfOutdated().diagnosis?.processID == 201)
    #expect(await system.commands.count == 2)
  }

  @Test func aStoppedHelperLoadsTheChangedPlistOnlyWhenStarted() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let (system, controller) = try await updated()
    _ = try await controller.perform(.stop)
    let before = await system.commands.count

    #expect(try await controller.restartIfOutdated() == .stopped, "a launch starts nothing")
    #expect(await system.commands.count == before)

    _ = try await controller.perform(.start)
    #expect(await system.loadedPlist == "B")
  }

  @Test func turnedOffInLoginItemsIsLeftAlone() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let system = FakeServiceSystem()
    await system.set { $0.agent = .requiresApproval }
    let controller = try controller(system, crashed: false)
    #expect(try await controller.restartIfOutdated() == .blockedInLoginItems)
    #expect(await system.commands.isEmpty)
  }

  @Test func theRecordSitsBesideTheTokenAndGoesWithTheHelper() async throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let variant = RegisteredAgent(
      configuration: try configuration(crashed: false, ["--token-file", "/tmp/imax-test/token"]))
    #expect(variant.file.path == "/tmp/imax-test/\(ServiceDefaults.registeredAgentFileName)")
    #expect(
      try configuration(crashed: true).plistDigest != configuration(crashed: false).plistDigest)

    let system = FakeServiceSystem()
    let controller = try controller(system, crashed: false)
    _ = try await controller.perform(.start)
    let record = RegisteredAgent(configuration: controller.configuration)
    #expect(
      record.file
        == home.appendingPathComponent(ServiceDefaults.tokenPath).deletingLastPathComponent()
        .appendingPathComponent(ServiceDefaults.registeredAgentFileName))
    let folder = try FileManager.default.attributesOfItem(
      atPath: record.file.deletingLastPathComponent().path)
    #expect((folder[.posixPermissions] as? Int) == 0o700)
    let file = try FileManager.default.attributesOfItem(atPath: record.file.path)
    #expect((file[.posixPermissions] as? Int) == 0o600)

    _ = try await controller.unregister()
    #expect(!FileManager.default.fileExists(atPath: record.file.path))
    #expect(!controller.definitionIsCurrent)
  }
}

/// The companion's periodic check restarts a helper an update left behind
/// whether or not it answers, and leaves a stopped one alone (088 #19).
@Suite struct OutdatedHelperTests {
  private func controller(_ system: FakeServiceSystem, home: URL) throws -> ServiceController {
    let controller = ServiceController(
      configuration: try configuration(home: home), system: system, home: home)
    try RegisteredAgent(configuration: controller.configuration).save()
    return controller
  }

  @Test func aHelperThatStoppedAnsweringOnTheOldBinaryIsRestarted() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let system = FakeServiceSystem()
    await system.startRunning()
    await system.set {
      $0.answering = false
      $0.outdated = true
    }
    let controller = try controller(system, home: home)
    let state = await controller.inspect()
    #expect(state == .unresponsive)
    #expect(await controller.outdated(state) == .binary)

    // The new helper does not answer either, so the wait for it runs out,
    // but the restart was made.
    _ = try? await controller.restartIfOutdated()
    #expect(await system.commands == [.kickstart(label: controller.configuration.label, restart: true)])
  }

  @Test func aStoppedHelperIsNeverOutdated() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let system = FakeServiceSystem()
    await system.set {
      $0.agent = .enabled
      $0.outdated = true
    }
    let controller = try controller(system, home: home)
    #expect(await controller.inspect() == .stopped)
    #expect(await controller.outdated(.stopped) == nil)
  }

  @Test func aFailingHelperUnderAnOldPlistIsRegisteredAgain() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let system = FakeServiceSystem()
    await system.startRunning()
    await system.set { $0.launchFailure = (exitCode: 1, logged: "bad plist") }
    let controller = ServiceController(
      configuration: try configuration(home: home), system: system, home: home)
    let state = await controller.inspect()
    #expect(state == .failing("bad plist"))
    #expect(await controller.outdated(state) == .definition)

    try RegisteredAgent(configuration: controller.configuration).save()
    #expect(await controller.outdated(state) == nil, "each launch already runs the new binary")
  }
}

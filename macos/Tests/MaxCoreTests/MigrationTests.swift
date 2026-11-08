import Foundation
import IMessageMaxContract
import MaxTestSupport
import Testing

@testable import MaxCore

private func legacyInstall(in home: URL, extra: Bool = false) throws -> LegacyInstall {
  let legacy = LegacyInstall(home: home)
  let fm = FileManager.default
  try fm.createDirectory(
    at: legacy.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
  try fm.createDirectory(
    at: legacy.helper.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("plist".utf8).write(to: legacy.plist)
  try Data("helper".utf8).write(to: legacy.helper)
  if extra {
    try Data("keep".utf8).write(
      to: legacy.helper.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("token"))
  }
  return legacy
}

@Test func migrationReplacesTheOldInstallAndARerunChangesNothing() async throws {
  let home = try temporaryHome()
  let legacy = try legacyInstall(in: home)
  let system = FakeServiceSystem()
  await system.set { $0.legacyLoaded = true }
  let controller = ServiceController(
    configuration: try configuration(home: home), system: system, home: home)
  #expect(await controller.inspect() == .legacyInstall)

  let first = try await controller.migrate()
  #expect(first.diagnosis != nil)
  let fm = FileManager.default
  #expect(!fm.fileExists(atPath: legacy.plist.path))
  #expect(!fm.fileExists(atPath: legacy.helper.path))
  // The old helper's folder is gone; the record of the registration is new.
  #expect(
    try fm.contentsOfDirectory(
      atPath: home.appendingPathComponent("Library/Application Support/iMessage Max").path)
      == [ServiceDefaults.registeredAgentFileName])
  #expect(fm.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents").path))
  let afterFirst = await system.commands
  #expect(
    afterFirst == [
      .bootout(label: LegacyInstall.label),
      .register(plistName: "\(ServiceDefaults.launchdLabel).plist"),
    ])

  await #expect(throws: CoreError.notReady(first)) { try await controller.migrate() }
  #expect(await system.commands == afterFirst, "a second run sends no command")
}

@Test func migrationFinishesAfterAnInterruptedRun() async throws {
  let home = try temporaryHome()
  _ = try legacyInstall(in: home)
  let system = FakeServiceSystem()
  await system.set {
    $0.legacyLoaded = true
    $0.failNextRegister = true
  }
  let controller = ServiceController(
    configuration: try configuration(home: home), system: system, home: home)
  await #expect(throws: CoreError.self) { try await controller.migrate() }
  #expect(await controller.inspect() == .notRegistered)
  await #expect(throws: CoreError.notReady(.notRegistered)) { try await controller.migrate() }
  #expect(try await controller.perform(.start).diagnosis != nil)
}

@Test func anOldListenerThatOutlivesTheBootoutKeepsTheOldInstall() async throws {
  let home = try temporaryHome()
  let legacy = try legacyInstall(in: home)
  let system = FakeServiceSystem()
  await system.set {
    $0.legacyLoaded = true
    $0.foreign = [99]
  }
  let controller = ServiceController(
    configuration: try configuration(home: home), system: system, home: home)
  await #expect(throws: CoreError.conflict) { try await controller.migrate() }
  #expect(FileManager.default.fileExists(atPath: legacy.plist.path))
  #expect(FileManager.default.fileExists(atPath: legacy.helper.path))
  #expect(await system.commands == [.bootout(label: LegacyInstall.label)], "nothing registers")
}

@Test func migratingWithoutAnOldInstallChangesNothing() async throws {
  let home = try temporaryHome()
  let system = FakeServiceSystem()
  await system.startRunning()
  let controller = ServiceController(
    configuration: try configuration(home: home), system: system, home: home)
  let state = await controller.inspect()
  #expect(state.diagnosis != nil)
  await #expect(throws: CoreError.notReady(state)) { try await controller.migrate() }
  #expect(await system.commands.isEmpty)
}

@Test func migrationKeepsFilesItDidNotInstall() async throws {
  let home = try temporaryHome()
  let legacy = try legacyInstall(in: home, extra: true)
  let controller = ServiceController(
    configuration: try configuration(home: home), system: FakeServiceSystem(), home: home)
  #expect(await controller.inspect() == .legacyInstall)
  _ = try await controller.migrate()
  #expect(!FileManager.default.fileExists(atPath: legacy.helper.path))
  #expect(
    FileManager.default.fileExists(
      atPath: home.appendingPathComponent("Library/Application Support/iMessage Max/token").path))
}

@Test func aTestBuildNeverTouchesTheOldInstall() async throws {
  let home = try temporaryHome()
  let legacy = try legacyInstall(in: home)
  let system = FakeServiceSystem()
  await system.set { $0.legacyLoaded = true }
  let controller = ServiceController(
    configuration: try configuration(
      label: "com.cyberpapiii.imessage-max.p3test.helper",
      bundleID: "com.cyberpapiii.imessage-max.p3test", port: 18383, home: home),
    system: system, home: home)
  #expect(await controller.inspect() == .notRegistered)
  await #expect(throws: CoreError.self) { try await controller.migrate() }
  #expect(await system.commands.isEmpty)
  #expect(FileManager.default.fileExists(atPath: legacy.plist.path))
  #expect(FileManager.default.fileExists(atPath: legacy.helper.path))
}

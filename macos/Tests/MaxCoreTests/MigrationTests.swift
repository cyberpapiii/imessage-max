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
  #expect(
    !fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/iMessage Max").path))
  #expect(fm.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents").path))
  let afterFirst = await system.commands
  #expect(
    afterFirst == [
      .bootout(label: LegacyInstall.label),
      .register(plistName: "\(ServiceDefaults.launchdLabel).plist"),
    ])

  let second = try await controller.migrate()
  #expect(second == first)
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
  #expect(try await controller.migrate().diagnosis != nil)
}

@Test func migrationKeepsFilesItDidNotInstall() async throws {
  let home = try temporaryHome()
  let legacy = try legacyInstall(in: home, extra: true)
  let controller = ServiceController(
    configuration: try configuration(home: home), system: FakeServiceSystem(), home: home)
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

@Test func movingTheAppReplacesAnOlderCopy() throws {
  let root = try temporaryHome()
  let source = root.appendingPathComponent("Downloads/iMessage Max.app")
  let applications = root.appendingPathComponent("Applications")
  try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
  try Data("new".utf8).write(to: source.appendingPathComponent("version"))
  let old = applications.appendingPathComponent("iMessage Max.app")
  try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
  try Data("old".utf8).write(to: old.appendingPathComponent("stale"))

  let target = try AppMover.install(source, into: applications)
  #expect(target.path == old.path)
  #expect(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "new")
  #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("stale").path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["iMessage Max.app"])
}

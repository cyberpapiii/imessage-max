import Foundation
import IMessageMaxContract
import Testing

@testable import MaxCore

@Suite struct KeepRunningSettingTests {
  private let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("keep-running-\(UUID().uuidString)")

  private func configuration(_ extra: [String] = []) throws -> ServiceConfiguration {
    let plist = try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": ServiceDefaults.launchdLabel, "BundleProgram": ServiceDefaults.helperBundlePath,
        "AssociatedBundleIdentifiers": [ServiceDefaults.companionBundleID],
        "ProgramArguments": [ServiceDefaults.executableName, "--http"] + extra,
      ], format: .xml, options: 0)
    return try ServiceConfiguration(
      plist: plist, plistName: "\(ServiceDefaults.launchdLabel).plist",
      bundleIdentifier: ServiceDefaults.companionBundleID,
      bundleURL: URL(fileURLWithPath: "/Applications/iMessage Max.app"), home: home)
  }

  @Test func theFileSitsBesideTheTokenTheHelperReads() throws {
    let standard = KeepRunningSetting(configuration: try configuration())
    #expect(
      standard.marker
        == home.appendingPathComponent(ServiceDefaults.tokenPath).deletingLastPathComponent()
        .appendingPathComponent(ServiceDefaults.stayStoppedFileName))

    let variant = KeepRunningSetting(
      configuration: try configuration(["--token-file", "/tmp/imax-test/token"]))
    #expect(variant.marker.path == "/tmp/imax-test/\(ServiceDefaults.stayStoppedFileName)")
  }

  @Test func onByDefaultAndOffOnlyWhileTheFileExists() throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let setting = KeepRunningSetting(configuration: try configuration())
    #expect(setting.isOn)

    // The helper has not made its folder yet: turning off makes it 0700.
    try setting.set(false)
    #expect(!setting.isOn)
    let folder = try FileManager.default.attributesOfItem(
      atPath: setting.marker.deletingLastPathComponent().path)
    #expect((folder[.posixPermissions] as? Int) == 0o700)
    let file = try FileManager.default.attributesOfItem(atPath: setting.marker.path)
    #expect((file[.posixPermissions] as? Int) == 0o600)

    try setting.set(false)
    #expect(!setting.isOn)
    try setting.set(true)
    #expect(setting.isOn)
    #expect(!FileManager.default.fileExists(atPath: setting.marker.path))
    try setting.set(true)
    #expect(setting.isOn)
  }

  @Test func keepAwakeIsOffByDefaultAndOnOnlyWhileItsFileExists() throws {
    defer { try? FileManager.default.removeItem(at: home) }
    let config = try configuration()
    let setting = KeepAwakeSetting(configuration: config)
    #expect(
      setting.marker
        == KeepRunningSetting(configuration: config).marker.deletingLastPathComponent()
        .appendingPathComponent(ServiceDefaults.keepAwakeFileName))
    #expect(!setting.isOn)

    try setting.set(true)
    #expect(setting.isOn)
    let folder = try FileManager.default.attributesOfItem(
      atPath: setting.marker.deletingLastPathComponent().path)
    #expect((folder[.posixPermissions] as? Int) == 0o700)
    let file = try FileManager.default.attributesOfItem(atPath: setting.marker.path)
    #expect((file[.posixPermissions] as? Int) == 0o600)
    // The two settings are separate files.
    #expect(KeepRunningSetting(configuration: config).isOn)

    try setting.set(true)
    try setting.set(false)
    #expect(!setting.isOn)
    try setting.set(false)
    #expect(!FileManager.default.fileExists(atPath: setting.marker.path))
  }
}

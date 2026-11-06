import XCTest
@testable import iMessageMax

final class VersionConsistencyTests: XCTestCase {
    func testAllVersionSitesMatchVersionCurrent() throws {
        let root = try findRepoRoot(from: URL(fileURLWithPath: #filePath))
        let expected = Version.current

        let plist = try plistObject(at: root.appendingPathComponent("swift/Sources/Resources/Info.plist"))
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, expected, "Info.plist CFBundleShortVersionString")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, expected, "Info.plist CFBundleVersion")

        let manifest = try jsonObject(at: root.appendingPathComponent("mcpb/manifest.json"))
        XCTAssertEqual(manifest["version"] as? String, expected, "mcpb/manifest.json version")

        let plugin = try jsonObject(at: root.appendingPathComponent(".codex-plugin/plugin.json"))
        XCTAssertEqual(plugin["version"] as? String, expected, ".codex-plugin/plugin.json version")

        let formula = try String(contentsOf: root.appendingPathComponent("swift/Formula/imessage-max.rb"), encoding: .utf8)
        XCTAssertTrue(formula.contains("version \"\(expected)\""), "Formula version")
        XCTAssertTrue(formula.contains("/releases/download/v\(expected)/"), "Formula url tag segment")
    }
}

private func plistObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try XCTUnwrap(object as? [String: Any])
}

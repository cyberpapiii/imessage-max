import XCTest

final class LaunchdSafetyTests: XCTestCase {
    /// Task.sleep aborts intermittently inside the launchd-run service
    /// (see AGENTS.md "No Task.sleep in the service runtime"). Use
    /// AsyncTimeout.sleep or the Dispatch-timer pattern instead.
    func testNoTaskSleepInServiceSources() throws {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()               // iMessageMaxTests
            .deletingLastPathComponent()               // Tests
        let sourcesDir = testsDir.deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sourcesDir.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "Expected a Sources directory at \(sourcesDir.path)"
        )
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)
        )
        var scannedFiles = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scannedFiles += 1
            let content = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in content.components(separatedBy: "\n").enumerated()
            where line.contains("Task.sleep(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertGreaterThan(scannedFiles, 0, "Scanned no Swift sources under \(sourcesDir.path)")
        XCTAssertEqual(offenders, [], "Task.sleep is forbidden in the service runtime; use AsyncTimeout.sleep. Found: \(offenders)")
    }
}

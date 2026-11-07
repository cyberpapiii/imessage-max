import XCTest

final class LaunchdSafetyTests: XCTestCase {
    func testNoTaskSleepInServiceSources() throws {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
        // ServiceGroup enforces these two durations by sleeping a Swift task,
        // and that sleep aborted every release-build SIGTERM (#27).
        let forbidden = ["Task.sleep(", ".maximumGracefulShutdownDuration =", ".maximumCancellationDuration ="]
        var scannedFiles = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scannedFiles += 1
            let content = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in content.components(separatedBy: "\n").enumerated()
            where forbidden.contains(where: line.contains) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertGreaterThan(scannedFiles, 0, "Scanned no Swift sources under \(sourcesDir.path)")
        XCTAssertEqual(offenders, [], "Task.sleep is forbidden in the service runtime, directly or through ServiceGroup's shutdown durations; use AsyncTimeout.sleep or a DispatchSourceTimer. Found: \(offenders)")
    }
}

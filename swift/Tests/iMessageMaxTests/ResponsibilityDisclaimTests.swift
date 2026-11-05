import Darwin
import XCTest
@testable import iMessageMax

/// `--request-contacts-access` must be attributed to imessage-max itself, not
/// to the terminal it was typed into: macOS records a TCC grant against the
/// *responsible* process, and an MCP client like Claude desktop launches the
/// server disclaimed, so a grant that landed on Terminal is invisible to it.
/// These tests read the kernel's responsibility record for a real child.
final class ResponsibilityDisclaimTests: XCTestCase {
    private func responsiblePID(ofChildSpawnedWith disclaim: Bool) throws -> (child: pid_t, responsible: pid_t) {
        let child = try ResponsibilityDisclaim.spawn(
            path: "/bin/sleep", arguments: ["5"], disclaim: disclaim
        )
        defer {
            kill(child, SIGKILL)
            _ = ResponsibilityDisclaim.wait(child)
        }
        let responsible = try XCTUnwrap(ResponsibilityDisclaim.responsiblePID(for: child))
        return (child, responsible)
    }

    func testDisclaimedChildIsResponsibleForItself() throws {
        let (child, responsible) = try responsiblePID(ofChildSpawnedWith: true)
        XCTAssertEqual(responsible, child)
    }

    func testUndisclaimedChildInheritsTheParentsResponsibleProcess() throws {
        let (child, responsible) = try responsiblePID(ofChildSpawnedWith: false)
        XCTAssertNotEqual(responsible, child)
    }

    func testWaitReportsTheChildsExitStatus() throws {
        let child = try ResponsibilityDisclaim.spawn(
            path: "/bin/sh", arguments: ["-c", "exit 3"], disclaim: true
        )
        XCTAssertEqual(ResponsibilityDisclaim.wait(child), 3)
    }
}

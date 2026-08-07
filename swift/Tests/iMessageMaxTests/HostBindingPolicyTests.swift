import XCTest
@testable import iMessageMax

final class HostBindingPolicyTests: XCTestCase {

    func testLoopbackHostsAllowedWithoutFlag() {
        let loopbackHosts = ["127.0.0.1", "::1", "localhost", "LOCALHOST"]
        for host in loopbackHosts {
            XCTAssertNil(
                HostBindingPolicy.validationError(host: host, allowExternalBind: false),
                "Expected nil error for loopback host '\(host)'"
            )
        }
    }

    func testExternalHostRejectedWithoutFlag() {
        let externalHosts = ["0.0.0.0", "192.168.1.10", "example.com"]
        for host in externalHosts {
            let error = HostBindingPolicy.validationError(host: host, allowExternalBind: false)
            XCTAssertNotNil(error, "Expected validation error for external host '\(host)'")
            XCTAssertTrue(
                error?.contains("--allow-external-bind") == true,
                "Error for '\(host)' should mention --allow-external-bind, got: \(error ?? "nil")"
            )
        }
    }

    func testExternalHostAllowedWithFlag() {
        let externalHosts = ["0.0.0.0", "192.168.1.10", "example.com"]
        for host in externalHosts {
            XCTAssertNil(
                HostBindingPolicy.validationError(host: host, allowExternalBind: true),
                "Expected nil error for external host '\(host)' when --allow-external-bind is set"
            )
        }
    }
}

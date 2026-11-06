import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import IMessageMaxContract
@testable import iMessageMax

final class SetupPermissionTests: XCTestCase {
    func testSetupRequiresExplicitNativeRequest() async throws {
        let transport = setupTestTransport()
        let app = await transport.application()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(uri: "/setup/permissions", method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "{\"permission\":\"automation\"}"))
            XCTAssertEqual(response.head.status, .forbidden)
        }
    }

    func testSetupRejectsBrowserOriginEvenOnLoopback() async throws {
        let transport = setupTestTransport()
        let app = await transport.application()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(uri: "/setup/permissions", method: .post,
                headers: [.contentType: "application/json", HTTPField.Name("Origin")!: "http://localhost:8080",
                          HTTPField.Name("X-iMessage-Max-Setup")!: "permission-request-v1"],
                body: ByteBuffer(string: "{\"permission\":\"automation\"}"))
            XCTAssertEqual(response.head.status, .forbidden)
        }
    }

    func testMissingTargetIsNotMissingConsent() {
        XCTAssertEqual(AutomationPermission.status(for: -600).status, "messages_not_running")
        XCTAssertEqual(AutomationPermission.status(for: -1744).status, "not_determined")
        XCTAssertEqual(AutomationPermission.status(for: -1743).status, "denied")
        XCTAssertEqual(AutomationPermission.status(for: -1).status, "check_failed_-1")
    }

    func testNativeRequestReturnsActualServiceIdentity() async throws {
        let app = await setupTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(uri: "/setup/permissions", method: .post,
                headers: setupHeaders(), body: ByteBuffer(string: "{\"permission\":\"automation\"}"))
            XCTAssertEqual(response.head.status, .ok)
            let result = try JSONDecoder().decode(SetupPermissionReply.self, from: Data(response.body.readableBytesView))
            XCTAssertEqual(result.processID, getpid())
            XCTAssertEqual(result.permission, .automation)
            XCTAssertTrue(result.authorized)
        }
    }

    func testNativeRequestRejectsUnknownPermissionAndExtraKeys() async throws {
        let app = await setupTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            for json in ["{\"permission\":\"full_disk\"}", "{\"permission\":\"contacts\",\"extra\":\"x\"}", "[]"] {
                let response = try await client.executeRequest(uri: "/setup/permissions", method: .post,
                    headers: setupHeaders(), body: ByteBuffer(string: json))
                XCTAssertEqual(response.head.status, .badRequest)
            }
        }
    }

    func testSetupReplyCarriesTheResolverWord() async throws {
        let service = SetupPermissionService(
            resolver: ContactResolver(seedCache: [:], authorization: (false, .denied))
        )
        let reply = try await service.request(.contacts)
        XCTAssertEqual(reply.status, .denied)
        XCTAssertFalse(reply.authorized)
    }

    func testNoSetupOnExternalListener() async throws {
        let app = await setupTestTransport(host: "0.0.0.0").application()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(uri: "/setup/permissions", method: .post,
                headers: setupHeaders(), body: ByteBuffer(string: "{\"permission\":\"automation\"}"))
            XCTAssertEqual(response.head.status, .notFound)
        }
    }

    func testNativeRequestRejectsOversizedBody() async throws {
        let app = await setupTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(uri: "/setup/permissions", method: .post,
                headers: setupHeaders(), body: ByteBuffer(string: String(repeating: "x", count: 300)))
            XCTAssertEqual(response.head.status, .contentTooLarge)
        }
    }
}

private func setupHeaders() -> HTTPFields {
    [.contentType: "application/json", HTTPField.Name("X-iMessage-Max-Setup")!: "permission-request-v1"]
}

private func setupTestTransport(host: String = "127.0.0.1") -> HTTPTransport {
    HTTPTransport(host: host, catalog: makeTestCatalog(),
        setupPermissions: SetupPermissionService(contactsRequest: { (true, "authorized") }, automationRequest: { (true, "authorized") }))
}

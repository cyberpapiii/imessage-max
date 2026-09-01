import MCP
import XCTest
@testable import iMessageMax

/// The tool catalog is process-wide but used to be re-registered by every new
/// session, which bumped the registry's catalog version twelve times per
/// `initialize` and invalidated the modern lane's encoded-catalog cache.
final class ToolRegistryBindingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ToolHandlerRegistry.shared.resetForTesting()
    }

    override func tearDown() {
        ToolHandlerRegistry.shared.resetForTesting()
        super.tearDown()
    }

    private func makeServer() -> Server {
        Server(
            name: Version.name,
            version: Version.current,
            title: Version.title,
            instructions: Version.instructions,
            capabilities: Version.serverCapabilities
        )
    }

    func testSecondRegistrationWithTheSameDependenciesChangesNothing() async {
        let db = Database()
        let resolver = ContactResolver(seedCache: [:])

        await ToolRegistry.registerAll(on: makeServer(), db: db, resolver: resolver)
        let afterFirst = ToolHandlerRegistry.shared.catalogVersion
        let toolsAfterFirst = ToolHandlerRegistry.shared.getTools().map(\.name)

        await ToolRegistry.registerAll(on: makeServer(), db: db, resolver: resolver)

        XCTAssertEqual(
            ToolHandlerRegistry.shared.catalogVersion, afterFirst,
            "re-registering the same catalog must not bump the version"
        )
        XCTAssertEqual(ToolHandlerRegistry.shared.getTools().map(\.name), toolsAfterFirst)
    }

    func testDifferentDependenciesRebindTheCatalog() async {
        let db = Database()
        await ToolRegistry.registerAll(
            on: makeServer(), db: db, resolver: ContactResolver(seedCache: [:])
        )
        let afterFirst = ToolHandlerRegistry.shared.catalogVersion

        // A fresh resolver is a different binding, so the handlers have to be
        // replaced or they would keep answering from the previous one.
        await ToolRegistry.registerAll(
            on: makeServer(), db: db, resolver: ContactResolver(seedCache: [:])
        )

        XCTAssertGreaterThan(ToolHandlerRegistry.shared.catalogVersion, afterFirst)
        XCTAssertEqual(ToolHandlerRegistry.shared.getTools().count, 12)
    }
}

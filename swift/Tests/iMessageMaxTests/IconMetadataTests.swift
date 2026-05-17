import XCTest
@testable import iMessageMax

final class IconMetadataTests: XCTestCase {
    func testInjectServerIconsAddsIconForLatestProtocolInitializeResponse() throws {
        let response = Data("""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","serverInfo":{"name":"imessage-max","title":"iMessage Max"},"capabilities":{}}}
        """.utf8)

        let injected = IconMetadata.injectServerIcons(into: response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: injected) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        let icons = try XCTUnwrap(serverInfo["icons"] as? [[String: Any]])

        XCTAssertEqual(icons.compactMap { ($0["sizes"] as? [String])?.first }, ["64x64", "32x32", "16x16"])
        for icon in icons {
            XCTAssertEqual(icon["mimeType"] as? String, "image/png")
            XCTAssertTrue((icon["src"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        }
    }

    func testEmbeddedIconsArePNGsMatchingDeclaredSizes() throws {
        let icons = try XCTUnwrap(IconMetadata.icons)
        XCTAssertEqual(icons.map { $0.sizes?.first }, ["64x64", "32x32", "16x16"])

        for icon in icons {
            XCTAssertEqual(icon.mimeType, "image/png")
            let declaredSize = try XCTUnwrap(icon.sizes?.first)
            let dimensions = declaredSize.split(separator: "x")
            XCTAssertEqual(dimensions.count, 2)
            let expectedWidth = try XCTUnwrap(Int(dimensions[0]))
            let expectedHeight = try XCTUnwrap(Int(dimensions[1]))
            let imageData = try decodePNGDataURI(icon.src)
            let size = try pngSize(imageData)

            XCTAssertEqual(size.width, expectedWidth)
            XCTAssertEqual(size.height, expectedHeight)
        }
    }

    func testToolIconUsesCompactPNG() throws {
        let icon = try XCTUnwrap(IconMetadata.toolIcons?.first)
        XCTAssertEqual(icon.mimeType, "image/png")
        XCTAssertEqual(icon.sizes, ["16x16"])

        let imageData = try decodePNGDataURI(icon.src)
        let size = try pngSize(imageData)

        XCTAssertEqual(size.width, 16)
        XCTAssertEqual(size.height, 16)
    }

    func testCommittedIconAssetsArePNGAtExpectedSizes() throws {
        let root = try findRepoRoot(from: URL(fileURLWithPath: #filePath))
        let expectedAssets = [
            "icon.png": 512,
            "assets/icons/icon-16.png": 16,
            "assets/icons/icon-32.png": 32,
            "assets/icons/icon-64.png": 64,
            "assets/icons/icon-128.png": 128,
            "assets/icons/icon-256.png": 256,
            "assets/icons/icon-512.png": 512,
            "assets/codex/icon.png": 360,
            "assets/codex/logo.png": 512,
            "mcpb/assets/icon-16.png": 16,
            "mcpb/assets/icon-32.png": 32,
            "mcpb/assets/icon-64.png": 64,
            "mcpb/assets/icon-128.png": 128,
            "mcpb/assets/icon-256.png": 256,
            "mcpb/assets/icon-512.png": 512,
        ]

        for (path, expectedDimension) in expectedAssets {
            let iconURL = root.appendingPathComponent(path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: iconURL.path), "\(path) should exist")
            let data = try Data(contentsOf: iconURL)
            let size = try pngSize(data)

            XCTAssertEqual(size.width, expectedDimension, path)
            XCTAssertEqual(size.height, expectedDimension, path)
        }
    }

    func testCodexPluginManifestReferencesExistingPNGAssets() throws {
        let root = try findRepoRoot(from: URL(fileURLWithPath: #filePath))
        let manifestURL = root.appendingPathComponent(".codex-plugin/plugin.json")
        let manifest = try jsonObject(at: manifestURL)
        let interface = try XCTUnwrap(manifest["interface"] as? [String: Any])

        XCTAssertEqual(manifest["mcpServers"] as? String, "./.mcp.json")
        XCTAssertEqual(interface["composerIcon"] as? String, "./assets/codex/icon.png")
        XCTAssertEqual(interface["logo"] as? String, "./assets/codex/logo.png")

        for field in ["composerIcon", "logo"] {
            let relativePath = try XCTUnwrap(interface[field] as? String).replacingOccurrences(of: "./", with: "")
            let iconURL = root.appendingPathComponent(relativePath)
            let data = try Data(contentsOf: iconURL)
            _ = try pngSize(data)
        }

        let mcpConfig = try jsonObject(at: root.appendingPathComponent(".mcp.json"))
        let servers = try XCTUnwrap(mcpConfig["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["imessage-max"])
    }

    func testMCPBManifestReferencesExistingPNGAssets() throws {
        let root = try findRepoRoot(from: URL(fileURLWithPath: #filePath))
        let manifestURL = root.appendingPathComponent("mcpb/manifest.json")
        let manifest = try jsonObject(at: manifestURL)

        XCTAssertEqual(manifest["manifest_version"] as? String, "0.3")
        XCTAssertEqual(manifest["icon"] as? String, "assets/icon-128.png")

        let iconPath = try XCTUnwrap(manifest["icon"] as? String)
        let iconURL = root.appendingPathComponent("mcpb").appendingPathComponent(iconPath)
        let data = try Data(contentsOf: iconURL)
        let size = try pngSize(data)

        XCTAssertEqual(size.width, 128)
        XCTAssertEqual(size.height, 128)

        let icons = try XCTUnwrap(manifest["icons"] as? [[String: Any]])
        XCTAssertEqual(icons.compactMap { $0["size"] as? String }, ["16x16", "32x32", "64x64", "128x128", "256x256", "512x512"])
        for icon in icons {
            let relativePath = try XCTUnwrap(icon["src"] as? String)
            let iconURL = root.appendingPathComponent("mcpb").appendingPathComponent(relativePath)
            let data = try Data(contentsOf: iconURL)
            _ = try pngSize(data)
        }
    }

    func testInjectServerIconsSkipsLegacyProtocolInitializeResponse() {
        let response = Data("""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","serverInfo":{"name":"imessage-max","title":"iMessage Max"},"capabilities":{}}}
        """.utf8)

        let injected = IconMetadata.injectServerIcons(into: response)

        XCTAssertEqual(injected, response)
    }

    func testInjectServerIconsSkipsNonInitializeResponses() {
        let response = Data("""
        {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"send"}]}}
        """.utf8)

        let injected = IconMetadata.injectServerIcons(into: response)

        XCTAssertEqual(injected, response)
    }
}

private func decodePNGDataURI(_ src: String) throws -> Data {
    let prefix = "data:image/png;base64,"
    XCTAssertTrue(src.hasPrefix(prefix))
    return try XCTUnwrap(Data(base64Encoded: String(src.dropFirst(prefix.count))))
}

private func pngSize(_ data: Data) throws -> (width: Int, height: Int) {
    let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    XCTAssertGreaterThanOrEqual(data.count, 24)
    XCTAssertEqual(Array(data.prefix(8)), pngSignature)
    XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "IHDR")

    let width = data[16..<20].reduce(0) { ($0 << 8) | Int($1) }
    let height = data[20..<24].reduce(0) { ($0 << 8) | Int($1) }
    return (width, height)
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func findRepoRoot(from fileURL: URL) throws -> URL {
    var directory = fileURL.deletingLastPathComponent()
    while directory.path != "/" {
        let iconURL = directory.appendingPathComponent("icon.png")
        if FileManager.default.fileExists(atPath: iconURL.path) {
            return directory
        }
        directory.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

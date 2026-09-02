import Foundation
import XCTest
@testable import iMessageMax

final class AttachmentStagingSecurityTests: XCTestCase {
    func testAliasPrefixesNormalizeToPrivate() {
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/tmp/x.png"), "/private/tmp/x.png")
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/var/folders/a/b.png"), "/private/var/folders/a/b.png")
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/etc/hosts"), "/private/etc/hosts")
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/tmp"), "/private/tmp")
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/tmpfoo/x"), "/tmpfoo/x")       // prefix must be a whole component
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/private/tmp/x"), "/private/tmp/x") // idempotent
    }

    func testTildeAndDotSegmentsAreResolvedLexically() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(SecurePath.absoluteLexicalPath("~/Pictures/../Downloads/a.png"), home + "/Downloads/a.png")
    }

    func testRelativePathsAreNotAbsolutized() {
        XCTAssertNil(SecurePath.absoluteLexicalPath("Pictures/a.png"))
        XCTAssertNil(SecurePath.absoluteLexicalPath("./a.png"))
        XCTAssertNil(SecurePath.absoluteLexicalPath(""))
    }
}

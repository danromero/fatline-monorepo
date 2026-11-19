import XCTest
@testable import Fatline

/// Links to a post: the page's `fatline://open` button and the post's own address.
final class PostLinkTests: XCTestCase {
    private let postHash = "0x" + String(repeating: "ab", count: 20)

    func testThePagesButton() throws {
        let link = try XCTUnwrap(PostLink(URL(string: "fatline://open?network=37.fatline.tech&post=\(postHash)")!))
        XCTAssertEqual(link.host, "37.fatline.tech")
        XCTAssertEqual(link.hash, postHash)
    }

    func testThePostsOwnAddress() throws {
        let link = try XCTUnwrap(PostLink(URL(string: "https://37.fatline.tech/p/\(postHash)")!))
        XCTAssertEqual(link.host, "37.fatline.tech")
        XCTAssertEqual(link.hash, postHash)
        XCTAssertEqual(PostLink(URL(string: "https://Club.Example:8443/p/\(postHash.uppercased().replacingOccurrences(of: "0X", with: "0x"))")!)?.host, "club.example:8443")
    }

    func testAnEncodedAddressInTheButton() {
        XCTAssertEqual(PostLink(URL(string: "fatline://open?network=club.example%3A8443&post=\(postHash)")!)?.host, "club.example:8443")
    }

    func testAnythingElseIsntALink() {
        let bad = [
            "fatline://open?network=37.fatline.tech",
            "fatline://open?post=\(postHash)",
            "fatline://elsewhere?network=37.fatline.tech&post=\(postHash)",
            "fatline://open?network=37.fatline.tech&post=0x1234",
            "fatline://open?network=37.fatline.tech/evil&post=\(postHash)",
            "fatline://open?network=user@37.fatline.tech&post=\(postHash)",
            "https://37.fatline.tech/p/\(postHash)/more",
            "https://37.fatline.tech/q/\(postHash)",
            "https://37.fatline.tech/p/",
            "ftp://37.fatline.tech/p/\(postHash)",
            "https://37.fatline.tech/p/0x\(String(repeating: "zz", count: 20))",
        ]
        for text in bad { XCTAssertNil(PostLink(URL(string: text)!), text) }
    }

    func testPlainHTTPOnlyForThisMachine() {
        XCTAssertNil(PostLink(URL(string: "http://37.fatline.tech/p/\(postHash)")!))
        #if DEBUG
        XCTAssertEqual(PostLink(URL(string: "fatline://open?network=localhost:8787&post=\(postHash)")!)?.host, "localhost:8787")
        #endif
    }
}

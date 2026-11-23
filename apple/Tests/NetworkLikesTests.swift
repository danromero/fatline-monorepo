import CryptoKit
import os
import XCTest
@testable import Fatline

/// Likes in iPhone's Activity: what the app takes from a network, and how a like's row reads.
final class NetworkLikesTests: XCTestCase {
    private func post(_ hash: String, fid: Int = 3, time: Int = 100, text: String = "Garden cleanup Sunday at 9.",
                      parent: String? = nil, embeds: [String] = []) -> String {
        let parentJSON = parent.map { #""\#($0)""# } ?? "null"
        return #"{"hash":"\#(hash)","fid":\#(fid),"time":\#(time),"text":"\#(text)","mentions":[],"parent":\#(parentJSON),"embeds":[\#(embeds.joined(separator: ","))],"replies":0,"likes":2,"liked":false,"deleted":false}"#
    }

    private func like(_ hash: String, likers: String, count: Int, time: Int = 500, parent: String = "null") -> String {
        #"{"kind":"like","post":\#(post(hash)),"parent":\#(parent),"likers":\#(likers),"count":\#(count),"time":\#(time)}"#
    }

    /// A client whose network answers `items`, and the address it was asked.
    private func activity(_ items: [String], likes: Bool) async throws -> (items: [NetworkActivity.Item], asked: String?) {
        let asked = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let membership = NetworkMembership(host: "pine.example", fid: 3, key: Curve25519.Signing.PrivateKey().rawRepresentation, issued: 0,
                                           approval: "", status: .approved, token: "token-1", expires: .max)
        let client = NetworkClient(membership: membership, transport: { request in
            asked.withLock { $0 = request.url }
            return (Data(#"{"items":[\#(items.joined(separator: ","))],"next":null}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, answers: NetworkAnswers())
        let read = try await client.activity(likes: likes)
        return (read, asked.withLock { $0 }?.absoluteString)
    }

    func testALikeIsReadWithItsLikersCountAndTime() async throws {
        let reply = #"{"kind":"reply","post":\#(post("0xr", fid: 4, time: 400, parent: "0xa")),"parent":\#(post("0xa"))}"#
        let liked = like("0xa", likers: #"[{"fid":5,"username":"helen"},{"fid":6,"username":"theo"}]"#, count: 5)
        let read = try await activity([liked, reply], likes: true)
        XCTAssertEqual(read.asked, "https://pine.example/api/v1/activity?likes=1")
        XCTAssertEqual(read.items.map(\.id), ["like 0xa 500 5", "reply 0xr"], "a like's row is new with each new like")
        let item = try XCTUnwrap(read.items.first)
        XCTAssertTrue(item.isLike)
        XCTAssertEqual(item.likers, [.init(fid: 5, username: "helen"), .init(fid: 6, username: "theo")])
        XCTAssertEqual(item.count, 5)
        XCTAssertEqual(item.when, 500, "a like is placed by its newest like, not the post's time")
        XCTAssertEqual(read.items[1].when, 400)
        XCTAssertEqual(item.threadRoot.hash, "0xa")
    }

    func testALikePastWhatANetworkCanSendIsDroppedAndTheRestStay() async throws {
        let one = #"[{"fid":5,"username":"helen"}]"#
        let reply = #"{"kind":"reply","post":\#(post("0xr", fid: 4, parent: "0xa")),"parent":null}"#
        let read = try await activity([
            like("0x1", likers: one, count: 1),
            like("0x2", likers: #"[{"fid":5,"username":"a"},{"fid":6,"username":"b"},{"fid":7,"username":"c"},{"fid":8,"username":"d"}]"#, count: 4),
            like("0x3", likers: #"[{"fid":5,"username":"\#(String(repeating: "a", count: 65))"}]"#, count: 1),
            like("0x4", likers: "[]", count: 0),
            like("0x5", likers: #"[{"fid":5,"username":"helen"},{"fid":6,"username":"theo"}]"#, count: 1),
            like("0x6", likers: one, count: 20_000),
            like("0x7", likers: #"[{"fid":"five","username":"helen"}]"#, count: 1),
            #"{"kind":"like","post":\#(post("0x8")),"parent":null,"likers":\#(one),"count":1}"#,
            reply,
        ], likes: true)
        XCTAssertEqual(read.items.map(\.post.hash), ["0x1", "0xr"])
    }

    func testWithoutAskingThereAreNoLikes() async throws {
        let reply = #"{"kind":"reply","post":\#(post("0xr", fid: 4, parent: "0xa")),"parent":null}"#
        let read = try await activity([like("0xa", likers: #"[{"fid":5,"username":"helen"}]"#, count: 1), reply], likes: false)
        XCTAssertEqual(read.asked, "https://pine.example/api/v1/activity")
        XCTAssertEqual(read.items.map(\.post.hash), ["0xr"])
    }

    private func header(_ names: [String], count: Int, reply: Bool = false) -> String {
        NetworkLikeRow.header(names: names, count: count, reply: reply).map(\.text).joined()
    }

    func testTheHeaderNamesUpToThreeAndCountsTheRest() {
        XCTAssertEqual(header(["helen"], count: 1), "helen liked your post")
        XCTAssertEqual(header(["helen", "theo"], count: 2), "helen and theo liked your post")
        XCTAssertEqual(header(["helen", "theo", "sana"], count: 3), "helen, theo, and sana liked your post")
        XCTAssertEqual(header(["helen", "theo", "sana"], count: 4), "helen, theo, and 2 others liked your post")
        XCTAssertEqual(header(["helen", "theo", "sana"], count: 5), "helen, theo, and 3 others liked your post")
        // Fewer names than the count, which an honest network doesn't send, still reads.
        XCTAssertEqual(header(["helen", "theo"], count: 3), "helen, theo, and 1 other liked your post")
        XCTAssertEqual(header(["helen"], count: 2), "helen and 1 other liked your post")
    }

    func testTheHeaderSaysReplyForALikedReplyAndOnlyNamesAreBold() {
        XCTAssertEqual(header(["theo"], count: 1, reply: true), "theo liked your reply")
        XCTAssertEqual(header(["helen", "theo", "sana"], count: 5, reply: true), "helen, theo, and 3 others liked your reply")
        let pieces = NetworkLikeRow.header(names: ["helen", "theo", "sana"], count: 5, reply: false)
        XCTAssertEqual(pieces.filter(\.isName).map(\.text), ["helen", "theo"])
    }

    private func decoded(_ json: String) throws -> NetworkPost {
        try JSONDecoder().decode(NetworkPost.self, from: Data(json.utf8))
    }

    func testTheSummaryIsThePostsTextOrWhatItHas() throws {
        XCTAssertEqual(NetworkLikeRow.summary(of: try decoded(post("0x1", text: #"Garden cleanup\n\nSunday  at 9. "#))),
                       "Garden cleanup Sunday at 9.")
        XCTAssertEqual(NetworkLikeRow.summary(of: try decoded(post("0x2", text: "", embeds: [#"{"type":"link","url":"https://www.example.com/rakes"}"#]))),
                       "example.com/rakes")
        let picture = #"{"type":"image","width":4,"height":3,"src":"https://pine.example/media/a"}"#
        XCTAssertEqual(NetworkLikeRow.summary(of: try decoded(post("0x3", text: "", embeds: [picture]))), "Picture")
        XCTAssertEqual(NetworkLikeRow.summary(of: try decoded(post("0x4", text: "", embeds: [picture, picture]))), "2 pictures")
        XCTAssertEqual(NetworkLikeRow.summary(of: try decoded(post("0x5", text: ""))), "Post")
        XCTAssertEqual(NetworkLikeRow.summary(of: try decoded(post("0x6", text: "", parent: "0xa"))), "Reply")
    }
}

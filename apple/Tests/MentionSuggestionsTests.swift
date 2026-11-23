import XCTest
@testable import Fatline

/// Typing @ in a network's composer suggests its members.
final class MentionSuggestionsTests: XCTestCase {
    private func member(_ fid: UInt64, _ username: String, _ name: String = "", muted: Bool = false) -> NetworkMember {
        NetworkMember(fid: fid, username: username, displayName: name, bio: "", role: "member", joined: 0, muted: muted)
    }

    private func query(_ text: String) -> String? {
        MentionSuggestions.query(in: text, caret: text.endIndex)?.name
    }

    func testAnAtStartingAWordIsAQuery() {
        XCTAssertEqual(query("@"), "")
        XCTAssertEqual(query("Thanks @sa"), "sa")
        XCTAssertEqual(query("(@dwr.eth"), "dwr.eth")
        XCTAssertEqual(query("line one\n@al"), "al")
    }

    func testNoQueryOutsideAnAtName() {
        XCTAssertNil(query(""))
        XCTAssertNil(query("hello"))
        XCTAssertNil(query("mail me at sam@example"))
        XCTAssertNil(query("@sana "))
        XCTAssertNil(query("@sa!"))
    }

    func testTheCaretDecides() {
        let text = "@sa and more"
        let caret = text.index(text.startIndex, offsetBy: 3)
        XCTAssertEqual(MentionSuggestions.query(in: text, caret: caret)?.name, "sa")
        XCTAssertNil(MentionSuggestions.query(in: text, caret: text.endIndex))
    }

    func testCompletingPutsInTheUsernameAndASpace() throws {
        let text = "Thanks @sa for the ladder"
        let caret = text.index(text.startIndex, offsetBy: 10)
        let found = try XCTUnwrap(MentionSuggestions.query(in: text, caret: caret))
        let done = MentionSuggestions.complete(text, range: found.range, with: "sana")
        XCTAssertEqual(done.text, "Thanks @sana  for the ladder")
        XCTAssertEqual(done.text[..<done.caret], "Thanks @sana ")
    }

    func testMatchesUsernamesAndNamesButNotYouOrMuted() {
        let members = [member(1, "dwr", "Dan"), member(2, "sana", "Sana Okafor"), member(3, "sam", "Sam Reyes"),
                       member(4, "olive", "Oli Sanchez"), member(5, "salt", muted: true)]
        let names = { (typed: String) in
            MentionSuggestions.members(matching: typed, in: members, you: 1, talkedWith: [:]).map(\.username)
        }
        XCTAssertEqual(names("sa"), ["olive", "sam", "sana"])
        XCTAssertEqual(names("SAN"), ["olive", "sana"])
        XCTAssertEqual(names("okaf"), ["sana"])
        XCTAssertEqual(names("d"), [])
        XCTAssertEqual(names("").count, MentionSuggestions.limit)
    }

    func testPeopleYouTalkedWithComeFirst() {
        let members = [member(2, "amy"), member(3, "bea"), member(4, "cal"), member(5, "dee")]
        let order = MentionSuggestions.members(matching: "", in: members, you: 1, talkedWith: [4: 20, 3: 10]).map(\.username)
        XCTAssertEqual(order, ["cal", "bea", "amy"])
    }

    func testTalkedWithCountsRepliesAndMentionsBothWays() {
        func post(_ fid: UInt64, _ time: Int64, parentFid: UInt64? = nil, mentions: [UInt64] = []) -> NetworkPost {
            NetworkPost(hash: "0x\(time)", fid: fid, time: time, text: "", mentions: mentions.map { .init(fid: $0, username: "u\($0)") },
                        parent: parentFid.map { _ in "0xp" }, parentFid: parentFid, embeds: [],
                        replies: 0, likes: 0, liked: false, deleted: false)
        }
        let talked = MentionSuggestions.talkedWith(in: [
            post(2, 5, parentFid: 1),   // 2 replied to you
            post(1, 7, parentFid: 3),   // you replied to 3
            post(1, 9, mentions: [4]),  // you mentioned 4
            post(5, 11, mentions: [1]), // 5 mentioned you
            post(6, 13, parentFid: 7),  // nothing to do with you
            post(2, 15, parentFid: 1),  // 2 again, later
        ], you: 1)
        XCTAssertEqual(talked, [2: 15, 3: 7, 4: 9, 5: 11])
    }
}

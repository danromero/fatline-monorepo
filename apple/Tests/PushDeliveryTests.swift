import CryptoKit
import XCTest
@testable import Fatline

/// What the notification extension shows and where a tap goes: the network's saved name and the
/// app's words, the fallback for anything that doesn't open, and the plan's table for taps.
final class PushDeliveryTests: XCTestCase {
    private let key = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
    private let root = "0x" + String(repeating: "a", count: 40)
    private let reply = "0x" + String(repeating: "b", count: 40)

    private var target: PushTarget {
        PushTarget(host: "pine.example", name: "Pine Street", relay: "https://push.fatline.tech",
                   handle: PushHandle(handle: String(repeating: "h", count: 22), secret: String(repeating: "s", count: 43)),
                   key: key.withUnsafeBytes { Data($0) }, choices: PushChoices())
    }

    /// Seals as the network does.
    private func seal(_ fields: String, key: SymmetricKey? = nil) throws -> String {
        let box = try AES.GCM.seal(Data("{\"v\":1,\(fields)}".utf8), using: key ?? self.key)
        return try XCTUnwrap(box.combined).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func deliver(_ fields: String, handle: String? = nil, key: SymmetricKey? = nil) throws -> PushDelivery {
        let info: [AnyHashable: Any] = ["aps": ["alert": ["title": "Fatline"]], "h": handle ?? target.handle.handle,
                                        "s": try seal(fields, key: key)]
        return PushDelivery.make(userInfo: info, targets: [target])
    }

    func testAReplyShowsTheSavedNameAndTheAppsWords() throws {
        let delivery = try deliver(#""kind":"reply","fid":4,"username":"helen","text":"Count me in","post":"\#(reply)","thread":"\#(root)""#)
        XCTAssertEqual(delivery.title, "Pine Street")
        XCTAssertEqual(delivery.body, "@helen replied: Count me in")
        XCTAssertEqual(delivery.thread, "pine.example", "Stacked by network")
        XCTAssertTrue(delivery.countsOnBadge)
        XCTAssertEqual(delivery.tap?.target, .thread(root, lit: reply), "The post, with the reply lit")
    }

    func testAnHoursPostsAreOneLineAndOpenTheFeed() throws {
        let delivery = try deliver(#""kind":"post","fid":4,"username":"mika","text":"Hike?","post":"\#(root)","thread":"\#(root)","count":3,"usernames":["mika","sana","dave"]"#)
        XCTAssertEqual(delivery.body, "3 new posts from mika, sana, and dave")
        XCTAssertFalse(delivery.countsOnBadge, "New posts aren't on the badge")
        XCTAssertEqual(delivery.tap?.target, .feed)
    }

    func testOneNewPostOpensThePost() throws {
        let delivery = try deliver(#""kind":"post","fid":4,"username":"mika","text":"Hike?","post":"\#(root)","thread":"\#(root)""#)
        XCTAssertEqual(delivery.tap?.target, .thread(root, lit: nil))
    }

    func testEachOtherKindGoesWhereThePlanSays() throws {
        XCTAssertEqual(try deliver(#""kind":"mention","fid":4,"username":"sana","text":"hi","post":"\#(root)","thread":"\#(root)""#).tap?.target,
                       .thread(root, lit: nil), "A mention in a post: the post")
        XCTAssertEqual(try deliver(#""kind":"mention","fid":4,"username":"sana","text":"hi","post":"\#(reply)","thread":"\#(root)""#).tap?.target,
                       .thread(root, lit: reply), "A mention in a reply: the post, with the reply lit")
        XCTAssertEqual(try deliver(#""kind":"reply","fid":4,"username":"helen","text":"hi","post":null,"thread":null"#).tap?.target,
                       .activity, "A reply with no post: Activity")
        XCTAssertEqual(try deliver(#""kind":"approved","fid":3,"username":"dwr","text":"","pictures":0"#).tap?.target, .feed)
        XCTAssertEqual(try deliver(#""kind":"request","fid":5,"username":"dave","text":"","pictures":0"#).tap?.target, .manage)
        XCTAssertEqual(try deliver(#""kind":"report","fid":6,"username":"erin","text":"spam","post":"\#(root)","thread":"\#(root)""#).tap?.target, .manage)
        XCTAssertFalse(try deliver(#""kind":"approved","fid":3,"username":"dwr","text":"","pictures":0"#).countsOnBadge)
    }

    func testAnythingThatDoesntOpenShowsTheFallback() throws {
        let fields = #""kind":"reply","fid":4,"username":"helen","text":"hi""#
        XCTAssertEqual(try deliver(fields, handle: String(repeating: "x", count: 22)), .fallback, "A handle this phone doesn't have")
        XCTAssertEqual(try deliver(fields, key: SymmetricKey(size: .bits256)), .fallback, "Another key")
        XCTAssertEqual(PushDelivery.make(userInfo: ["h": target.handle.handle], targets: [target]), .fallback, "No note")
        XCTAssertEqual(PushDelivery.make(userInfo: ["h": target.handle.handle, "s": try seal(fields)], targets: []), .fallback,
                       "Locked since the phone started, so no keys")
        XCTAssertEqual(PushDelivery.fallback.title, "Fatline")
        XCTAssertEqual(PushDelivery.fallback.body, "Something new in a network.")
        XCTAssertNil(PushDelivery.fallback.tap)
    }

    func testATapReadsBackWhatTheExtensionWrote() throws {
        let tap = PushTap(host: "pine.example", kind: .reply, post: reply, thread: root, count: 1)
        XCTAssertEqual(PushTap(userInfo: tap.userInfo), tap)
    }

    func testATapIgnoresWhatTheExtensionDidntWrite() {
        XCTAssertNil(PushTap(userInfo: ["h": "handle", "s": "sealed"]), "The relay's payload alone opens nothing")
        XCTAssertNil(PushTap(userInfo: [PushTap.key: ["host": "pine.example", "kind": "like"]]))
        let odd = PushTap(userInfo: [PushTap.key: ["host": "pine.example", "kind": "reply", "post": "../admin", "thread": root.uppercased()]])
        XCTAssertNil(odd?.post, "Only real hashes")
        XCTAssertNil(odd?.thread)
        XCTAssertEqual(odd?.target, .activity)
    }

    func testTheBadgeCountsByNetworkAndClearsOne() throws {
        let suite = "fatline.tests.push-badge.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let badge = PushBadge(defaults: defaults)
        XCTAssertEqual(badge.add("pine.example"), 1)
        XCTAssertEqual(badge.add("pine.example"), 2)
        XCTAssertEqual(badge.add("cabin.example"), 3)
        XCTAssertEqual(badge.clear("pine.example"), 1, "Pine Street's Activity opened")
        XCTAssertEqual(badge.counts, ["cabin.example": 1])
        badge.clearAll()
        XCTAssertEqual(badge.total, 0)
    }

    func testOffHearsNothingUnlessAnAdminKeepsRequestsOrReports() {
        XCTAssertTrue(PushChoices().hearsAnything(admin: false))
        XCTAssertFalse(PushChoices(level: .off).hearsAnything(admin: false))
        XCTAssertTrue(PushChoices(level: .off).hearsAnything(admin: true))
        XCTAssertTrue(PushChoices(level: .off, requests: false).hearsAnything(admin: true))
        XCTAssertFalse(PushChoices(level: .off, requests: false, reports: false).hearsAnything(admin: true))
    }
}

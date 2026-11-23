import XCTest
@testable import Fatline

/// Debug's Send Test Notification: the network's `POST /me/push/test` and the words for what it said.
final class PushTestTests: XCTestCase {
    /// Answers one request and keeps it.
    private final class Server: @unchecked Sendable {
        let status: Int
        let body: String
        var sent: [URLRequest] = []
        init(_ status: Int, _ body: String) { self.status = status; self.body = body }

        var transport: NetworkClient.Transport {
            { request in
                self.sent.append(request)
                return (Data(self.body.utf8), HTTPURLResponse(url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private func client(_ server: Server) -> NetworkClient {
        var membership = NetworkMembership(host: "pine.example.net", fid: 3, key: Data(repeating: 1, count: 32), issued: 0,
                                           approval: "", status: .approved)
        membership.token = "session"
        return NetworkClient(membership: membership, transport: server.transport, retryDelay: .zero)
    }

    func testItPostsAndReadsWhatTheRelaySaid() async throws {
        let server = Server(200, "{\"result\":\"failed\",\"reason\":\"BadDeviceToken\"}")
        let answer = try await client(server).testPush()
        XCTAssertEqual(server.sent[0].httpMethod, "POST")
        XCTAssertEqual(server.sent[0].url?.path(), "/api/v1/me/push/test")
        XCTAssertEqual(server.sent[0].value(forHTTPHeaderField: "authorization"), "Bearer session")
        XCTAssertEqual(answer, PushTestAnswer(result: .failed, reason: "BadDeviceToken"))
        let sent = try await client(Server(200, "{\"result\":\"sent\"}")).testPush()
        XCTAssertEqual(sent, PushTestAnswer(result: .sent))
    }

    func testAnOlderNetworkSaysItCantYet() async {
        do {
            _ = try await client(Server(404, "{\"message\":\"Not found.\"}")).testPush()
            XCTFail("An older network has no such route")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This network can’t send test notifications yet.")
        }
        do {
            _ = try await client(Server(404, "{\"message\":\"This network has nowhere to send this device's notifications.\",\"code\":\"no-push\"}")).testPush()
            XCTFail("No target is an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This network has nowhere to send this device's notifications.")
        }
    }

    func testTheWords() {
        XCTAssertEqual(PushTestAnswer(result: .sent).detail, "The relay passed it to Apple.")
        XCTAssertEqual(PushTestAnswer(result: .failed, reason: "TopicDisallowed").detail,
                       "It didn’t reach Apple: Apple won’t send for this app (TopicDisallowed).")
        XCTAssertEqual(PushTestAnswer(result: .failed, reason: "relay-503").detail, "It didn’t reach Apple: the relay answered 503 (relay-503).")
        XCTAssertEqual(PushTestAnswer(result: .failed, reason: "SomethingNew").detail, "It didn’t reach Apple: SomethingNew.")
        XCTAssertEqual(PushTestAnswer(result: .failed).detail, "It didn’t reach Apple.")
        XCTAssertTrue(PushTestAnswer(result: .gone, reason: "BadDeviceToken").detail.contains("sandbox or production"))
        XCTAssertTrue(PushTestAnswer(result: .gone, reason: "BadDeviceToken").detail.hasSuffix("send it again."))
    }

    func testATestNoteOpensTheFeedAndLeavesTheBadgeAlone() {
        let tap = PushTap(host: "pine.example.net", kind: .test, post: nil, thread: nil, count: 1)
        XCTAssertEqual(tap.target, .feed)
        XCTAssertEqual(PushTap(userInfo: tap.userInfo), tap)
        XCTAssertFalse(PushDelivery(title: "Pine Street", body: "", thread: nil, tap: tap).countsOnBadge)
    }
}

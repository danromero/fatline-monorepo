import CryptoKit
import XCTest
@testable import Fatline

/// The phone's side of the relay and of a network's `/me/push`, against stand-ins that record what
/// was sent (push/README.md, docs/NETWORK.md).
final class PushRelayTests: XCTestCase {
    /// Answers each request in turn and keeps what was sent.
    private final class Server: @unchecked Sendable {
        var answers: [(status: Int, body: String)]
        var sent: [URLRequest] = []
        init(_ answers: [(Int, String)]) { self.answers = answers.map { (status: $0.0, body: $0.1) } }

        var transport: NetworkClient.Transport {
            { request in
                self.sent.append(request)
                let answer = self.answers.isEmpty ? (status: 500, body: "") : self.answers.removeFirst()
                return (Data(answer.body.utf8), HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!)
            }
        }

        func json(_ index: Int) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent[index].httpBody)) as? [String: Any])
        }
    }

    private let handle = PushRelay.Handle(handle: String(repeating: "h", count: 22), secret: String(repeating: "s", count: 43))
    /// The Simulator's tokens are 80 bytes, a phone's 32.
    private let token = Data((0..<80).map { UInt8($0) })

    private func relay(_ server: Server) -> PushRelay {
        PushRelay(origin: URL(string: "https://push.example.net")!, transport: server.transport)
    }

    private func answer(_ handle: PushRelay.Handle) -> String {
        "{\"handle\":\"\(handle.handle)\",\"secret\":\"\(handle.secret)\"}"
    }

    // MARK: The relay

    func testRegisteringSendsTheTokenAsHexAndKeepsTheHandle() async throws {
        let server = Server([(201, answer(handle))])
        let got = try await relay(server).register(token: token, environment: .sandbox, app: "org.danromero.fatline.dev")
        XCTAssertEqual(got, handle)
        XCTAssertEqual(server.sent[0].httpMethod, "POST")
        XCTAssertEqual(server.sent[0].url?.absoluteString, "https://push.example.net/handles")
        XCTAssertEqual(server.sent[0].value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertNil(server.sent[0].value(forHTTPHeaderField: "authorization"))
        let body = try server.json(0)
        XCTAssertEqual(body["token"] as? String, PushRelay.hex(token))
        XCTAssertEqual((body["token"] as? String)?.count, 160)
        XCTAssertEqual(body["env"] as? String, "sandbox")
        XCTAssertEqual(body["app"] as? String, "org.danromero.fatline.dev")
    }

    func testAHandleThatCouldReachAnotherPathIsRefused() async throws {
        for bad in [PushRelay.Handle(handle: "../../admin/xxxxxxxxxxx", secret: handle.secret),
                    PushRelay.Handle(handle: String(repeating: "h", count: 21), secret: handle.secret),
                    PushRelay.Handle(handle: handle.handle, secret: "short")] {
            let server = Server([(201, answer(bad))])
            do {
                _ = try await relay(server).register(token: token, app: "org.danromero.fatline")
                XCTFail("Took \(bad)")
            } catch {
                XCTAssertEqual(error as? PushRelay.Problem, .unreadable)
            }
            // And a saved one like it is never put in a path.
            let refreshed = try await relay(Server([])).refresh(bad, token: token)
            XCTAssertFalse(refreshed)
        }
    }

    func testTheRelaysWordsComeBackWhenItSaysNo() async throws {
        let server = Server([(400, "{\"message\":\"Invalid registration.\"}")])
        do {
            _ = try await relay(server).register(token: Data(), app: "org.danromero.fatline")
            XCTFail("Registered")
        } catch {
            XCTAssertEqual(error as? PushRelay.Problem, .refused(status: 400, message: "Invalid registration."))
        }
    }

    func testRefreshingSendsTheSecretAndSaysWhenTheHandleIsGone() async throws {
        let server = Server([(204, ""), (404, "{\"message\":\"No such handle.\"}")])
        let relay = relay(server)
        let first = try await relay.refresh(handle, token: token)
        let second = try await relay.refresh(handle, token: token)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(server.sent[0].httpMethod, "PUT")
        XCTAssertEqual(server.sent[0].url?.path(), "/handles/\(handle.handle)")
        XCTAssertEqual(server.sent[0].value(forHTTPHeaderField: "authorization"), "Bearer \(handle.secret)")
        XCTAssertEqual(try server.json(0)["token"] as? String, PushRelay.hex(token))
    }

    func testRemovingCountsGoneAsDone() async throws {
        let server = Server([(204, ""), (404, ""), (401, "{\"message\":\"Wrong secret.\"}")])
        let relay = relay(server)
        try await relay.remove(handle)
        try await relay.remove(handle)
        XCTAssertEqual(server.sent[0].httpMethod, "DELETE")
        XCTAssertNil(server.sent[0].httpBody)
        do {
            try await relay.remove(handle)
            XCTFail("Removed with a wrong secret")
        } catch {
            XCTAssertEqual(error as? PushRelay.Problem, .refused(status: 401, message: "Wrong secret."))
        }
    }

    func testNotReachingTheRelayIsItsOwnProblem() async throws {
        let relay = PushRelay(origin: URL(string: "https://push.example.net")!) { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await relay.register(token: token, app: "org.danromero.fatline")
            XCTFail("Registered")
        } catch {
            XCTAssertEqual(error as? PushRelay.Problem, .unreachable)
        }
    }

    func testTheRelayAddressHasNoTrailingSlash() {
        XCTAssertEqual(PushRelay.standard.address, "https://push.fatline.tech")
        XCTAssertEqual(PushRelay(origin: URL(string: "https://push.example.net/")!).address, "https://push.example.net")
    }

    // MARK: The network

    private func target(_ choices: PushChoices = PushChoices()) -> PushTarget {
        PushTarget.make(host: "pine.example.net", name: "Pine Street", relay: PushRelay.standard, handle: handle, choices: choices)
    }

    func testEachNetworkGetsItsOwnKey() {
        let one = target(), two = target()
        XCTAssertEqual(one.key.count, 32)
        XCTAssertNotEqual(one.key, two.key)
        XCTAssertEqual(one.symmetricKey.bitCount, 256)
    }

    func testPuttingPushSendsTheRelayHandleKeyAndChoices() async throws {
        let server = Server([(204, "")])
        var membership = NetworkMembership(host: "pine.example.net", fid: 3, key: Data(repeating: 1, count: 32), issued: 0,
                                           approval: "", status: .approved)
        membership.token = "session"
        let client = NetworkClient(membership: membership, transport: server.transport, retryDelay: .zero)
        let target = target(PushChoices(level: .replies, requests: false, reports: true))
        try await client.setPush(target)
        XCTAssertEqual(server.sent[0].httpMethod, "PUT")
        XCTAssertEqual(server.sent[0].url?.path(), "/api/v1/me/push")
        XCTAssertEqual(server.sent[0].value(forHTTPHeaderField: "authorization"), "Bearer session")
        let body = try server.json(0)
        XCTAssertEqual(body["relay"] as? String, "https://push.fatline.tech")
        XCTAssertEqual(body["handle"] as? String, handle.handle)
        XCTAssertEqual(body["key"] as? String, target.key.hex)
        XCTAssertEqual((body["key"] as? String)?.count, 66, "0x and 64 hex digits, as the network checks")
        XCTAssertEqual(body["level"] as? String, "replies")
        XCTAssertEqual(body["requests"] as? Bool, false)
        XCTAssertEqual(body["reports"] as? Bool, true)
        XCTAssertEqual(body["tz"] as? String, TimeZone.current.identifier, "Where this iPhone is, for when summaries go")
        XCTAssertNil(body["secret"], "The network never gets the relay's secret")
    }

    func testANewDeviceHearsTwiceADay() {
        XCTAssertEqual(PushChoices().level, .digest)
        XCTAssertEqual(PushChoices.Level.allCases.first, .digest, "First in Settings")
        XCTAssertEqual(PushChoices.Level.digest.title, "Twice a day")
        XCTAssertEqual(target().pushFields["level"] as? String, "digest")
    }

    func testAJoinsPushCarriesTheTimeZone() {
        let fields = PushTarget.make(host: "pine.example.net", name: "Pine Street", relay: PushRelay.standard, handle: handle,
                                     zone: "Asia/Kolkata").joinFields
        XCTAssertEqual(fields["tz"] as? String, "Asia/Kolkata")
        XCTAssertNil(fields["level"], "A join leaves the level to the network: twice a day")
    }

    func testATargetSavedBeforeSummariesStillReads() throws {
        // As the Keychain holds one from before November 21, 2026: no zone.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target())) as! [String: Any]
        old["zone"] = nil
        let read = try JSONDecoder().decode(PushTarget.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(read.zone)
        XCTAssertNil(read.joinFields["tz"])
    }

    func testSeenSendsThePostsTime() async throws {
        let server = Server([(204, "")])
        var membership = NetworkMembership(host: "pine.example.net", fid: 3, key: Data(repeating: 1, count: 32), issued: 0,
                                           approval: "", status: .approved)
        membership.token = "session"
        try await NetworkClient(membership: membership, transport: server.transport, retryDelay: .zero).setSeen(1_795_000_000)
        XCTAssertEqual(server.sent[0].httpMethod, "PUT")
        XCTAssertEqual(server.sent[0].url?.path(), "/api/v1/me/seen")
        XCTAssertEqual(try server.json(0)["time"] as? Int, 1_795_000_000)
    }

    func testRemovingPush() async throws {
        let server = Server([(204, "")])
        var membership = NetworkMembership(host: "pine.example.net", fid: 3, key: Data(repeating: 1, count: 32), issued: 0,
                                           approval: "", status: .approved)
        membership.token = "session"
        try await NetworkClient(membership: membership, transport: server.transport, retryDelay: .zero).removePush()
        XCTAssertEqual(server.sent[0].httpMethod, "DELETE")
        XCTAssertEqual(server.sent[0].url?.path(), "/api/v1/me/push")
    }

    func testAJoinGoesAgainWithoutPushWhenTheNetworkWontUseTheRelay() async throws {
        let device = NetworkDevice(fid: 3, custody: "0x0000000000000000000000000000000000000003",
                                   key: Curve25519.Signing.PrivateKey().rawRepresentation, issuedAt: 1, signature: "0x01")
        let server = Server([(400, "{\"message\":\"This network doesn't send notifications through that relay.\",\"code\":\"unknown-relay\"}"),
                             (200, "{\"status\":\"pending\"}")])
        let joined = try await NetworkClient.join(host: "pine.example.net", device: device, invite: nil, push: target(), transport: server.transport)
        XCTAssertEqual(joined.status, .pending)
        XCTAssertEqual(server.sent.count, 2)
        let first = try server.json(0), second = try server.json(1)
        XCTAssertEqual((first["push"] as? [String: Any])?["handle"] as? String, handle.handle)
        XCTAssertNil((first["push"] as? [String: Any])?["level"], "A join's push is only where, not what")
        XCTAssertNil(second["push"])
    }
}

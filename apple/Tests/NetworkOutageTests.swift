import CryptoKit
import XCTest
@testable import Fatline

/// One dropped request, or one the app called off, shouldn't put up "Couldn't reach the network."
final class NetworkOutageTests: XCTestCase {
    /// Answers each request with the next outcome: an error, or a body sent back with a 200.
    private final class Line: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [Result<String, URLError>]
        private var sent: [String] = []

        init(_ outcomes: [Result<String, URLError>]) { self.outcomes = outcomes }

        var methods: [String] { lock.withLock { sent } }

        var transport: NetworkClient.Transport {
            { [self] request in
                let outcome = lock.withLock {
                    sent.append(request.httpMethod ?? "")
                    return outcomes.isEmpty ? .failure(URLError(.badServerResponse)) : outcomes.removeFirst()
                }
                let body = try outcome.get()
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private let noRequests = #"{"requests":[]}"#
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func client(_ line: Line) -> NetworkClient {
        let membership = NetworkMembership(host: "pine.example", fid: 3, key: Curve25519.Signing.PrivateKey().rawRepresentation, issued: 0,
                                           approval: "", status: .approved, token: "token-1", expires: .max)
        return NetworkClient(membership: membership, transport: line.transport, retryDelay: .zero)
    }

    // MARK: The client

    func testAReadThatDropsGoesOnceMore() async throws {
        let line = Line([.failure(URLError(.networkConnectionLost)), .success(noRequests)])
        let waiting = try await client(line).waitingRequests()
        XCTAssertEqual(waiting, 0)
        XCTAssertEqual(line.methods, ["GET", "GET"])
    }

    func testAReadThatDropsTwiceIsUnreachable() async {
        let line = Line([.failure(URLError(.notConnectedToInternet)), .failure(URLError(.notConnectedToInternet)), .success(noRequests)])
        do {
            _ = try await client(line).waitingRequests()
            XCTFail("A read that dropped twice should be unreachable")
        } catch {
            XCTAssertEqual(error as? NetworkError, .unreachable)
        }
        XCTAssertEqual(line.methods, ["GET", "GET"])
    }

    func testAWriteThatDropsIsntSentAgain() async {
        let line = Line([.failure(URLError(.networkConnectionLost)), .success("{}")])
        do {
            _ = try await client(line).upload(Data([1]), type: "image/jpeg")
            XCTFail("A write that dropped should be unreachable")
        } catch {
            XCTAssertEqual(error as? NetworkError, .unreachable)
        }
        XCTAssertEqual(line.methods, ["POST"])
    }

    func testAReadThatTimedOutIsntSentAgain() async {
        let line = Line([.failure(URLError(.timedOut)), .success(noRequests)])
        do {
            _ = try await client(line).waitingRequests()
            XCTFail("A read that timed out should be unreachable")
        } catch {
            XCTAssertEqual(error as? NetworkError, .unreachable)
        }
        XCTAssertEqual(line.methods, ["GET"])
    }

    func testARequestCalledOffIsntUnreachable() async {
        let line = Line([.failure(URLError(.cancelled))])
        do {
            _ = try await client(line).waitingRequests()
            XCTFail("A request called off should throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(line.methods, ["GET"])
    }

    // MARK: When the banner shows

    func testQuickFailuresShowOnlyOnceTheyveLastedTheGrace() {
        var outage = NetworkOutage()
        XCTAssertFalse(outage.failed(started: start, now: start + 2))
        XCTAssertFalse(outage.failed(started: start + 6, now: start + 7))
        XCTAssertTrue(outage.failed(started: start + 11, now: start + 12))
    }

    func testAReadThatTookLongerThanTheGraceShowsAtOnce() {
        var outage = NetworkOutage()
        XCTAssertTrue(outage.failed(started: start, now: start + 30))
    }

    func testAFailureLongAfterTheLastStartsOver() {
        var outage = NetworkOutage()
        _ = outage.failed(started: start, now: start + 1)
        XCTAssertTrue(outage.failed(started: start + 60, now: start + 61))
        // Back after the app was away: the first failure is quiet again.
        XCTAssertFalse(outage.failed(started: start + 3600, now: start + 3601))
    }

    func testAFreshOutageStartsQuiet() {
        var outage = NetworkOutage()
        XCTAssertTrue(outage.failed(started: start, now: start + 10))
        outage = NetworkOutage()
        XCTAssertFalse(outage.failed(started: start + 20, now: start + 21))
    }
}

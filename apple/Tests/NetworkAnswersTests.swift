import CryptoKit
import XCTest
@testable import Fatline

/// Polling sends the last ETag, a 304 keeps the posts already read, and a thread follows `next` back.
final class NetworkAnswersTests: XCTestCase {
    /// Answers each request with the next status, body, and ETag, and keeps what was asked.
    private final class Server: @unchecked Sendable {
        struct Answer {
            var status = 200
            var body = ""
            var etag: String?
        }

        private let lock = NSLock()
        private var answers: [Answer]
        private var asked: [URLRequest] = []

        init(_ answers: [Answer]) { self.answers = answers }

        var requests: [URLRequest] { lock.withLock { asked } }

        var transport: NetworkClient.Transport {
            { [self] request in
                let answer = lock.withLock {
                    asked.append(request)
                    return answers.isEmpty ? Answer(status: 500) : answers.removeFirst()
                }
                let headers = answer.etag.map { ["etag": $0] }
                return (Data(answer.body.utf8), HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: headers)!)
            }
        }
    }

    private func client(_ server: Server, answers: NetworkAnswers) -> NetworkClient {
        let membership = NetworkMembership(host: "pine.example", fid: 3, key: Curve25519.Signing.PrivateKey().rawRepresentation, issued: 0,
                                           approval: "", status: .approved, token: "token-1", expires: .max)
        return NetworkClient(membership: membership, transport: server.transport, retryDelay: .zero, answers: answers)
    }

    private func post(_ hash: String, time: Int64, parent: String? = nil) -> String {
        #"{"hash":"\#(hash)","fid":3,"time":\#(time),"text":"hi","mentions":[],"parent":\#(parent.map { "\"\($0)\"" } ?? "null"),"embeds":[],"replies":0,"likes":0,"liked":false,"deleted":false}"#
    }

    private func feed(_ hashes: [String]) -> String {
        #"{"posts":[\#(hashes.enumerated().map { post($0.element, time: Int64(100 - $0.offset)) }.joined(separator: ","))],"next":null}"#
    }

    func testAPollSendsTheLastETagAndA304KeepsThePosts() async throws {
        let server = Server([
            .init(body: feed(["0x01", "0x02"]), etag: #""v1""#),
            .init(status: 304, etag: #""v1""#),
        ])
        let client = client(server, answers: NetworkAnswers())
        let first = try await client.feed()
        let second = try await client.feed()
        XCTAssertEqual(first.map(\.hash), ["0x01", "0x02"])
        XCTAssertEqual(second, first)
        XCTAssertNil(server.requests[0].value(forHTTPHeaderField: "if-none-match"))
        XCTAssertEqual(server.requests[1].value(forHTTPHeaderField: "if-none-match"), #""v1""#)
    }

    func testANewETagReplacesTheKeptOne() async throws {
        let server = Server([
            .init(body: feed(["0x01"]), etag: #""v1""#),
            .init(body: feed(["0x03", "0x01"]), etag: #""v2""#),
            .init(status: 304),
        ])
        let client = client(server, answers: NetworkAnswers())
        _ = try await client.feed()
        let changed = try await client.feed()
        let again = try await client.feed()
        XCTAssertEqual(changed.map(\.hash), ["0x03", "0x01"])
        XCTAssertEqual(again, changed)
        XCTAssertEqual(server.requests[2].value(forHTTPHeaderField: "if-none-match"), #""v2""#)
    }

    func testA304WithNothingKeptIsAnError() async {
        let server = Server([.init(status: 304)])
        do {
            _ = try await client(server, answers: NetworkAnswers()).feed()
            XCTFail("A 304 with nothing kept should fail")
        } catch {
            XCTAssertNotNil(error as? NetworkError)
        }
    }

    func testAnAnswerWithoutAnETagIsntKept() async throws {
        let server = Server([.init(body: feed(["0x01"])), .init(body: feed(["0x01"]))])
        let client = client(server, answers: NetworkAnswers())
        _ = try await client.feed()
        _ = try await client.feed()
        XCTAssertNil(server.requests[1].value(forHTTPHeaderField: "if-none-match"))
    }

    func testOtherAccountsAndPagesKeepTheirOwnETags() async throws {
        let answers = NetworkAnswers()
        let server = Server([
            .init(body: feed(["0x01"]), etag: #""feed""#),
            .init(body: #"{"items":[]}"#, etag: #""activity""#),
            .init(status: 304),
            .init(status: 304),
        ])
        let client = client(server, answers: answers)
        _ = try await client.feed()
        _ = try await client.activity()
        _ = try await client.activity()
        _ = try await client.feed()
        XCTAssertEqual(server.requests[2].value(forHTTPHeaderField: "if-none-match"), #""activity""#)
        XCTAssertEqual(server.requests[3].value(forHTTPHeaderField: "if-none-match"), #""feed""#)
    }

    func testOnlyTheLatestAnswersAreKept() {
        let answers = NetworkAnswers()
        for index in 0...NetworkAnswers.limit { answers.keep("page \(index)", etag: "\(index)", data: Data()) }
        XCTAssertNil(answers.answer("page 0"))
        XCTAssertEqual(answers.answer("page \(NetworkAnswers.limit)")?.etag, "\(NetworkAnswers.limit)")
    }

    // MARK: Threads

    func testAThreadFollowsNextForOlderReplies() async throws {
        let root = post("0xr", time: 1)
        let newer = [post("0x3", time: 30, parent: "0xr"), post("0x4", time: 40, parent: "0xr")].joined(separator: ",")
        let older = [post("0x1", time: 10, parent: "0xr"), post("0x2", time: 20, parent: "0xr")].joined(separator: ",")
        let server = Server([
            .init(body: #"{"post":\#(root),"replies":[\#(newer)],"next":"older"}"#),
            .init(body: #"{"post":\#(root),"replies":[\#(older)],"next":null}"#),
        ])
        let thread = try await client(server, answers: NetworkAnswers()).thread("0xr")
        XCTAssertEqual(thread.replies.map(\.hash), ["0x1", "0x2", "0x3", "0x4"])
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(URLComponents(url: server.requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "cursor", value: "older")])
    }

    func testAThreadStopsAtACursorItSawBefore() async throws {
        let root = post("0xr", time: 1)
        let reply = post("0x1", time: 10, parent: "0xr")
        let looping = #"{"post":\#(root),"replies":[\#(reply)],"next":"same"}"#
        let server = Server([.init(body: looping), .init(body: looping), .init(body: looping)])
        let thread = try await client(server, answers: NetworkAnswers()).thread("0xr")
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(thread.replies.count, 2)
    }

    func testAThreadFromBeforePagesReadsOnce() async throws {
        let root = post("0xr", time: 1)
        let server = Server([.init(body: #"{"post":\#(root),"replies":[\#(post("0x1", time: 10, parent: "0xr"))]}"#)])
        let thread = try await client(server, answers: NetworkAnswers()).thread("0xr")
        XCTAssertEqual(thread.replies.map(\.hash), ["0x1"])
        XCTAssertEqual(server.requests.count, 1)
    }
}

import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Fatline

/// The app reads link previews and the Farcaster picture itself and sends them, so a network fetches
/// nothing from the web (docs/NETWORK.md). These check what goes over the wire.
final class NetworkPreviewsTests: XCTestCase {
    /// Stands in for the network: keeps every request and answers each `METHOD /path` as told.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: (Int, String)] = [:]
        private var sent: [URLRequest] = []

        var requests: [URLRequest] { lock.withLock { sent } }
        var routes: [String] { requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } }

        func answer(_ route: String, _ status: Int, _ body: String = "") {
            lock.withLock { answers[route] = (status, body) }
        }

        func body(_ index: Int) -> [String: Any]? {
            requests[index].httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        var transport: NetworkClient.Transport {
            { [self] request in
                let route = "\(request.httpMethod ?? "") \(request.url?.path() ?? "")"
                let (status, body) = lock.withLock {
                    sent.append(request)
                    return answers[route] ?? (404, #"{"message":"No such route."}"#)
                }
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private let member = #"{"fid":3,"username":"dwr","displayName":"","bio":"","role":"member","joined":0,"muted":false,"avatar":"https://pine.example/media/pic1/thumb?e=1&s=x","ownAvatar":false}"#

    private func client(_ server: Server) -> NetworkClient {
        let membership = NetworkMembership(host: "pine.example", fid: 3, key: Curve25519.Signing.PrivateKey().rawRepresentation, issued: 0,
                                           approval: "", status: .approved, token: "token-1", expires: .max)
        return NetworkClient(membership: membership, transport: server.transport)
    }

    private func picture() -> NetworkImage {
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return NetworkImage(data: output as Data)!
    }

    // MARK: Requests

    func testAPostWhoseLinksTheAppReadsSaysSo() async throws {
        let server = Server()
        server.answer("POST /api/v1/messages", 200, #"{"hash":"0xabc"}"#)
        let message = SnapchainMessage(hash: "0xabc", bytes: Data([1, 2, 3]))
        try await client(server).submit(message, readsLinks: true)
        try await client(server).submit(message)
        XCTAssertEqual(server.requests[0].value(forHTTPHeaderField: "Fatline-Previews"), "app")
        XCTAssertEqual(server.requests[0].httpBody, Data([1, 2, 3]))
        XCTAssertNil(server.requests[1].value(forHTTPHeaderField: "Fatline-Previews"), "a post without links lets the network be")
    }

    func testPreviewsGoToThePostLeavingOutWhatWasntFound() async throws {
        let server = Server()
        server.answer("PUT /api/v1/posts/0xabc/previews", 204)
        try await client(server).sendPreviews("0xabc", [
            .init(url: "https://a.example/one", title: "One", description: nil, image: "img1"),
            .init(url: "https://b.example/two", title: nil, description: "Second", image: nil),
        ])
        XCTAssertEqual(server.routes, ["PUT /api/v1/posts/0xabc/previews"])
        XCTAssertEqual(server.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        let previews = try XCTUnwrap(server.body(0)?["previews"] as? [[String: String]])
        XCTAssertEqual(previews, [["url": "https://a.example/one", "title": "One", "image": "img1"],
                                  ["url": "https://b.example/two", "description": "Second"]])
    }

    func testTheFarcasterPictureIsAnUpload() async throws {
        let server = Server()
        server.answer("PATCH /api/v1/me", 200, member)
        let you = try await client(server).setFarcasterPicture("pic1")
        XCTAssertEqual(you.fid, 3)
        XCTAssertEqual(server.body(0) as? [String: String], ["farcasterPicture": "pic1"])
    }

    func testAJoinCarriesNoPicture() async throws {
        let server = Server()
        server.answer("POST /api/v1/join", 200, #"{"status":"pending"}"#)
        let device = NetworkDevice(fid: 3, custody: "0x0000000000000000000000000000000000000003",
                                   key: Curve25519.Signing.PrivateKey().rawRepresentation, issuedAt: 1, signature: "0x01")
        let membership = try await NetworkClient.join(host: "pine.example", device: device, invite: "CODE", transport: server.transport)
        XCTAssertEqual(membership.status, .pending)
        let body = try XCTUnwrap(server.body(0))
        XCTAssertEqual(body["invite"] as? String, "CODE")
        XCTAssertEqual(body["fid"] as? Int, 3)
        XCTAssertNil(body["avatar"], "the app uploads the picture once in, so the network fetches nothing")
    }

    // MARK: Previews after a post

    func testAPreviewsPictureGoesUpFirst() async throws {
        let server = Server()
        server.answer("POST /api/v1/media", 200, #"{"id":"img1","url":"https://pine.example/m/img1","width":40,"height":30}"#)
        server.answer("PUT /api/v1/posts/0xabc/previews", 204)
        let picture = picture()
        let page = LinkPreview(title: "Tom\u{202E} & \nJerry", description: "  A   cat\u{200B} ", image: URL(string: "https://a.example/cat.jpg"))
        await NetworkPreviews.send(links: ["https://a.example/one"], hash: "0xabc", client: client(server),
                                   read: { _ in page }, download: { $0.host() == "a.example" ? picture : nil })
        XCTAssertEqual(server.routes, ["POST /api/v1/media", "PUT /api/v1/posts/0xabc/previews"])
        XCTAssertEqual(server.requests[0].value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        let previews = try XCTUnwrap(server.body(1)?["previews"] as? [[String: String]])
        XCTAssertEqual(previews, [["url": "https://a.example/one", "title": "Tom & Jerry", "description": "A cat", "image": "img1"]],
                       "text is on one line with nothing hidden or reversed, as the network takes it")
    }

    func testAPreviewThatFailsLeavesThePostAlone() async throws {
        // The picture is refused: the title still goes.
        let server = Server()
        server.answer("POST /api/v1/media", 429, #"{"message":"That's 50 pictures today."}"#)
        server.answer("PUT /api/v1/posts/0xabc/previews", 204)
        let picture = picture()
        await NetworkPreviews.send(links: ["https://a.example/one"], hash: "0xabc", client: client(server),
                                   read: { _ in LinkPreview(title: "One", image: URL(string: "https://a.example/p.jpg")) },
                                   download: { _ in picture })
        XCTAssertEqual(server.routes, ["POST /api/v1/media", "PUT /api/v1/posts/0xabc/previews"])
        XCTAssertEqual(server.body(1)?["previews"] as? [[String: String]], [["url": "https://a.example/one", "title": "One"]])

        // Nothing read, or nothing left once cleaned: nothing sent.
        let quiet = Server()
        await NetworkPreviews.send(links: ["https://a.example/one"], hash: "0xabc", client: client(quiet), read: { _ in nil })
        await NetworkPreviews.send(links: ["https://a.example/one"], hash: "0xabc", client: client(quiet),
                                   read: { _ in LinkPreview(title: "\u{200B}\u{202E}") })
        XCTAssertEqual(quiet.routes, [])

        // The network refusing the previews doesn't throw.
        let refusing = Server()
        await NetworkPreviews.send(links: ["https://a.example/one"], hash: "0xabc", client: client(refusing),
                                   read: { _ in LinkPreview(title: "One") })
        XCTAssertEqual(refusing.routes, ["PUT /api/v1/posts/0xabc/previews"])
    }

    func testTheFarcasterPictureIsDownloadedThenUploaded() async throws {
        let server = Server()
        server.answer("POST /api/v1/media", 200, #"{"id":"pic1","url":"https://pine.example/m/pic1","width":40,"height":30}"#)
        server.answer("PATCH /api/v1/me", 200, member)
        let picture = picture()
        let you = await NetworkPreviews.sendFarcasterPicture("https://imagedelivery.example/me.png", client: client(server),
                                                             download: { _ in picture })
        XCTAssertEqual(you?.fid, 3)
        XCTAssertEqual(server.routes, ["POST /api/v1/media", "PATCH /api/v1/me"])
        XCTAssertEqual(server.body(1) as? [String: String], ["farcasterPicture": "pic1"])

        let unreadable = Server()
        let nobody = await NetworkPreviews.sendFarcasterPicture("https://imagedelivery.example/me.png", client: client(unreadable),
                                                                download: { _ in nil })
        XCTAssertNil(nobody)
        XCTAssertEqual(unreadable.routes, [], "no picture, nothing sent")
    }

    // MARK: Reading the page

    func testTextIsCleanedAsTheNetworkWantsIt() {
        XCTAssertEqual(LinkPreview.networkText("Line one\nline\ttwo"), "Line one line two")
        XCTAssertEqual(LinkPreview.networkText("evil\u{202E}txt.exe \u{2066}x\u{2069}"), "eviltxt.exe x", "nothing reverses text")
        XCTAssertEqual(LinkPreview.networkText("a\u{200B}b\u{FEFF}c\u{00AD}d\u{2060}e"), "abcde", "nothing hides")
        XCTAssertEqual(LinkPreview.networkText("family 👨‍👩‍👧 and 🏴󠁧󠁢󠁳󠁣󠁴󠁿"), "family 👨‍👩‍👧 and 🏴󠁧󠁢󠁳󠁣󠁴󠁿", "joiners and a flag's tags stay")
        XCTAssertEqual(LinkPreview.networkText("tag\u{E0041}ged"), "tagged", "a tag outside a flag goes")
        XCTAssertEqual(LinkPreview.networkText("\u{FE0F}start \u{200D}\u{200D}x"), "start \u{200D}x", "no stray selectors or joiner runs")
        XCTAssertEqual(LinkPreview.networkText(" \u{FE0F}lead"), "lead", "trimming leaves no selector at the start")
        XCTAssertNil(LinkPreview.networkText(" \n\u{200B} "))
        let long = String(repeating: "é", count: 400)
        XCTAssertEqual(LinkPreview.networkText(long)?.count, LinkPreview.maxText)
    }

    func testAPageGivesItsPicture() {
        let base = URL(string: "https://a.example/posts/1")!
        let relative = LinkPreview.parse(#"<meta property="og:image" content="/img/cat.jpg?a=1&amp;b=2"><title>Cat &#x1F408; &#169;</title>"#, base: base)
        XCTAssertEqual(relative.image?.absoluteString, "https://a.example/img/cat.jpg?a=1&b=2")
        XCTAssertEqual(relative.title, "Cat 🐈 ©")
        let twitter = LinkPreview.parse(#"<meta name="twitter:image" content="https://cdn.example/t.png">"#, base: base)
        XCTAssertEqual(twitter.image?.absoluteString, "https://cdn.example/t.png")
        for unsafe in ["http://a.example/cat.jpg", "https://localhost/cat.jpg", "https://192.168.1.1/cat.jpg", "file:///etc/hosts"] {
            XCTAssertNil(LinkPreview.parse(#"<meta property="og:image" content="\#(unsafe)">"#, base: base).image, unsafe)
        }
    }
}

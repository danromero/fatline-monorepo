import CryptoKit
import Foundation

/// This device's key for Fatline networks, approved once by the account's custody address.
struct NetworkDevice: Codable, Sendable {
    let fid: UInt64
    let custody: String
    let key: Data
    let issuedAt: Int64
    let signature: String

    var signingKey: Curve25519.Signing.PrivateKey {
        get throws { try Curve25519.Signing.PrivateKey(rawRepresentation: key) }
    }
}

/// One network this device has joined or asked to join.
struct NetworkMembership: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case approved, pending, refused }

    let host: String
    let fid: UInt64
    let key: Data
    let issued: Int64
    let approval: String
    var status: Status
    var token: String?
    var expires: Int64?
    var name: String?
    var isAdmin = false
    /// A link to the network's picture, or nil for its first letter.
    var icon: String?
    /// A link to this account's Farcaster picture, which the app uploads once the network lets it in,
    /// and then forgets.
    var farcasterPicture: String?
    /// True once the network has let this account in, so a refusal after that reads as being removed.
    var wasApproved: Bool?
    /// What this device hears from the network. Nil is the default: all posts, and for an admin, join
    /// requests and reports.
    var pushChoices: PushChoices?

    var id: String { host }
    /// Refused after being let in: the admin removed this account. Only a member has a name for the
    /// network, which covers memberships saved before `wasApproved`.
    var removed: Bool { status == .refused && (wasApproved == true || name != nil) }
    /// Where a network that hasn't let you in stands, for menus and lists.
    var standing: String? {
        switch status {
        case .approved: nil
        case .pending: "Waiting"
        case .refused: removed ? "Removed" : "Not approved"
        }
    }
    var title: String { name ?? host }
    /// The name with the host beside it, for menus and Settings, so a network can't pass for another.
    var label: String { name.map { "\($0) · \(host)" } ?? host }

    /// The name a network gives itself, if the app shows it: at most 64 characters, nothing hidden or
    /// reversed, and not "Farcaster", an address, or another network's name or address, so one
    /// network can't pass for another. Otherwise the app shows the host.
    static func acceptedName(_ given: String?, host: String, others: [NetworkMembership]) -> String? {
        guard let name = given?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 64,
              !name.unicodeScalars.contains(where: hides) else { return nil }
        // Something like "net.example.com" reads as an address.
        if !name.contains(" "), name.contains("."), name.lowercased() != host { return nil }
        let fold = { (text: String) in text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
        let taken = ["Farcaster", "Fatline"] + others.filter { $0.host != host }.flatMap { [$0.title, $0.host] }
        return taken.contains { fold($0) == fold(name) } ? nil : name
    }

    /// Characters that show as nothing or reorder text: controls, format characters, and Hangul
    /// fillers. The zero-width joiner and non-joiner, and emoji tags, stay.
    private static func hides(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x200C || scalar.value == 0x200D || (0xE0020...0xE007F).contains(scalar.value) { return false }
        switch scalar.properties.generalCategory {
        case .control, .format: return true
        default: return [0x115F, 0x1160, 0x3164, 0xFFA0].contains(scalar.value)
        }
    }

    var signingKey: Curve25519.Signing.PrivateKey {
        get throws { try Curve25519.Signing.PrivateKey(rawRepresentation: key) }
    }
}

enum NetworkKeychain {
    static let device = KeychainValue<NetworkDevice>(account: "network-device-v1")
    static let memberships = KeychainValue<[NetworkMembership]>(account: "network-memberships-v1")
}

/// What a network server answers. See docs/NETWORK.md.
struct NetworkPost: Codable, Hashable, Identifiable, Sendable {
    struct Mention: Codable, Hashable, Sendable {
        let fid: UInt64
        let username: String
    }

    struct Quoted: Codable, Hashable, Sendable {
        let hash: String
        let fid: UInt64
        let text: String
    }

    struct Embed: Codable, Hashable, Sendable {
        struct Preview: Codable, Hashable, Sendable {
            var title: String?
            var description: String?
            var image: String?
        }

        let type: String
        var url: String?
        var hash: String?
        var post: Quoted?
        // An image: its size, and signed links to its display size and the file itself.
        var width: Int?
        var height: Int?
        var src: String?
        var full: String?
        /// A link: what the network read from the page, once it has.
        var preview: Preview?
    }

    let hash: String
    let fid: UInt64
    let time: Int64
    let text: String
    let mentions: [Mention]
    let parent: String?
    /// Who wrote the post a reply answers. A network from before replies showed in the feed sends none.
    var parentFid: UInt64?
    let embeds: [Embed]
    let replies: Int
    let likes: Int
    let liked: Bool
    let deleted: Bool

    var id: String { hash }
}

struct NetworkMember: Codable, Hashable, Identifiable, Sendable {
    let fid: UInt64
    let username: String
    let displayName: String
    let bio: String
    let role: String
    let joined: Int64
    let muted: Bool
    /// A signed link to their picture's thumb size.
    var avatar: String?
    /// Whether the picture was uploaded to this network, rather than copied from Farcaster.
    var ownAvatar: Bool?

    var id: UInt64 { fid }
    /// How a member shows: their username, bare, as Farcaster names show. One without a username is "!" and their ID.
    var handle: String { username }
}

struct NetworkInfo: Codable, Sendable {
    let name: String
    /// A link to the network's picture, which changes with it, or nil.
    var icon: String?
    let retention: String
    let you: NetworkMember
}

struct NetworkActivity: Codable, Sendable {
    /// Someone who liked your post, as the network names them.
    struct Liker: Codable, Hashable, Sendable {
        let fid: UInt64
        let username: String
    }

    struct Item: Codable, Hashable, Identifiable, Sendable {
        let kind: String
        let post: NetworkPost
        /// For a reply, the post it answers. For a like on your reply, the post your reply answers.
        var parent: NetworkPost?
        /// For a like: up to 3 of the newest likers, newest first, how many liked the post, and when
        /// the newest like was.
        var likers: [Liker]?
        var count: Int?
        var time: Int64?

        /// The post whose replies this item belongs with: the answered post for a reply.
        var threadRoot: NetworkPost { parent ?? post }
        var isLike: Bool { kind == "like" }
        /// When it happened: the newest like for a like, or the post's own time.
        var when: Int64 { isLike ? time ?? post.time : post.time }
        /// A post can be in the list once as a reply or mention and once for its likes. A like's row
        /// changes with each new like, so it's a new row then: kept, it showed the likers from before.
        var id: String { isLike ? "like \(post.hash) \(when) \(count ?? 0)" : "\(kind) \(post.hash)" }
    }

    let items: [Item]
}

extension NetworkActivity.Item {
    /// A like's own fields that can't be read are left out, so that like is dropped (`fitsLimits`)
    /// rather than the whole of Activity.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        post = try container.decode(NetworkPost.self, forKey: .post)
        parent = try container.decodeIfPresent(NetworkPost.self, forKey: .parent)
        likers = try? container.decodeIfPresent([NetworkActivity.Liker].self, forKey: .likers)
        count = try? container.decodeIfPresent(Int.self, forKey: .count)
        time = try? container.decodeIfPresent(Int64.self, forKey: .time)
    }

    /// Within what an honest network sends. A like names 1 to 3 likers, newest first, out of a count
    /// no smaller than that and no larger than a network's members.
    var fitsLimits: Bool {
        guard NetworkLimits.fits(kind, 16), post.fitsLimits, parent?.fitsLimits != false else { return false }
        guard isLike else { return true }
        guard let likers, let count, time != nil, (1...NetworkLimits.likers).contains(likers.count),
              (likers.count...NetworkLimits.members).contains(count) else { return false }
        return likers.allSatisfy { NetworkLimits.fits($0.username, NetworkLimits.usernameBytes) }
    }
}

/// The most an honest network sends, from docs/NETWORK.md, checked as each answer arrives. A post
/// or member past them is dropped and lists are cut short, so a server can't have the app lay out
/// megabytes of text or start thousands of downloads.
enum NetworkLimits {
    static let textBytes = 1024
    static let mentions = 10
    static let linkBytes = 256
    /// Signed picture links and the network's icon, which run longer than links in posts.
    static let addressBytes = 2048
    /// Previews are 300 characters at most, which is at most this many bytes.
    static let previewBytes = 1200
    static let hashBytes = 128
    static let usernameBytes = 64
    static let displayNameBytes = 512
    static let bioBytes = 2048
    /// A page of the feed or of activity.
    static let page = 100
    static let replies = 1000
    static let members = 10_000
    /// The newest likers a like in Activity names.
    static let likers = 3

    static func fits(_ text: String?, _ bytes: Int) -> Bool { (text?.utf8.count ?? 0) <= bytes }
}

extension NetworkPost {
    var fitsLimits: Bool {
        NetworkLimits.fits(text, NetworkLimits.textBytes) && NetworkLimits.fits(hash, NetworkLimits.hashBytes)
            && NetworkLimits.fits(parent, NetworkLimits.hashBytes) && mentions.count <= NetworkLimits.mentions
            && mentions.allSatisfy { NetworkLimits.fits($0.username, NetworkLimits.usernameBytes) }
            && embeds.count <= NetworkMessages.maxEmbeds && embeds.allSatisfy(\.fitsLimits)
    }

    /// The posts that fit, from the first `limit`.
    static func kept(_ posts: [NetworkPost], limit: Int) -> [NetworkPost] {
        posts.prefix(limit).filter(\.fitsLimits)
    }
}

extension NetworkPost.Embed {
    var fitsLimits: Bool {
        NetworkLimits.fits(type, 16) && NetworkLimits.fits(url, NetworkLimits.linkBytes) && NetworkLimits.fits(hash, NetworkLimits.hashBytes)
            && NetworkLimits.fits(post?.text, NetworkLimits.textBytes) && NetworkLimits.fits(post?.hash, NetworkLimits.hashBytes)
            && NetworkLimits.fits(src, NetworkLimits.addressBytes) && NetworkLimits.fits(full, NetworkLimits.addressBytes)
            && NetworkLimits.fits(preview?.title, NetworkLimits.previewBytes)
            && NetworkLimits.fits(preview?.description, NetworkLimits.previewBytes)
            && NetworkLimits.fits(preview?.image, NetworkLimits.addressBytes)
    }
}

extension NetworkMember {
    var fitsLimits: Bool {
        NetworkLimits.fits(username, NetworkLimits.usernameBytes) && NetworkLimits.fits(displayName, NetworkLimits.displayNameBytes)
            && NetworkLimits.fits(bio, NetworkLimits.bioBytes) && NetworkLimits.fits(role, 16)
            && NetworkLimits.fits(avatar, NetworkLimits.addressBytes)
    }
}

enum NetworkError: LocalizedError, Equatable {
    case server(status: Int, message: String)
    case unreachable
    case refused
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .server(_, let message): message
        case .unreachable: "Couldn’t reach the network."
        case .refused: "You’re not a member of this network."
        case .notSignedIn: "Sign in to this network again."
        }
    }
}

/// Farcaster's ID registry on Optimism, read directly, so no server can say who owns an FID.
enum Optimism {
    /// Public Optimism RPCs, tried in order, since any one can turn requests away for a while.
    private static var rpcs: [URL] {
        #if DEBUG
        // `npm run demo -- --app` prints a stand-in for Optimism, so a local demo network can be joined.
        if let local = ProcessInfo.processInfo.environment["FATLINE_OPTIMISM_URL"], let url = URL(string: local) { return [url] }
        #endif
        return ["https://mainnet.optimism.io", "https://optimism-rpc.publicnode.com", "https://optimism.drpc.org"].compactMap(URL.init(string:))
    }
    private static let idRegistry = "0x00000000Fc6c5F01Fc30151999387Bb99A9f489b"

    /// The FID an address owns, or nil.
    static func fid(owning address: String) async throws -> UInt64? {
        for rpc in rpcs {
            do {
                return try await fid(owning: address, rpc: rpc)
            } catch {
                continue
            }
        }
        throw NetworkError.server(status: 0, message: "Couldn’t reach Optimism to look up your account.")
    }

    private static func fid(owning address: String, rpc: URL) async throws -> UInt64? {
        let argument = String(repeating: "0", count: 24) + address.lowercased().dropFirst(2)
        var request = URLRequest(url: rpc, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "eth_call",
            "params": [["to": idRegistry, "data": "0xd94fe832" + argument], "latest"]
        ])
        let (data, response) = try await HTTP.loadResponse(request)
        struct Answer: Decodable { let result: String? }
        guard response.statusCode == 200, let result = try JSONDecoder().decode(Answer.self, from: data).result,
              let value = UInt64(result.dropFirst(2).suffix(16), radix: 16) else {
            throw NetworkError.server(status: response.statusCode, message: "Couldn’t reach Optimism to look up your account.")
        }
        return value == 0 ? nil : value
    }
}

/// What `GET /invites/{code}` says: the network's name and picture link, as it gives them.
struct NetworkInvite: Decodable, Hashable, Sendable {
    let name: String?
    let icon: String?

    init(name: String?, icon: String?) {
        self.name = name
        self.icon = icon
    }

    init(data: Data) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw NetworkError.server(status: 0, message: "The network sent something Fatline couldn’t read.")
        }
    }
}

/// Talks to one network's server as this device.
/// Network reads kept in memory with their ETags, by address, for `If-None-Match`. An unchanged feed
/// then costs the network one database row and sends nothing back. A network's answers name the
/// viewer and change at least each hour, as its picture links do.
final class NetworkAnswers: @unchecked Sendable {
    struct Kept {
        let etag: String
        let data: Data
    }

    static let shared = NetworkAnswers()
    /// Each network's feed and activity, plus the threads opened lately.
    static let limit = 64

    private let lock = NSLock()
    private var kept: [String: Kept] = [:]
    /// Least recently used first.
    private var order: [String] = []

    func answer(_ address: String) -> Kept? {
        lock.withLock {
            guard let found = kept[address] else { return nil }
            order.removeAll { $0 == address }
            order.append(address)
            return found
        }
    }

    func keep(_ address: String, etag: String, data: Data) {
        lock.withLock {
            kept[address] = Kept(etag: etag, data: data)
            order.removeAll { $0 == address }
            order.append(address)
            while order.count > Self.limit { kept[order.removeFirst()] = nil }
        }
    }

    func forget(_ address: String) {
        lock.withLock {
            kept[address] = nil
            order.removeAll { $0 == address }
        }
    }
}

struct NetworkClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let membership: NetworkMembership
    /// How requests go out: the shared HTTP session, or a stand-in in tests.
    var transport: Transport = { try await HTTP.loadResponse($0) }
    /// How long a read that dropped waits before going again.
    var retryDelay: Duration = .seconds(2)
    /// Reads kept with their ETag, so asking again sends `If-None-Match` and an unchanged page comes
    /// back as a `304` with nothing in it.
    var answers: NetworkAnswers = .shared

    private var base: URL { NetworkMessages.origin(membership.host).appending(path: "api/v1") }

    // MARK: Joining and signing in

    /// Asks to join. The Farcaster picture isn't sent: once signed in, the app uploads it itself
    /// (`setFarcasterPicture`), so the network fetches nothing.
    /// `push` is where this device hears from the network, so a waiting request hears it's in. A
    /// network that won't use that relay turns the join down having changed nothing, so it goes again
    /// without `push`.
    static func join(host: String, device: NetworkDevice, invite: String?, push: PushTarget? = nil,
                     transport: @escaping Transport = { try await HTTP.loadResponse($0) }) async throws -> NetworkMembership {
        try await joinTellingPush(host: host, device: device, invite: invite, push: push, transport: transport).membership
    }

    /// `join`, and whether the network took `push`.
    static func joinTellingPush(host: String, device: NetworkDevice, invite: String?, push: PushTarget?,
                                transport: @escaping Transport = { try await HTTP.loadResponse($0) }) async throws -> (membership: NetworkMembership, pushTaken: Bool) {
        let key = Curve25519.Signing.PrivateKey()
        let issued = Int64(Date.now.timeIntervalSince1970)
        let text = NetworkMessages.networkKeyText(host: host, fid: device.fid, networkKey: key.publicKey.rawRepresentation, issued: issued)
        let approval = try device.signingKey.signature(for: Data(text.utf8)).hex
        var membership = NetworkMembership(host: host, fid: device.fid, key: key.rawRepresentation, issued: issued,
                                           approval: approval, status: .pending)
        var body = try joinBody(device: device, networkKey: key.publicKey.rawRepresentation, issued: issued, approval: approval)
        if let invite { body["invite"] = invite }
        let client = NetworkClient(membership: membership, transport: transport)
        let (status, taken) = try await client.sendJoin(body, push: push)
        membership.status = status
        return (membership, taken)
    }

    /// For a request that's waiting: the join again, with the same network key and `push`, so the
    /// network can say "You're in." once it lets you in (docs/NETWORK.md, "A join's push"). The key's
    /// approval is signed afresh, since the network takes one made in the last few minutes. True when the
    /// network took `push`.
    static func addPush(_ push: PushTarget, to membership: NetworkMembership, device: NetworkDevice,
                        transport: @escaping Transport = { try await HTTP.loadResponse($0) }) async throws -> Bool {
        let key = try membership.signingKey.publicKey.rawRepresentation
        let issued = Int64(Date.now.timeIntervalSince1970)
        let text = NetworkMessages.networkKeyText(host: membership.host, fid: device.fid, networkKey: key, issued: issued)
        let approval = try device.signingKey.signature(for: Data(text.utf8)).hex
        let body = try joinBody(device: device, networkKey: key, issued: issued, approval: approval)
        return try await NetworkClient(membership: membership, transport: transport).sendJoin(body, push: push).pushTaken
    }

    private static func joinBody(device: NetworkDevice, networkKey: Data, issued: Int64, approval: String) throws -> [String: Any] {
        [
            "fid": device.fid,
            "deviceKey": try device.signingKey.publicKey.rawRepresentation.hex,
            "deviceApproval": ["issuedAt": device.issuedAt, "signature": device.signature],
            "networkKey": networkKey.hex,
            "networkApproval": ["issued": issued, "signature": approval],
        ]
    }

    private func sendJoin(_ body: [String: Any], push: PushTarget?) async throws -> (status: NetworkMembership.Status, pushTaken: Bool) {
        struct Answer: Decodable { let status: NetworkMembership.Status }
        if let push {
            do {
                let answer: Answer = try await call("POST", "join", json: body.merging(["push": push.joinFields]) { $1 }, signedIn: false)
                return (answer.status, true)
            } catch NetworkError.server(status: 400, _) {}
        }
        let answer: Answer = try await call("POST", "join", json: body, signedIn: false)
        return (answer.status, false)
    }

    /// What a network's invite page shows for `code`, or nil when the network doesn't know the code.
    /// It sends nothing about this device or account, so the app can show it before anything is sent.
    static func invite(host: String, code: String) async throws -> NetworkInvite? {
        // Only the characters invite codes are made of, so a code can't reach another path.
        guard !code.isEmpty, code.count <= 128,
              code.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-._~".unicodeScalars.contains($0) })
        else { return nil }
        let nobody = NetworkMembership(host: host, fid: 0, key: Data(), issued: 0, approval: "", status: .pending)
        let (data, response) = try await NetworkClient(membership: nobody).send("GET", "invites/\(code)", token: nil)
        let status = response.statusCode
        switch status {
        case 200: return try NetworkInvite(data: data)
        case 404: return nil
        default: throw Self.error(status: status, data: data)
        }
    }

    /// Signs in once approved. Returns the membership with its new token, or its new status.
    func signIn() async throws -> NetworkMembership {
        var updated = membership
        let issued = Int64(Date.now.timeIntervalSince1970)
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).hex
        let text = NetworkMessages.sessionText(host: membership.host, fid: membership.fid, issued: issued, nonce: nonce)
        let signature = try membership.signingKey.signature(for: Data(text.utf8)).hex
        let body: [String: Any] = [
            "fid": membership.fid, "networkKey": try membership.signingKey.publicKey.rawRepresentation.hex,
            "issued": issued, "nonce": nonce, "signature": signature,
        ]
        let (data, response) = try await send("POST", "session", json: body, token: nil)
        let status = response.statusCode
        switch status {
        case 200:
            struct Session: Decodable { let token: String; let expires: Int64 }
            let session = try JSONDecoder().decode(Session.self, from: data)
            updated.status = .approved
            updated.wasApproved = true
            updated.token = session.token
            updated.expires = session.expires
        case 202: updated.status = .pending
        case 403: updated.status = .refused
        default: throw Self.error(status: status, data: data)
        }
        return updated
    }

    // MARK: Reading

    /// The network's name is held to 64 characters by `NetworkMembership.acceptedName`.
    func info() async throws -> NetworkInfo {
        var info: NetworkInfo = try await call("GET", "network")
        guard info.you.fitsLimits else { throw Self.unreadable }
        if !NetworkLimits.fits(info.icon, NetworkLimits.addressBytes) { info.icon = nil }
        return info
    }

    /// Posts and replies, newest first. A network from before replies showed in the feed ignores the
    /// question and sends posts alone.
    func feed() async throws -> [NetworkPost] {
        struct Page: Decodable { let posts: [NetworkPost] }
        let page: Page = try await call("GET", "feed", query: [URLQueryItem(name: "replies", value: "1")])
        return NetworkPost.kept(page.posts, limit: NetworkLimits.page)
    }

    /// A post and its replies, oldest first. Replies come a page at a time, newest page first (200 to
    /// a page since round seven), so this follows `next` back for the older ones, up to the limit.
    func thread(_ hash: String) async throws -> (post: NetworkPost, replies: [NetworkPost]) {
        struct Thread: Decodable { let post: NetworkPost; let replies: [NetworkPost]; let next: String? }
        let thread: Thread = try await call("GET", "posts/\(hash)")
        guard thread.post.fitsLimits else { throw Self.unreadable }
        var replies = thread.replies
        var next = thread.next
        var seen: Set<String> = []
        while let cursor = next, replies.count < NetworkLimits.replies, seen.insert(cursor).inserted {
            let older: Thread = try await call("GET", "posts/\(hash)", query: [URLQueryItem(name: "cursor", value: cursor)])
            guard !older.replies.isEmpty else { break }
            replies = older.replies + replies
            next = older.next
        }
        return (thread.post, NetworkPost.kept(Array(replies.suffix(NetworkLimits.replies)), limit: NetworkLimits.replies))
    }

    /// Replies to you and mentions of you, newest first. With `likes`, likes on your posts and replies
    /// too, one item a post, placed by its newest like. Only iPhone shows likes so far, so only it asks.
    func activity(likes: Bool = false) async throws -> [NetworkActivity.Item] {
        let page: NetworkActivity = try await call("GET", "activity", query: likes ? [URLQueryItem(name: "likes", value: "1")] : [])
        return page.items.prefix(NetworkLimits.page).filter { $0.fitsLimits && (likes || !$0.isLike) }
    }

    func members() async throws -> [NetworkMember] {
        struct Members: Decodable { let members: [NetworkMember] }
        let members: Members = try await call("GET", "members")
        return members.members.prefix(NetworkLimits.members).filter(\.fitsLimits)
    }

    // MARK: Changing

    /// With `readsLinks`, this app reads the post's links itself and sends what it found
    /// (`sendPreviews`), so the network reads none of them.
    func submit(_ message: SnapchainMessage, readsLinks: Bool = false) async throws {
        struct Answer: Decodable { let hash: String }
        let _: Answer = try await call("POST", "messages", bytes: message.bytes,
                                       headers: readsLinks ? [Self.previewsHeader: "app"] : [:])
    }

    static let previewsHeader = "fatline-previews"

    /// What this app read from one of a post's links, with the picture uploaded first.
    struct LinkPreviewUpload: Equatable, Sendable {
        let url: String
        var title: String?
        var description: String?
        /// An uploaded picture's ID.
        var image: String?

        var isEmpty: Bool { title == nil && description == nil && image == nil }
    }

    /// The previews of a post's own links, which only its author can send.
    func sendPreviews(_ hash: String, _ previews: [LinkPreviewUpload]) async throws {
        let list: [[String: String]] = previews.map { preview in
            var item = ["url": preview.url]
            if let title = preview.title { item["title"] = title }
            if let description = preview.description { item["description"] = description }
            if let image = preview.image { item["image"] = image }
            return item
        }
        try await expectNoContent("PUT", "posts/\(hash)/previews", json: ["previews": list])
    }

    func adminLink() async throws -> URL {
        struct Answer: Decodable { let url: String }
        let answer: Answer = try await call("POST", "admin-link")
        guard let url = URL(string: answer.url), url.host() == NetworkMessages.origin(membership.host).host() else {
            throw NetworkError.server(status: 0, message: "The network sent a link somewhere else.")
        }
        return url
    }

    func leave() async throws {
        try await expectNoContent("POST", "leave")
    }

    /// Ends the session this token belongs to, and no other. The device keeps its keys.
    func endSession() async throws {
        try await expectNoContent("DELETE", "session")
    }

    func mute(_ fid: UInt64, _ muted: Bool) async throws {
        try await expectNoContent(muted ? "PUT" : "DELETE", "mutes/\(fid)")
    }

    func report(_ hash: String, note: String) async throws {
        try await expectNoContent("POST", "reports", json: ["post": hash, "note": note])
    }

    // MARK: Notifications

    /// `PUT /me/push`: where and what this device hears, for the network key this session signed in with.
    func setPush(_ target: PushTarget) async throws {
        try await expectNoContent("PUT", "me/push", json: target.pushFields)
    }

    /// `DELETE /me/push`: this device hears nothing more from this network.
    func removePush() async throws {
        try await expectNoContent("DELETE", "me/push")
    }

    /// `POST /me/push/test`: a test notification to this device, sent at once, and what the relay said.
    /// A network whose server is older than test notifications answers 404 without the `no-push` code.
    func testPush() async throws -> PushTestAnswer {
        if membership.token == nil { throw NetworkError.notSignedIn }
        let (data, response) = try await send("POST", "me/push/test", token: membership.token)
        struct Code: Decodable { let code: String? }
        if response.statusCode == 404, (try? JSONDecoder().decode(Code.self, from: data))?.code != "no-push" {
            throw NetworkError.server(status: 404, message: "This network can’t send test notifications yet.")
        }
        guard response.statusCode == 200 else { throw Self.error(status: response.statusCode, data: data) }
        guard let answer = try? JSONDecoder().decode(PushTestAnswer.self, from: data) else { throw Self.unreadable }
        return answer
    }

    /// `PUT /me/seen`: the newest post this member has had on screen, by its time, so twice-a-day
    /// summaries leave out what was read, on whichever device.
    func setSeen(_ time: Int64) async throws {
        try await expectNoContent("PUT", "me/seen", json: ["time": time])
    }

    func updateProfile(displayName: String, bio: String) async throws -> NetworkMember {
        try Self.fitting(await call("PATCH", "me", json: ["displayName": displayName, "bio": bio]))
    }

    /// An uploaded picture's ID, or "farcaster" to go back to the Farcaster picture.
    func setAvatar(_ avatar: String) async throws -> NetworkMember {
        try Self.fitting(await call("PATCH", "me", json: ["avatar": avatar]))
    }

    /// The Farcaster picture, which this app downloaded and uploaded (`upload`), so the network
    /// needn't fetch it.
    func setFarcasterPicture(_ id: String) async throws -> NetworkMember {
        try Self.fitting(await call("PATCH", "me", json: ["farcasterPicture": id]))
    }

    private static func fitting(_ member: NetworkMember) throws -> NetworkMember {
        guard member.fitsLimits else { throw unreadable }
        return member
    }

    struct Uploaded: Decodable, Sendable {
        let id: String
        let url: String

        private static let idCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

        /// Whether `url` is the network's own `https://<host>/m/<id>` address for this picture. A post
        /// carries it signed with the user's key, so a server mustn't choose a link of its own.
        func isOwnLink(on host: String) -> Bool {
            (1...64).contains(id.count) && id.allSatisfy(Self.idCharacters.contains) && url == "https://\(host)/m/\(id)"
        }
    }

    func upload(_ data: Data, type: String) async throws -> Uploaded {
        let uploaded: Uploaded = try await call("POST", "media", bytes: data, contentType: type)
        guard uploaded.isOwnLink(on: membership.host) else {
            throw NetworkError.server(status: 0, message: "The network sent a picture link that isn’t its own.")
        }
        return uploaded
    }

    /// Admins only: how many people are waiting to join.
    func waitingRequests() async throws -> Int {
        struct Request: Decodable { let status: String }
        struct Requests: Decodable { let requests: [Request] }
        let answer: Requests = try await call("GET", "admin/requests")
        return answer.requests.filter { $0.status == "pending" }.count
    }

    // MARK: Requests

    private func expectNoContent(_ method: String, _ path: String, json: [String: Any]? = nil) async throws {
        if membership.token == nil { throw NetworkError.notSignedIn }
        let (data, response) = try await send(method, path, json: json, token: membership.token)
        guard (200..<300).contains(response.statusCode) else { throw Self.error(status: response.statusCode, data: data) }
    }

    private func call<Answer: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil,
                                         bytes: Data? = nil, contentType: String? = nil, headers: [String: String] = [:],
                                         signedIn: Bool = true) async throws -> Answer {
        if signedIn && membership.token == nil { throw NetworkError.notSignedIn }
        // A signed-in read is kept by its address, for this account on this network.
        let address = method == "GET" && signedIn ? "\(membership.fid)@\(membership.host)/\(path)?\(query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&"))" : nil
        let kept = address.flatMap(answers.answer)
        var headers = headers
        if let kept { headers["if-none-match"] = kept.etag }
        let (sent, response) = try await send(method, path, query: query, json: json, bytes: bytes, contentType: contentType,
                                              headers: headers, token: signedIn ? membership.token : nil)
        let data: Data
        if response.statusCode == 304, let kept {
            // Unchanged since the kept copy, which the network didn't send again.
            data = kept.data
        } else if (200..<300).contains(response.statusCode) {
            data = sent
        } else {
            throw Self.error(status: response.statusCode, data: sent)
        }
        let answer: Answer
        do {
            answer = try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            if let address { answers.forget(address) }
            throw Self.unreadable
        }
        if let address, response.statusCode == 200, let etag = response.value(forHTTPHeaderField: "etag") {
            answers.keep(address, etag: etag, data: data)
        }
        return answer
    }

    private static let unreadable = NetworkError.server(status: 0, message: "The network sent something Fatline couldn’t read.")

    /// Which app and version this is, such as `mac/0.3.91`, so a network can ask old builds to update.
    static let appHeader: String = {
        #if os(macOS)
        let platform = "mac"
        #else
        let platform = "iphone"
        #endif
        return "\(platform)/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")"
    }()

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil, bytes: Data? = nil,
                      contentType: String? = nil, headers: [String: String] = [:], token: String?) async throws -> (Data, HTTPURLResponse) {
        let url = base.appending(path: path)
        var request = URLRequest(url: query.isEmpty ? url : url.appending(queryItems: query), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: bytes.map { $0.count > 1_000_000 ? 120 : 30 } ?? 30)
        request.httpMethod = method
        request.setValue(Self.appHeader, forHTTPHeaderField: "fatline-app")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let bytes {
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "content-type")
            request.httpBody = bytes
        }
        do {
            return try await deliver(request)
        } catch {
            // A request the app called off, such as when a screen closes, isn't the network being down.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw NetworkError.unreachable
        }
    }

    /// Errors where a request never got to the network, as the first one after the app comes back often doesn't.
    private static let dropped: Set<URLError.Code> = [.networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                                                      .cannotFindHost, .dnsLookupFailed]

    /// Sends a read once more, shortly, if it dropped on the way. Writes go once, since the first may have arrived.
    private func deliver(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport(request)
        } catch let error as URLError where request.httpMethod == "GET" && Self.dropped.contains(error.code) {
            try await Task.sleep(for: retryDelay)
            return try await transport(request)
        }
    }

    private static func error(status: Int, data: Data) -> NetworkError {
        struct Problem: Decodable { let message: String?; let status: String? }
        let problem = try? JSONDecoder().decode(Problem.self, from: data)
        if status == 401 { return .notSignedIn }
        if status == 403, problem?.status == "refused" { return .refused }
        return .server(status: status, message: problem?.message ?? "The network answered \(status).")
    }
}

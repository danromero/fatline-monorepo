import CryptoKit
import Foundation

/// The Fatline networks this device belongs to, and the one being looked at. Farcaster is the
/// default, shown when no network is selected.
@MainActor
@Observable
final class NetworkModel {
    private static let selectedKey = "selectedNetwork" + DevProfile.suffix
    private static let seenPostsKey = "networkSeenPosts" + DevProfile.suffix
    private static let seenActivityKey = "networkSeenActivity" + DevProfile.suffix
    static let pollInterval: TimeInterval = 60
    /// How often a poll also reads members and the network's name and icon.
    static let slowPollInterval: TimeInterval = 10 * 60

    private(set) var device: NetworkDevice?
    private(set) var memberships: [NetworkMembership] = []
    /// Nil means Farcaster.
    private(set) var selectedHost: String?

    // The selected network's feed.
    private(set) var posts: [NetworkPost] = []
    private(set) var members: [NetworkMember] = []
    private(set) var loading = false
    /// When the read under way started, for Debug's check on a stuck read.
    @ObservationIgnored private(set) var readStarted: Date?
    /// The read under way, and the network it's reading.
    @ObservationIgnored private var reading: (host: String, task: Task<Void, Never>)?
    /// When the selected network's members and name were last read.
    @ObservationIgnored private var slowReadAt: Date?
    /// Authors in the feed who weren't in the last members list read, such as someone who left.
    @ObservationIgnored private var lookedUp: Set<UInt64> = []
    private(set) var problem: String?
    /// Reads that couldn't reach the network, so one dropped request doesn't put up the banner.
    @ObservationIgnored private var outage = NetworkOutage()
    /// The quick try again after a read that couldn't reach the network, while the banner waits.
    @ObservationIgnored private var retry: Task<Void, Never>?
    private(set) var lastRead: Date?
    /// You, as the selected network knows you.
    private(set) var you: NetworkMember?
    /// A confirmation, such as Sent. On iPhone it clears itself after a couple of seconds and is read out
    /// once, whichever screen is showing. The Mac's own toast view clears it.
    var toast: String? {
        didSet {
            #if os(iOS)
            toastTimer?.cancel()
            toastTimer = nil
            guard let toast else { return }
            Platform.announce(toast)
            toastTimer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(FatlineStyle.toastSeconds)) } catch { return }
                guard let self, self.toast == toast else { return }
                self.toast = nil
            }
            #endif
        }
    }
    #if os(iOS)
    @ObservationIgnored private var toastTimer: Task<Void, Never>?
    #endif

    /// Hosts whose Farcaster picture was tried this launch, so a picture that can't be read isn't
    /// downloaded again at every refresh. One that failed is tried again next launch.
    @ObservationIgnored private var picturesTried: Set<String> = []

    // What's new, by host: the newest post by someone else and the newest activity, against the
    // newest of each that was on screen. Seen times are kept, so a dot survives quitting.
    private var newestPost: [String: Int64] = [:]
    private var newestActivity: [String: Int64] = [:]
    private var seenPosts: [String: Int64] = UserDefaults.standard.dictionary(forKey: seenPostsKey) as? [String: Int64] ?? [:]
    private var seenActivity: [String: Int64] = UserDefaults.standard.dictionary(forKey: seenActivityKey) as? [String: Int64] ?? [:]
    /// How many replies and mentions in each network came after the newest Activity showed, for the
    /// count on iPhone's Activity tab. Known only after a read of Activity's list.
    private var unseenActivity: [String: Int] = [:]

    init() {
        #if DEBUG
        // `-FatlineForgetNetworks YES` starts with no networks and no device key, for testing.
        if UserDefaults.standard.bool(forKey: "FatlineForgetNetworks") {
            Self.forgetAll()
            seenPosts = [:]
            seenActivity = [:]
        }
        #endif
        device = try? NetworkKeychain.device.load()
        #if DEBUG
        // `-FatlineDeviceKeyFile path` uses a made-up account's key from `npm run demo`, in place of its phrase.
        if device == nil, let path = UserDefaults.standard.string(forKey: "FatlineDeviceKeyFile"), let loaded = Self.demoDevice(path) {
            try? NetworkKeychain.device.save(loaded)
            device = loaded
        }
        #endif
        memberships = (try? NetworkKeychain.memberships.load()) ?? []
        let saved = UserDefaults.standard.string(forKey: Self.selectedKey)
        selectedHost = memberships.contains { $0.host == saved } ? saved : nil
    }

    var selected: NetworkMembership? { memberships.first { $0.host == selectedHost } }

    #if DEBUG
    /// The device part of a key file the network folder's scripts write.
    private static func demoDevice(_ path: String) -> NetworkDevice? {
        struct KeyFile: Decodable {
            struct Device: Decodable { let secret: String; let issuedAt: Int64; let signature: String }
            let fid: UInt64
            let custody: String
            let device: Device
        }
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(KeyFile.self, from: data),
              let key = Data(hex: file.device.secret)
        else { return nil }
        return NetworkDevice(fid: file.fid, custody: file.custody.lowercased(), key: key,
                             issuedAt: file.device.issuedAt, signature: file.device.signature)
    }
    #endif

    func select(_ host: String?) {
        guard host != selectedHost else { return }
        selectedHost = host
        UserDefaults.standard.set(host, forKey: Self.selectedKey)
        posts = []
        members = []
        you = nil
        problem = nil
        outage = NetworkOutage()
        retry?.cancel()
        retry = nil
        lastRead = nil
        slowReadAt = nil
        lookedUp = []
    }

    // MARK: What's new

    /// Replies to you and mentions of you that the selected network has and Activity hasn't shown.
    var hasNewActivity: Bool {
        guard let host = selectedHost else { return false }
        return (newestActivity[host] ?? 0) > (seenActivity[host] ?? .max)
    }

    /// How many of those there are: at least 1 while there's news, 0 without.
    var newActivityCount: Int {
        guard hasNewActivity, let host = selectedHost else { return 0 }
        return max(1, unseenActivity[host] ?? 0)
    }

    /// New posts or activity in a network that isn't showing.
    func hasNews(_ host: String) -> Bool {
        guard host != selectedHost else { return false }
        return (newestPost[host] ?? 0) > (seenPosts[host] ?? .max) || (newestActivity[host] ?? 0) > (seenActivity[host] ?? .max)
    }

    /// Whether any network other than the one showing has something new.
    var othersHaveNews: Bool { memberships.contains { $0.status == .approved && hasNews($0.host) } }

    /// The newest reply or mention Activity has shown for the selected network. Anything after it is new.
    var activitySeen: Int64? { selectedHost.flatMap { seenActivity[$0] } }

    func markActivitySeen() {
        guard let host = selectedHost, let newest = newestActivity[host] else { return }
        seenActivity[host] = newest
        unseenActivity[host] = 0
        UserDefaults.standard.set(seenActivity, forKey: Self.seenActivityKey)
    }

    /// Records what a network has. The first look at a network counts as seen, so joining shows no dots.
    /// Without `activity`, as after a read of the feed alone, what's known about Activity stays.
    private func note(_ host: String, posts: [NetworkPost], activity: [NetworkActivity.Item]? = nil, fid: UInt64) {
        let newestPost = posts.first { $0.fid != fid }?.time ?? 0
        self.newestPost[host] = newestPost
        if host == selectedHost || seenPosts[host] == nil { seenPosts[host] = max(newestPost, posts.first?.time ?? 0) }
        UserDefaults.standard.set(seenPosts, forKey: Self.seenPostsKey)
        guard let activity else { return }
        let newestActivity = activity.first?.post.time ?? 0
        self.newestActivity[host] = newestActivity
        if seenActivity[host] == nil { seenActivity[host] = newestActivity }
        let seen = seenActivity[host] ?? .max
        unseenActivity[host] = activity.filter { $0.post.time > seen }.count
        UserDefaults.standard.set(seenActivity, forKey: Self.seenActivityKey)
    }

    /// Looks for news in the networks that aren't showing.
    func checkOthers() async {
        for membership in memberships where membership.status == .approved && membership.host != selectedHost {
            guard let (feed, activity) = try? await signedIn(membership.host, { client in
                async let feed = client.feed()
                async let activity = client.activity()
                return try await (feed, activity)
            }) else { continue }
            note(membership.host, posts: feed, activity: activity, fid: membership.fid)
        }
    }

    // MARK: Joining

    /// True until this device has a key, which the recovery phrase approves once.
    var needsPhrase: Bool { device == nil }

    /// Approves a key for this device with the recovery phrase, which isn't kept.
    func approveDevice(phrase: String) async throws {
        let signer = try RecoverySigner(phrase: phrase)
        guard let fid = try await Optimism.fid(owning: signer.address) else {
            throw NetworkError.server(status: 0, message: "No Farcaster account belongs to that recovery phrase.")
        }
        let key = Curve25519.Signing.PrivateKey()
        let issuedAt = Int64(Date.now.timeIntervalSince1970)
        let signature = try signer.approveDevice(fid: fid, key: key, issuedAt: issuedAt)
        let device = NetworkDevice(fid: fid, custody: signer.address.lowercased(), key: key.rawRepresentation,
                                   issuedAt: issuedAt, signature: signature)
        try NetworkKeychain.device.save(device)
        self.device = device
    }

    /// What joining a network came to, for the screen after it.
    struct JoinResult: Hashable, Sendable {
        let host: String
        let status: NetworkMembership.Status
        var name: String?
        var icon: String?
        var memberCount: Int?
    }

    /// Joins with an address or a `CODE@host` invite. Once in, it reads the network's name and size.
    /// `avatar` is a link to this account's Farcaster picture, when the app knows it. The join doesn't
    /// carry it: once signed in, this app uploads it, so the network fetches nothing.
    func join(typed: String, avatar: String? = nil) async throws -> JoinResult {
        guard let device else { throw NetworkError.notSignedIn }
        let (host, invite) = Self.parse(typed)
        guard let host else { throw NetworkError.server(status: 0, message: "Use the format server.example or CODE@server.example.") }
        var membership = try await NetworkClient.join(host: host, device: device, invite: invite)
        membership.farcasterPicture = avatar
        #if DEBUG
        // `-FatlineFarcasterPicture URL` stands in for a made-up demo account's Farcaster picture.
        membership.farcasterPicture = avatar ?? UserDefaults.standard.string(forKey: "FatlineFarcasterPicture")
        #endif
        if membership.status == .approved { membership = try await NetworkClient(membership: membership).signIn() }
        var result = JoinResult(host: host, status: membership.status)
        if membership.status == .approved {
            let client = NetworkClient(membership: membership)
            if let info = try? await client.info() {
                let name = NetworkMembership.acceptedName(info.name, host: host, others: memberships)
                membership.name = name
                membership.isAdmin = info.you.role == "admin"
                membership.icon = info.icon
                result.name = name
                result.icon = info.icon
            }
            result.memberCount = try? await client.members().count
        }
        try add(membership)
        // Behind the result, since the picture is an extra.
        if membership.status == .approved { Task { await sendFarcasterPicture(host) } }
        return result
    }

    /// Uploads the Farcaster picture a join left to send, once the network has let this account in.
    private func sendFarcasterPicture(_ host: String) async {
        guard let link = memberships.first(where: { $0.host == host && $0.status == .approved })?.farcasterPicture,
              !picturesTried.contains(host) else { return }
        picturesTried.insert(host)
        let sent = try? await signedIn(host) { await NetworkPreviews.sendFarcasterPicture(link, client: $0) }
        guard let member = sent ?? nil, var membership = memberships.first(where: { $0.host == host }), membership.farcasterPicture == link else { return }
        membership.farcasterPicture = nil
        _ = try? update(membership)
        if host == selectedHost {
            you = member
            await refresh()
        }
    }

    /// For a network that's waiting on the admin: asks whether they've decided.
    func checkAgain(_ host: String) async {
        guard let membership = memberships.first(where: { $0.host == host }) else { return }
        do {
            let updated = try await NetworkClient(membership: membership).signIn()
            guard try update(updated) else { return }
            if updated.status == .approved {
                await refresh()
                await sendFarcasterPicture(host)
            }
        } catch is CancellationError {
            return
        } catch {
            problem = error.localizedDescription
        }
    }

    #if DEBUG
    /// `-FatlineJoin "CODE@host,host"` joins those networks at launch, for trying a build with a demo
    /// network's key file before it has a way to add one.
    func joinFromLaunch() async {
        guard let list = UserDefaults.standard.string(forKey: "FatlineJoin") else { return }
        for typed in list.split(separator: ",").map(String.init) {
            guard let host = Self.parse(typed).host, !memberships.contains(where: { $0.host == host }) else { continue }
            _ = try? await join(typed: typed)
        }
    }
    #endif

    /// Takes the address and code from `CODE@host`, or just the address.
    static func parse(_ typed: String) -> (host: String?, invite: String?) {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if let at = text.lastIndex(of: "@"), !text.hasPrefix("http") {
            let code = String(text[..<at])
            guard (1...128).contains(code.count), code.allSatisfy(codeCharacters.contains) else { return (nil, nil) }
            return (NetworkMessages.host(from: String(text[text.index(after: at)...])), code)
        }
        return (NetworkMessages.host(from: text), nil)
    }

    // MARK: Reading

    var isStale: Bool { lastRead.map { Date.now.timeIntervalSince($0) > Self.pollInterval } ?? true }

    /// Reads the selected network's feed, members, name, and activity. A read already under way for it
    /// is awaited rather than skipped or repeated. The read is its own task, so a caller that goes away,
    /// such as the poll restarting when the app comes forward, doesn't stop it halfway.
    func refresh() async {
        guard let host = selectedHost, let title = selected?.title, selected?.status == .approved else { return }
        if let reading, reading.host == host {
            await reading.task.value
            return
        }
        let task = Task { await read(host, title: title) }
        reading = (host, task)
        loading = true
        readStarted = .now
        await task.value
        guard reading?.task == task else { return }
        reading = nil
        loading = false
        readStarted = nil
    }

    private func read(_ host: String, title: String) async {
        let started = Date.now
        do {
            // Members and the network's name change rarely, and each read counts against a member's reads
            // a minute, so they're read every few minutes, or when someone not in the list shows up.
            let slow = slowReadAt.map { Date.now.timeIntervalSince($0) >= Self.slowPollInterval } ?? true
            let known = Set(members.map(\.fid)).union(lookedUp)
            let (feed, activity, info, fetched) = try await signedIn(host) { client in
                async let feed = client.feed()
                async let activity = client.activity()
                let info = slow ? try await client.info() : nil
                let members = slow ? try await client.members() : nil
                return try await (feed, activity, info, members)
            }
            var members = fetched
            let authors = Set(feed.map(\.fid) + activity.flatMap { [$0.post.fid] + ($0.parent.map { [$0.fid] } ?? []) })
            if members == nil, !authors.isSubset(of: known) {
                members = try await signedIn(host) { try await $0.members() }
            }
            LaunchLog.read(host: host, name: title, .done, "\(Int(Date.now.timeIntervalSince(started) * 1000)) ms")
            guard host == selectedHost else { return }
            CastImages.feedRead()
            posts = feed
            if let members {
                self.members = members
                // Someone who left still has posts here. Looked up once, they don't cause another read.
                lookedUp = authors.subtracting(members.map(\.fid))
            }
            if slow { slowReadAt = .now }
            lastRead = .now
            reached()
            note(host, posts: feed, activity: activity, fid: info?.you.fid ?? selected?.fid ?? 0)
            if let info {
                you = info.you
                let name = NetworkMembership.acceptedName(info.name, host: host, others: memberships)
                if var membership = selected,
                   membership.name != name || membership.isAdmin != (info.you.role == "admin") || membership.icon != info.icon {
                    membership.name = name
                    membership.isAdmin = info.you.role == "admin"
                    membership.icon = info.icon
                    _ = try? update(membership)
                }
            }
        } catch is CancellationError {
            LaunchLog.read(host: host, name: title, .cancelled, "Stopped before it finished")
            return
        } catch {
            LaunchLog.read(host: host, name: title, Task.isCancelled ? .cancelled : .failed, error.localizedDescription)
            guard host == selectedHost else { return }
            failed(error, started: started)
        }
    }

    /// For Debug's checks: `work` signed in to `host`, as the app's own reads are.
    func withClient<Result: Sendable>(_ host: String, _ work: @Sendable (NetworkClient) async throws -> Result) async throws -> Result {
        try await signedIn(host, work)
    }

    /// Reads the feed alone, after a post, like, or delete of yours, which change nothing else here.
    /// One read where `refresh` makes four, since a network allows each member only so many a minute.
    private func refreshFeed() async {
        guard let host = selectedHost, let membership = selected, membership.status == .approved else { return }
        let started = Date.now
        do {
            let feed = try await signedIn(host) { try await $0.feed() }
            guard host == selectedHost else { return }
            CastImages.feedRead()
            posts = feed
            reached()
            note(host, posts: feed, fid: membership.fid)
        } catch is CancellationError {
            return
        } catch {
            guard host == selectedHost else { return }
            failed(error, started: started)
        }
    }

    /// A read got through, so whatever was wrong is over.
    private func reached() {
        outage = NetworkOutage()
        retry?.cancel()
        retry = nil
        problem = nil
    }

    /// A read failed. What the network itself said shows at once. Not reaching it shows only once reads
    /// have kept failing for a few seconds; until then the posts stay as they are and it tries again soon.
    private func failed(_ error: any Error, started: Date) {
        guard error as? NetworkError == .unreachable else {
            outage = NetworkOutage()
            problem = error.localizedDescription
            return
        }
        if outage.failed(started: started) {
            problem = error.localizedDescription
        } else if retry == nil {
            retry = Task { [weak self] in
                do { try await Task.sleep(for: NetworkOutage.retryAfter) } catch { return }
                self?.retry = nil
                await self?.refresh()
            }
        }
    }

    func thread(_ hash: String) async throws -> (post: NetworkPost, replies: [NetworkPost]) {
        try await signedIn { try await $0.thread(hash) }
    }

    func activity() async throws -> [NetworkActivity.Item] {
        let items = try await signedIn { try await $0.activity() }
        if let host = selectedHost, let newest = items.first?.post.time {
            newestActivity[host] = max(newestActivity[host] ?? 0, newest)
        }
        markActivitySeen()
        return items
    }

    /// How a member shows: @username, or !fid without one.
    func handle(for fid: UInt64) -> String {
        members.first { $0.fid == fid }?.handle ?? "!\(fid)"
    }

    var ownFID: UInt64? { selected?.fid }

    /// A post in the shape the feed's rows take.
    func cast(for post: NetworkPost) -> FeedCast {
        // A link with a preview shows as a card, and one already in the text is a link there, so
        // neither shows again as a line under the text.
        let text = post.text.lowercased()
        let links = post.embeds.compactMap { $0.type == "link" && $0.preview == nil ? $0.url : nil }.filter { url in
            let bare = url.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression).lowercased()
            return !text.contains(url.lowercased()) && !text.contains(bare)
        }
        let quote = post.embeds.first { $0.type == "post" }?.post.map {
            FeedCast.Quote(fid: $0.fid, handle: handle(for: $0.fid), text: $0.text)
        }
        let images = post.embeds.compactMap { $0.type == "image" ? $0.src : nil }
        return FeedCast(hash: post.hash, fid: post.fid, time: post.time, text: post.text,
                        links: links.isEmpty ? nil : links, quote: quote,
                        avatar: members.first { $0.fid == post.fid }?.avatar,
                        images: images.isEmpty ? nil : images, mediaHost: selectedHost)
    }

    /// A link the network has read, for a card under the post.
    struct LinkCard: Identifiable, Hashable {
        let url: URL
        let title: String?
        let description: String?
        /// The page's picture, from the network's own host.
        let image: URL?

        var id: URL { url }
    }

    /// The post's links that have a title, description, or picture. Only HTTPS links open.
    func linkCards(for post: NetworkPost) -> [LinkCard] {
        post.embeds.compactMap { embed in
            guard embed.type == "link", let preview = embed.preview, let link = embed.url,
                  let url = URL(string: link), url.scheme == "https", url.host() != nil else { return nil }
            let image = preview.image.flatMap { image in selectedHost.flatMap { FeedCast.networkMediaURL(image, host: $0) } }
            guard preview.title != nil || preview.description != nil || image != nil else { return nil }
            return LinkCard(url: url, title: preview.title, description: preview.description, image: image)
        }
    }

    // MARK: Changing

    /// Posts, or replies when `parent` is set, to `host`, the network the composer opened on. Pictures
    /// go up first, then the post with up to two attachments, pictures before the link. Returns once the
    /// network has it. If another network is showing by now, nothing is sent and the draft stays, since
    /// its mentions name the members of the network it was written for.
    func post(to host: String, text: String, link: String? = nil, images: [NetworkImage] = [], parent: NetworkPost? = nil) async throws {
        guard let membership = memberships.first(where: { $0.host == host }) else { throw NetworkError.notSignedIn }
        guard host == selectedHost else {
            throw NetworkError.server(status: 0, message: "This post is for \(membership.title). Switch back to it to post.")
        }
        let handles = Dictionary(members.map { ($0.username.lowercased(), $0.fid) }, uniquingKeysWith: { first, _ in first })
        var embeds: [NetworkMessages.Embed] = []
        for image in images.prefix(NetworkMessages.maxEmbeds) {
            let (data, type) = (image.data, image.type)
            let uploaded = try await signedIn(membership.host) { try await $0.upload(data, type: type) }
            embeds.append(.link(uploaded.url))
        }
        let links = link.flatMap { embeds.count < NetworkMessages.maxEmbeds ? [$0] : nil } ?? []
        embeds += links.map(NetworkMessages.Embed.link)
        let message = try NetworkMessages.post(fid: membership.fid, text: text, handles: handles, embeds: embeds,
                                               parent: parent.map { ($0.fid, $0.hash) }, key: membership.signingKey)
        // The network it was signed for, even if another was chosen while pictures went up. With a
        // link, this app reads the page itself and the network reads nothing.
        try await signedIn(membership.host) { try await $0.submit(message, readsLinks: !links.isEmpty) }
        toast = parent == nil ? "Sent" : "Replied"
        // The post is in. The composer closes now, and the feed catches up behind it, then again once
        // the link's preview is there. A preview that fails leaves the post as it is.
        Task { await refreshFeed() }
        guard !links.isEmpty else { return }
        let hash = message.hash
        Task {
            _ = try? await signedIn(host) { await NetworkPreviews.send(links: links, hash: hash, client: $0) }
            if host == selectedHost { await refreshFeed() }
        }
    }

    func toggleLike(_ post: NetworkPost) async {
        guard let membership = selected else { return }
        do {
            let message = try NetworkMessages.like(!post.liked, fid: membership.fid, target: (post.fid, post.hash), key: membership.signingKey)
            try await signedIn(membership.host) { try await $0.submit(message) }
            await refreshFeed()
        } catch is CancellationError {
            return
        } catch {
            problem = error.localizedDescription
        }
    }

    func delete(_ post: NetworkPost) async throws {
        guard let membership = selected else { return }
        let message = try NetworkMessages.removal(fid: membership.fid, target: post.hash, key: membership.signingKey)
        try await signedIn(membership.host) { try await $0.submit(message) }
        toast = "Deleted"
        await refreshFeed()
    }

    func adminLink() async throws -> URL {
        try await signedIn { try await $0.adminLink() }
    }

    func waitingRequests() async throws -> Int {
        try await signedIn { try await $0.waitingRequests() }
    }

    func setMuted(_ fid: UInt64, _ muted: Bool) async throws {
        try await signedIn { try await $0.mute(fid, muted) }
        toast = "\(muted ? "Muted" : "Unmuted") \(handle(for: fid))"
        await refresh()
    }

    func isMuted(_ fid: UInt64) -> Bool { members.first { $0.fid == fid }?.muted ?? false }

    func report(_ post: NetworkPost, note: String) async throws {
        try await signedIn { try await $0.report(post.hash, note: note) }
        toast = "Reported"
    }

    func updateProfile(displayName: String, bio: String) async throws {
        you = try await signedIn { try await $0.updateProfile(displayName: displayName, bio: bio) }
        await refresh()
    }

    /// Uploads a picture for this network only, or with nil goes back to the Farcaster one.
    func setAvatar(_ image: NetworkImage?) async throws {
        guard let host = selectedHost else { return }
        let avatar: String
        if let image {
            let (data, type) = (image.data, image.type)
            avatar = try await signedIn(host) { try await $0.upload(data, type: type) }.id
        } else {
            avatar = "farcaster"
        }
        you = try await signedIn(host) { try await $0.setAvatar(avatar) }
        await refresh()
    }

    // MARK: Post links

    /// A post link that arrived, until its network's screen opens the post. A link to a network this
    /// device isn't in waits here while Add Network runs, with the address filled in.
    private(set) var linkedPost: PostLink?

    /// What a link asks the screens to do.
    enum LinkTarget: Equatable {
        /// Switched to the post's network, which opens it.
        case post
        /// Not a member there: Add Network, with the address filled in.
        case join
    }

    /// Takes a `fatline://open` link or a post's own `https://<host>/p/<hash>` address.
    func open(_ url: URL) -> LinkTarget? {
        guard let link = PostLink(url) else { return nil }
        linkedPost = link
        guard memberships.contains(where: { $0.host == link.host }) else { return .join }
        select(link.host)
        return .post
    }

    /// The post a link asked for, when `host`'s screen is the one showing. It stays until
    /// `linkedPostOpened`, so a screen that goes away midway leaves it for the next.
    func linkedPost(in host: String) -> PostLink? {
        linkedPost?.host == host ? linkedPost : nil
    }

    /// The link's post showed, or turned out not to be there.
    func linkedPostOpened(_ link: PostLink) {
        if linkedPost == link { linkedPost = nil }
    }

    /// Add Network closed. A link to a network that still isn't joined is dropped, so it doesn't open
    /// later by surprise.
    func addNetworkClosed() {
        guard let link = linkedPost, !memberships.contains(where: { $0.host == link.host }) else { return }
        linkedPost = nil
    }

    /// The post a link opens: the post itself, or for a reply, the post it answers, as the feed does.
    func linkedThread(_ hash: String) async throws -> NetworkPost {
        let post = try await thread(hash).post
        guard let parent = post.parent else { return post }
        return try await thread(parent).post
    }

    /// The address that opens a post, for sharing with other members.
    func link(for post: NetworkPost) -> URL? {
        guard let host = selectedHost else { return nil }
        return NetworkMessages.origin(host).appending(path: "p/\(post.hash)")
    }

    func leave() async throws {
        guard let membership = selected else { return }
        try await signedIn(membership.host) { try await $0.leave() }
        // Leaving ended every session there already.
        remove(membership.host)
    }

    /// Forgets every network and this device's key, so the next network asks for a recovery phrase,
    /// perhaps another account's. Each network's session ends, but the networks still list this
    /// device until someone leaves them.
    func forgetEverything() {
        Self.endSessions(memberships)
        Self.forgetAll()
        device = nil
        memberships = []
        forgetSeen()
        select(nil)
    }

    private static func forgetAll() {
        try? NetworkKeychain.memberships.remove()
        try? NetworkKeychain.device.remove()
        for key in [selectedKey, seenPostsKey, seenActivityKey] { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// What was seen in one network, or in all of them, so joining again shows no dots, as joining does.
    private func forgetSeen(_ host: String? = nil) {
        for keyPath in [\NetworkModel.newestPost, \.newestActivity, \.seenPosts, \.seenActivity] {
            if let host { self[keyPath: keyPath][host] = nil } else { self[keyPath: keyPath] = [:] }
        }
        if let host { unseenActivity[host] = nil } else { unseenActivity = [:] }
        UserDefaults.standard.set(seenPosts, forKey: Self.seenPostsKey)
        UserDefaults.standard.set(seenActivity, forKey: Self.seenActivityKey)
    }

    /// Takes a network off this device, for one that refused or is gone. Its session ends, but the
    /// network still lists this device.
    func forget(_ host: String) {
        Self.endSessions(memberships.filter { $0.host == host })
        remove(host)
    }

    private func remove(_ host: String) {
        memberships.removeAll { $0.host == host }
        try? NetworkKeychain.memberships.save(memberships)
        forgetSeen(host)
        if selectedHost == host { select(nil) }
    }

    /// Ends these memberships' sessions on their networks, without waiting and whatever the answer,
    /// since they're being forgotten anyway. The tokens stop working even if a copy of one survives.
    private static func endSessions(_ ending: [NetworkMembership]) {
        for membership in ending where membership.token != nil {
            Task { try? await NetworkClient(membership: membership).endSession() }
        }
    }

    // MARK: Plumbing

    /// Adds a membership, or replaces one for the same host. Only joining adds.
    private func add(_ membership: NetworkMembership) throws {
        if let index = memberships.firstIndex(where: { $0.host == membership.host }) {
            memberships[index] = membership
        } else {
            memberships.append(membership)
        }
        try NetworkKeychain.memberships.save(memberships)
    }

    /// Saves a change to a membership in place. Returns false, saving nothing, if it was forgotten while
    /// a request was under way, or forgotten and joined again with a new key, so it stays forgotten.
    @discardableResult
    private func update(_ membership: NetworkMembership) throws -> Bool {
        guard let index = memberships.firstIndex(where: { $0.host == membership.host && $0.key == membership.key }) else { return false }
        memberships[index] = membership
        try NetworkKeychain.memberships.save(memberships)
        return true
    }

    /// Runs `work` signed in to a network, the selected one unless another is named, signing in
    /// again once if the session ended.
    private func signedIn<Result: Sendable>(_ host: String? = nil, _ work: @Sendable (NetworkClient) async throws -> Result) async throws -> Result {
        guard var membership = memberships.first(where: { $0.host == (host ?? selectedHost) }) else { throw NetworkError.notSignedIn }
        if membership.token == nil || (membership.expires ?? 0) < Int64(Date.now.timeIntervalSince1970) + 60 {
            membership = try await NetworkClient(membership: membership).signIn()
            guard try update(membership) else { throw NetworkError.notSignedIn }
        }
        guard membership.status == .approved else { throw membership.status == .refused ? NetworkError.refused : NetworkError.notSignedIn }
        do {
            return try await work(NetworkClient(membership: membership))
        } catch NetworkError.notSignedIn {
            membership = try await NetworkClient(membership: membership).signIn()
            guard try update(membership) else { throw NetworkError.notSignedIn }
            guard membership.status == .approved else { throw NetworkError.refused }
            return try await work(NetworkClient(membership: membership))
        }
    }
}

/// Whether reads that couldn't reach a network add up to it being down. The first failure stays quiet and
/// the feed tries again soon. The banner shows once reads have kept failing for `grace` seconds, counted
/// from when the first of them started, so a read that timed out shows at once.
struct NetworkOutage {
    static let grace: TimeInterval = 8
    static let retryAfter: Duration = .seconds(4)
    /// A failure this long after the last one starts a new outage, such as after the app was away.
    static let forgetAfter: TimeInterval = 120

    private var since: Date?
    private var last: Date?

    /// Notes a read that started at `started` and failed at `now`. True once the banner should show.
    mutating func failed(started: Date, now: Date = .now) -> Bool {
        let ongoing = last.map { now.timeIntervalSince($0) <= Self.forgetAfter } ?? false
        let since = ongoing ? self.since ?? started : started
        self.since = since
        last = now
        return now.timeIntervalSince(since) >= Self.grace
    }
}

import Foundation
import Network

/// How one of Debug's checks went.
enum DebugCheckState: Sendable, Equatable {
    case waiting, running, passed, failed
    /// Not run, because something it needs failed first or the run was stopped.
    case skipped
}

/// One check, as Debug shows it and the report lists it.
struct DebugCheck: Identifiable, Sendable {
    let id: Int
    /// Which of the run's groups it's in.
    let group: Int
    let title: String
    var detail: String
    var milliseconds: Int?
    var state: DebugCheckState
}

/// What a check found.
struct DebugOutcome: Sendable {
    var state: DebugCheckState
    var detail: String
    var milliseconds: Int?

    static func pass(_ detail: String, _ milliseconds: Int? = nil) -> DebugOutcome {
        DebugOutcome(state: .passed, detail: detail, milliseconds: milliseconds)
    }

    static func fail(_ detail: String, _ milliseconds: Int? = nil) -> DebugOutcome {
        DebugOutcome(state: .failed, detail: detail, milliseconds: milliseconds)
    }

    static func skip(_ detail: String) -> DebugOutcome {
        DebugOutcome(state: .skipped, detail: detail)
    }
}

/// The text Copy Report puts on the clipboard, short enough to read in a message: problems in full,
/// each group on one line, then the launch log's notable events.
enum DebugReport {
    struct Header: Sendable {
        /// The network's name, or Farcaster.
        let place: String
        /// Such as "Fatline 0.1.1 (16)".
        let build: String
        /// Such as "iOS 27.1".
        let system: String
        let fid: UInt64?
        let time: Date
        /// The build before this one, when this is the first launch after an update.
        let updatedFrom: String?
        let seconds: Double
    }

    static let leavesOut = "No keys, tokens, post text, drafts, link signatures, or recovery phrase."

    static func text(header: Header, groups: [String], checks: [DebugCheck], extra: [String] = [], log: [String]) -> String {
        let problems = checks.filter { $0.state == .failed }
        var lines = ["Fatline report · \(header.place)"]
        lines.append([header.build, header.system, header.fid.map { "Farcaster ID \($0)" }].compactMap(\.self).joined(separator: " · "))
        lines.append(header.time.formatted(date: .abbreviated, time: .shortened)
                     + (header.updatedFrom.map { " · first launch after build \($0)" } ?? ""))
        lines.append("\(summary(problems: problems.count)) · \(count(checks.count)) · \(String(format: "%.1f", header.seconds)) s")
        if !problems.isEmpty {
            lines.append("")
            for check in problems {
                lines.append("✗ \(groups[check.group]): \(check.title)")
                lines.append("  \(check.detail)")
            }
        }
        lines.append("")
        for (index, group) in groups.enumerated() {
            let mine = checks.filter { $0.group == index }
            guard !mine.isEmpty else { continue }
            let passed = mine.filter { $0.state == .passed }.count
            let mark = mine.contains { $0.state == .failed } ? "✗" : passed == mine.count ? "✓" : "–"
            lines.append("\(mark) \(group) \(passed) of \(mine.count)")
        }
        if !extra.isEmpty { lines += [""] + extra }
        if !log.isEmpty { lines += [""] + log }
        lines += ["", leavesOut]
        return lines.joined(separator: "\n")
    }

    static func summary(problems: Int) -> String {
        problems == 0 ? "No problems" : problems == 1 ? "1 problem" : "\(problems) problems"
    }

    static func count(_ checks: Int) -> String {
        checks == 1 ? "1 check" : "\(checks) checks"
    }
}

/// Debug's checks for one place in the app: a network, or Farcaster, never both. They only read:
/// nothing posts, likes, deletes, or changes a setting, and the pictures they fetch leave the cache
/// as it was.
@MainActor
@Observable
final class CheckRun {
    enum Target {
        case network(host: String, model: NetworkModel)
        case farcaster(model: FeedModel, keyNotice: String?)
    }

    private enum Step {
        case connection, lowPower, storage
        case keychain, membership, feedFile, imageCache
        case answers, clock, signedIn, info, feed, members, activity, noStuckRead
        case farcasterFeed, postingKey
        case cachedPictures, freshPictures, feedPictures
    }

    let place: String
    let groups: [String]
    private(set) var checks: [DebugCheck] = []
    private(set) var running = false
    private(set) var finishedAt: Date?
    private(set) var seconds: Double = 0

    private let target: Target
    private let steps: [(group: Int, title: String, step: Step)]
    @ObservationIgnored private var task: Task<Void, Never>?
    // What earlier checks found, for the ones after them.
    @ObservationIgnored private var clockOffset: TimeInterval?
    @ObservationIgnored private var feed: [NetworkPost]?
    @ObservationIgnored private var memberList: [NetworkMember]?

    init(_ target: Target) {
        let name: String
        switch target {
        case .network(let host, let model): name = model.memberships.first { $0.host == host }?.title ?? host
        case .farcaster: name = "Farcaster"
        }
        self.target = target
        place = name
        groups = ["This \(Platform.deviceName)", "Saved on this \(Platform.deviceName)", name]
        steps = Self.plan(for: target)
        checks = steps.enumerated().map {
            DebugCheck(id: $0.offset, group: $0.element.group, title: $0.element.title, detail: "Waiting", state: .waiting)
        }
    }

    /// The group being checked while the run is under way.
    var currentGroup: Int? { checks.first { $0.state == .running }?.group }
    var problems: [DebugCheck] { checks.filter { $0.state == .failed } }
    var done: Int { checks.filter { $0.state != .waiting && $0.state != .running }.count }

    func start() {
        guard !running else { return }
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
    }

    var report: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let header = DebugReport.Header(
            place: place, build: FeedModel.versionLine, system: "\(Platform.systemName) \(system.majorVersion).\(system.minorVersion)",
            fid: fid, time: finishedAt ?? .now, updatedFrom: LaunchLog.updatedFrom, seconds: seconds
        )
        return DebugReport.text(header: header, groups: groups, checks: checks, extra: extraLines, log: LaunchLog.reportLines(scope: scope))
    }

    /// The Launch Log's scope for this place.
    var scope: String {
        switch target {
        case .network(let host, _): host
        case .farcaster: LaunchLog.farcaster
        }
    }

    private var fid: UInt64? {
        switch target {
        case .network(let host, let model): model.memberships.first { $0.host == host }?.fid
        case .farcaster(let model, _): model.ownFID
        }
    }

    /// Farcaster's last few feed reads, which Copy Diagnostics used to give.
    private var extraLines: [String] {
        guard case .farcaster(let model, _) = target else { return [] }
        let lines = model.diagnostics.split(separator: "\n").map(String.init)
        guard let index = lines.firstIndex(where: { $0.hasPrefix("Refreshes") }) else { return [] }
        return ["Recent feed reads"] + lines[(index + 1)...].prefix(3)
    }

    private static func plan(for target: Target) -> [(group: Int, title: String, step: Step)] {
        let phone: [(group: Int, title: String, step: Step)] = [
            (0, "Connection", .connection), (0, "Low Power mode", .lowPower), (0, "Storage", .storage),
        ]
        switch target {
        case .network:
            return phone + [
                (1, "Keychain", .keychain), (1, "Membership", .membership), (1, "Image cache", .imageCache),
                (2, "Answers", .answers), (2, "Clock", .clock), (2, "Signed in", .signedIn), (2, "Network", .info),
                (2, "Feed", .feed), (2, "Members", .members), (2, "Activity", .activity), (2, "No read stuck", .noStuckRead),
                (2, "Pictures from the cache", .cachedPictures), (2, "Pictures fetched fresh", .freshPictures),
                (2, "Pictures in the feed", .feedPictures),
            ]
        case .farcaster:
            return phone + [
                (1, "Keychain", .keychain), (1, "Feed file", .feedFile), (1, "Image cache", .imageCache),
                (2, "Feed", .farcasterFeed), (2, "Posting key", .postingKey),
                (2, "Pictures from the cache", .cachedPictures), (2, "Pictures fetched fresh", .freshPictures),
                (2, "Pictures in the feed", .feedPictures),
            ]
        }
    }

    private func run() async {
        running = true
        finishedAt = nil
        clockOffset = nil
        feed = nil
        memberList = nil
        let begin = Date.now
        for index in checks.indices {
            checks[index].milliseconds = nil
            checks[index].state = .waiting
            checks[index].detail = "Waiting"
        }
        for index in steps.indices {
            guard !Task.isCancelled else {
                checks[index].state = .skipped
                checks[index].detail = "Stopped"
                continue
            }
            checks[index].state = .running
            checks[index].detail = "Checking…"
            let outcome = await perform(steps[index].step)
            checks[index].state = outcome.state
            checks[index].detail = outcome.detail
            checks[index].milliseconds = outcome.milliseconds
        }
        seconds = Date.now.timeIntervalSince(begin)
        finishedAt = .now
        running = false
        task = nil
    }

    private func perform(_ step: Step) async -> DebugOutcome {
        switch step {
        case .connection:
            let connection = await Self.connection()
            return connection.connected ? .pass(connection.detail) : .fail(connection.detail)
        case .lowPower:
            return .pass(ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
        case .storage:
            guard let free = Self.freeSpace() else { return .skip("Couldn’t read it") }
            let text = ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free"
            return free >= 500_000_000 ? .pass(text) : .fail(text)
        case .keychain:
            return keychain()
        case .membership:
            return membership()
        case .feedFile:
            return feedFile()
        case .imageCache:
            let bytes = CastImages.cacheBytes
            return .pass(bytes == 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        case .answers:
            return await answers()
        case .clock:
            guard let clockOffset else { return .skip("The network didn’t say its time") }
            let off = Int(abs(clockOffset).rounded())
            let text = off <= 2 ? "Within 2 s of \(place)" : "\(off) s \(clockOffset > 0 ? "ahead of" : "behind") \(place)"
            return off < 60 ? .pass(text) : .fail(text)
        case .signedIn:
            return await signedIn()
        case .info:
            return await read { try await $0.info() } describe: { $0.name }
        case .feed:
            return await read { try await $0.feed() } describe: { posts in
                self.feed = posts
                return posts.count == 1 ? "1 post" : "\(posts.count) posts"
            }
        case .members:
            return await read { try await $0.members() } describe: { members in
                self.memberList = members
                return members.count == 1 ? "1 member" : "\(members.count) members"
            }
        case .activity:
            return await read { try await $0.activity() } describe: { $0.count == 1 ? "1 item" : "\($0.count) items" }
        case .noStuckRead:
            guard case .network(_, let model) = target else { return .skip("") }
            if let started = model.readStarted, Date.now.timeIntervalSince(started) > 30 {
                return .fail("A read has been loading for \(Int(Date.now.timeIntervalSince(started))) s")
            }
            return .pass("None")
        case .farcasterFeed:
            guard case .farcaster(let model, _) = target else { return .skip("") }
            if let problem = model.problem { return .fail("\(problem)") }
            guard let checked = model.lastChecked else { return .fail("Not read yet") }
            let minutes = Int(Date.now.timeIntervalSince(checked) / 60)
            let text = minutes < 1 ? "Read just now" : "Read \(minutes) min ago"
            return minutes <= 15 ? .pass(text) : .fail(text)
        case .postingKey:
            guard case .farcaster(_, let keyNotice) = target else { return .skip("") }
            if let keyNotice { return .fail(keyNotice) }
            return .pass("Active")
        case .cachedPictures:
            return await cachedPictures()
        case .freshPictures:
            return await freshPictures()
        case .feedPictures:
            let loaded = CastImages.loadedCount[scope] ?? 0
            let failed = CastImages.failedCount[scope] ?? 0
            let waiting = CastImages.waiting(scope, longerThan: 60)
            if failed == 0 && waiting == 0 { return .pass("\(loaded) loaded, none failed") }
            var parts = ["\(failed) failed since launch"]
            if waiting > 0 { parts.append("\(waiting) still waiting after 60 s") }
            parts.append("\(loaded) loaded")
            return .fail(parts.joined(separator: ", "))
        }
    }

    // MARK: The checks that take more than a line

    private func keychain() -> DebugOutcome {
        let probe = KeychainValue<String>(account: "debug-check")
        do {
            try probe.save("ok")
            let back = try probe.load()
            try probe.remove()
            return back == "ok" ? .pass("Reads and writes") : .fail("Read back something else")
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func membership() -> DebugOutcome {
        guard case .network(let host, let model) = target else { return .skip("") }
        do {
            guard let saved = try NetworkKeychain.memberships.load()?.first(where: { $0.host == host }) else {
                return .fail("Not saved on this \(Platform.deviceName)")
            }
            guard saved.key == model.memberships.first(where: { $0.host == host })?.key else { return .fail("Saved with another key") }
            return .pass(saved.status == .approved ? "Saved, key matches" : "Saved, \(saved.status)")
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func feedFile() -> DebugOutcome {
        guard case .farcaster(let model, _) = target, let fid = model.ownFID else { return .skip("") }
        let file = PostingSession.accountFolder(fid).appending(path: "feed.json")
        guard let data = try? Data(contentsOf: file) else { return .pass("None saved yet") }
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return .fail("\(size), unreadable") }
        return .pass("\(size), \(model.casts.count) casts")
    }

    private func answers() async -> DebugOutcome {
        guard case .network(let host, _) = target else { return .skip("") }
        var request = URLRequest(url: NetworkMessages.origin(host).appending(path: "api/v1"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(NetworkClient.appHeader, forHTTPHeaderField: "fatline-app")
        let start = Date.now
        do {
            let (_, response) = try await HTTP.loadResponse(request)
            let milliseconds = Self.milliseconds(since: start)
            if let date = response.value(forHTTPHeaderField: "date").flatMap(Self.httpDate) {
                clockOffset = Date.now.timeIntervalSince(date)
            }
            return response.statusCode == 200 ? .pass(host, milliseconds) : .fail("\(host) answered \(response.statusCode)", milliseconds)
        } catch {
            return .fail("Couldn’t reach \(host): \(error.localizedDescription)", Self.milliseconds(since: start))
        }
    }

    private func signedIn() async -> DebugOutcome {
        guard case .network(let host, let model) = target else { return .skip("") }
        let start = Date.now
        do {
            try await model.withClient(host) { _ in }
            let expires = model.memberships.first { $0.host == host }?.expires
            let until = expires.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .shortened) }
            return .pass(until.map { "Session until \($0)" } ?? "Signed in", Self.milliseconds(since: start))
        } catch {
            return .fail(error.localizedDescription, Self.milliseconds(since: start))
        }
    }

    /// One read from the network, timed, as the app's own reads make it.
    private func read<Value: Sendable>(_ work: @Sendable (NetworkClient) async throws -> Value,
                                       describe: (Value) -> String) async -> DebugOutcome {
        guard case .network(let host, let model) = target else { return .skip("") }
        let start = Date.now
        do {
            let value = try await model.withClient(host, work)
            return .pass(describe(value), Self.milliseconds(since: start))
        } catch {
            return .fail(error.localizedDescription, Self.milliseconds(since: start))
        }
    }

    /// The same pictures, from the cache alone. A copy that's there but doesn't decode is the problem
    /// this looks for; one that isn't cached yet is fine.
    private func cachedPictures() async -> DebugOutcome {
        let links = pictureLinks()
        guard !links.isEmpty else { return .skip(needsFeed ? "Needs the feed" : "No pictures to try") }
        var probes: [CastImages.Probe] = []
        for link in links { probes.append(await CastImages.probe(link, fresh: false)) }
        let cached = probes.filter { $0.fetched.status != nil }
        if let broken = cached.first(where: { !$0.decoded }) {
            let good = cached.filter(\.decoded).count
            return .fail("\(good) of \(cached.count) cached copies decode: \(Self.why(broken))")
        }
        if cached.isEmpty { return .pass("None of \(links.count) cached yet") }
        let missing = links.count - cached.count
        return .pass("\(cached.count) cached, all decode" + (missing > 0 ? "; \(missing) not cached yet" : ""))
    }

    private func freshPictures() async -> DebugOutcome {
        let links = pictureLinks()
        guard !links.isEmpty else { return .skip(needsFeed ? "Needs the feed" : "No pictures to try") }
        var probes: [CastImages.Probe] = []
        for link in links { probes.append(await CastImages.probe(link, fresh: true)) }
        let good = probes.filter(\.decoded).count
        if let broken = probes.first(where: { !$0.decoded }) {
            return .fail("\(good) of \(probes.count) decode: \(Self.why(broken))")
        }
        let types = Set(probes.compactMap { $0.fetched.type?.split(separator: ";").first.map(String.init) }).sorted()
        return .pass("\(good) of \(probes.count) decode" + (types.isEmpty ? "" : " (\(types.joined(separator: ", ")))"))
    }

    private var needsFeed: Bool {
        if case .network = target { return feed == nil }
        return false
    }

    /// Up to 3 pictures from the feed: posts' pictures first, then avatars.
    private func pictureLinks() -> [URL] {
        var links: [URL] = []
        switch target {
        case .network(let host, _):
            for post in feed ?? [] {
                for embed in post.embeds where embed.type == "image" {
                    if let src = embed.src, let url = FeedCast.networkMediaURL(src, host: host) { links.append(url) }
                }
            }
            for member in memberList ?? [] {
                if let avatar = member.avatar, let url = FeedCast.networkMediaURL(avatar, host: host) { links.append(url) }
            }
        case .farcaster(let model, _):
            for cast in model.casts { links += cast.imageURLs }
            for cast in model.casts { if let avatar = cast.avatarURL { links.append(avatar) } }
        }
        var seen = Set<URL>()
        return Array(links.filter { seen.insert($0).inserted }.prefix(3))
    }

    // MARK: Helpers

    private static func why(_ probe: CastImages.Probe) -> String {
        if let data = probe.fetched.data { return CastImages.undecodable(data, probe.fetched.type) + ", \(data.count) bytes" }
        return probe.fetched.problem ?? "failed"
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date.now.timeIntervalSince(start) * 1000)
    }

    nonisolated private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    nonisolated private static func freeSpace() -> Int64? {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The connection right now: Wi-Fi, cellular, or none, and whether Low Data mode is on.
    nonisolated private static func connection() async -> (connected: Bool, detail: String) {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        return await withCheckedContinuation { continuation in
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                continuation.resume(returning: summary(of: path))
            }
            monitor.start(queue: DispatchQueue(label: "fatline.debug.connection"))
        }
    }

    nonisolated private static func summary(of path: NWPath) -> (connected: Bool, detail: String) {
        guard path.status == .satisfied else { return (false, "No connection") }
        let kind = path.usesInterfaceType(.wifi) ? "Wi-Fi"
            : path.usesInterfaceType(.cellular) ? "Cellular"
            : path.usesInterfaceType(.wiredEthernet) ? "Wired" : "Connected"
        return (true, kind + (path.isConstrained ? ", Low Data mode on" : ""))
    }
}

/// Lets the first of several callbacks through, for a continuation that must resume once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

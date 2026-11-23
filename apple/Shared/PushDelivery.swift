import Foundation

// What happens to a push between Apple and the screen: the notification extension opens the sealed
// note and writes the words, the badge counts replies and mentions, and a tap opens the right screen.
// The extension compiles this file too. design/push-notifications-plan.md, "What notifies" and Phase 3.

/// What the notification extension shows for a push from the relay, which carries the handle as `h`
/// and the sealed note as `s`. Anything that doesn't open shows the relay's own fallback words.
struct PushDelivery: Equatable, Sendable {
    let title: String
    let body: String
    /// Stacks a network's notifications together: its host.
    let thread: String?
    /// Where a tap goes, written into the notification by the extension.
    let tap: PushTap?

    /// Replies and mentions count on the badge; new posts and the network's own news don't.
    var countsOnBadge: Bool { tap?.kind == .reply || tap?.kind == .mention }

    static let fallback = PushDelivery(title: "Fatline", body: "Something new in a network.", thread: nil, tap: nil)

    static func make(userInfo: [AnyHashable: Any], targets: [PushTarget]) -> PushDelivery {
        guard let handle = userInfo["h"] as? String, let sealed = userInfo["s"] as? String,
              let target = targets.first(where: { $0.handle.handle == handle }),
              let note = PushNote.open(sealed, key: target.symmetricKey) else { return .fallback }
        let words = note.words(network: target.name)
        return PushDelivery(title: words.title, body: words.body, thread: target.host,
                            tap: PushTap(host: target.host, kind: note.kind, post: note.post, thread: note.thread, count: note.count))
    }
}

/// Where a tapped notification goes. The extension writes it under one key, from the target it opened
/// the note with, so the host is always a network this device joined, never one a note names.
struct PushTap: Equatable, Hashable, Sendable {
    static let key = "fatline"

    let host: String
    let kind: PushNote.Kind
    let post: String?
    let thread: String?
    let count: Int

    enum Target: Equatable, Hashable, Sendable {
        /// A post and its replies, with one reply lit for a moment.
        case thread(String, lit: String?)
        /// The network's feed.
        case feed
        case activity
        /// The admin pages, in Safari.
        case manage
    }

    /// The plan's table: a reply opens the post with that reply lit, a mention the post it's in, a new
    /// post the post, an hour's new posts, "You're in.", and Debug's test the feed, requests and reports
    /// Manage Network. A reply or mention without a post opens Activity.
    var target: Target {
        switch kind {
        case .reply, .mention:
            guard let thread else { return .activity }
            return .thread(thread, lit: post.flatMap { $0 == thread ? nil : $0 })
        case .post:
            guard count == 1, let thread else { return .feed }
            return .thread(thread, lit: nil)
        case .approved, .test:
            return .feed
        case .request, .report:
            return .manage
        }
    }

    var userInfo: [String: Any] {
        var info: [String: Any] = ["host": host, "kind": kind.rawValue, "count": count]
        if let post { info["post"] = post }
        if let thread { info["thread"] = thread }
        return [Self.key: info]
    }

    init(host: String, kind: PushNote.Kind, post: String?, thread: String?, count: Int) {
        self.host = host
        self.kind = kind
        self.post = post
        self.thread = thread
        self.count = count
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let info = userInfo[Self.key] as? [String: Any], let host = info["host"] as? String, !host.isEmpty,
              let kind = (info["kind"] as? String).flatMap(PushNote.Kind.init) else { return nil }
        // `0x` and 40 lowercase hex digits, as every post's hash is.
        let hash = { (key: String) in
            (info[key] as? String).flatMap { text in
                text.count == 42 && text.hasPrefix("0x") && text.dropFirst(2).allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) } ? text : nil
            }
        }
        self.init(host: host, kind: kind, post: hash("post"), thread: hash("thread"), count: max(1, info["count"] as? Int ?? 1))
    }
}

/// The badge: replies and mentions not yet seen in Activity, by network, in the App Group's settings.
/// The extension adds to it as each arrives, and the app clears a network's when its Activity opens.
struct PushBadge {
    static let key = "pushBadge"
    let defaults: UserDefaults

    init?(group: String) {
        guard let defaults = UserDefaults(suiteName: group) else { return nil }
        self.defaults = defaults
    }

    init(defaults: UserDefaults) { self.defaults = defaults }

    var counts: [String: Int] { defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:] }
    var total: Int { counts.values.reduce(0, +) }

    /// One more for `host`. Returns the new total, for the notification's badge.
    @discardableResult
    func add(_ host: String) -> Int {
        var counts = counts
        counts[host, default: 0] += 1
        defaults.set(counts, forKey: Self.key)
        return counts.values.reduce(0, +)
    }

    /// Activity opened in `host`, or it was left. Returns the new total.
    @discardableResult
    func clear(_ host: String) -> Int {
        var counts = counts
        counts[host] = nil
        defaults.set(counts, forKey: Self.key)
        return counts.values.reduce(0, +)
    }

    func clearAll() { defaults.removeObject(forKey: Self.key) }
}

import Foundation

/// What each network is told was read (`PUT /me/seen`), for twice-a-day summaries: the newest post its
/// feed had on screen, and nothing read while Settings, Activity, or the composer was over it. A network
/// is told at most once a minute, or at once when the app goes to the background
/// (design/push-digest-plan.md). Pure, so it's tested without a network.
struct SeenReports {
    static let interval: TimeInterval = 60

    /// The newest post time each network's feed has had on screen.
    private(set) var shown: [String: Int64] = [:]
    /// The newest post time each network was told, and when.
    private var sent: [String: (time: Int64, at: Date)] = [:]

    /// A network's feed was on screen with posts up to `time`. It only moves forward.
    mutating func show(_ host: String, upTo time: Int64) {
        guard time > 0 else { return }
        shown[host] = max(shown[host] ?? 0, time)
    }

    /// The time to tell `host` now, marked as told, or nil: when nothing newer was shown since it was last
    /// told, or it was told less than a minute ago and `now` is false.
    mutating func due(_ host: String, now: Bool = false, at date: Date = .now) -> Int64? {
        guard let time = shown[host], time > (sent[host]?.time ?? 0) else { return nil }
        if !now, let last = sent[host]?.at, date.timeIntervalSince(last) < Self.interval { return nil }
        sent[host] = (time, date)
        return time
    }

    /// Every network with something shown that it hasn't been told, each marked as told, for going to the
    /// background.
    mutating func allDue(at date: Date = .now) -> [(host: String, time: Int64)] {
        shown.keys.sorted().compactMap { host in due(host, now: true, at: date).map { (host, $0) } }
    }
}

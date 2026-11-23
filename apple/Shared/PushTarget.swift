import CryptoKit
import Foundation

// What this device keeps for each network it hears from. The notification extension compiles this
// file too, so it stays free of the app's networking: the relay's calls are in PushRelay.swift.

/// Where this device hears from one network: the handle and secret at the relay.
struct PushHandle: Codable, Equatable, Sendable {
    let handle: String
    let secret: String

    /// 16 random bytes as 22 base64url characters, and 32 as 43, as the relay makes them. Anything
    /// else is refused, since the handle goes into the relay's paths.
    var isWellFormed: Bool {
        Self.isBase64URL(handle, count: 22) && Self.isBase64URL(secret, count: 43)
    }

    static func isBase64URL(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// What a device hears from one network, as `PUT /me/push` sends it (docs/NETWORK.md, Notifications).
struct PushChoices: Codable, Equatable, Hashable, Sendable {
    enum Level: String, Codable, CaseIterable, Sendable {
        case digest, all, replies, off

        /// As Settings shows it.
        var title: String {
            switch self {
            case .digest: "Twice a day"
            case .all: "All posts"
            case .replies: "Replies and mentions"
            case .off: "Off"
            }
        }
    }

    /// New posts you haven't read at 9 a.m. and 9 p.m. with replies and mentions at once, the default
    /// (design/push-digest-plan.md); each new post, replies, and mentions; replies and mentions; or nothing.
    var level = Level.digest
    /// The admin's own switches, whatever the level.
    var requests = true
    var reports = true

    /// Whether a network would send this device anything. Off still hears join requests and reports
    /// when an admin keeps them on; otherwise Off means the relay forgets the handle.
    func hearsAnything(admin: Bool) -> Bool {
        level != .off || (admin && (requests || reports))
    }
}

/// Where one network's notes go and the key that opens them, which this device made for that network.
/// The notification extension reads these to open a note: the handle names the network, and the
/// network's name here is the one the notification shows.
struct PushTarget: Codable, Equatable, Sendable {
    let host: String
    var name: String
    let relay: String
    var handle: PushHandle
    /// 32 random bytes, made on this device. Only this device and that network have it.
    let key: Data
    var choices: PushChoices
    /// The time zone the network was last told, such as America/New_York, for when its twice-a-day
    /// summaries go. Nil for a target saved before summaries, which the next launch tells.
    var zone: String? = nil

    var symmetricKey: SymmetricKey { SymmetricKey(data: key) }
}

import Foundation

/// What a network said when Debug asked it to send this device a test notification
/// (`POST /me/push/test`, docs/NETWORK.md), and the words Debug shows for it.
struct PushTestAnswer: Decodable, Equatable, Sendable {
    enum Result: String, Decodable, Sendable {
        /// The relay passed it to Apple.
        case sent
        /// The relay or Apple no longer knows this device, so the network forgot it.
        case gone
        /// It didn't reach Apple, and the handle is fine.
        case failed
    }

    let result: Result
    /// The relay's reason, such as `BadDeviceToken`, or the network's, such as `relay-503`.
    let reason: String?

    init(result: Result, reason: String? = nil) {
        self.result = result
        self.reason = reason
    }

    var detail: String {
        switch result {
        case .sent: "The relay passed it to Apple."
        case .gone: "Apple or the relay no longer knows this \(Platform.deviceName)\(because). Fatline gave the network a new handle, so send it again."
        case .failed: "It didn’t reach Apple\(because)."
        }
    }

    /// ": what it means (Reason)", or ": Reason" for one Fatline doesn't know, or nothing without one.
    private var because: String {
        guard let reason, !reason.isEmpty else { return "" }
        guard let meaning = Self.meaning(reason) else { return ": \(reason)" }
        return ": \(meaning) (\(reason))"
    }

    /// The reasons worth explaining. Apple's are at developer.apple.com, "Handling notification responses from APNs".
    static func meaning(_ reason: String) -> String? {
        switch reason {
        case "BadDeviceToken": "the device token is for Apple’s other service, sandbox or production"
        case "Unregistered": "Apple says the app was deleted or turned notifications off"
        case "DeviceTokenNotForTopic": "the device token belongs to another build of Fatline"
        case "TopicDisallowed": "Apple won’t send for this app"
        case "BadTopic", "MissingTopic": "the relay named the app wrongly"
        case "InvalidProviderToken", "ExpiredProviderToken", "MissingProviderToken", "key": "Apple turned down the relay’s key"
        case "TooManyRequests", "TooManyProviderTokenUpdates": "Apple says too many went at once"
        case "InternalServerError", "ServiceUnavailable", "Shutdown": "Apple had a problem of its own"
        case "unreachable": "Apple didn’t answer the relay"
        case "hourly-limit": "this \(Platform.deviceName) had 60 notifications from this network this hour"
        case "unknown-handle": "the relay no longer had this \(Platform.deviceName)’s handle"
        case "unknown-app": "the relay no longer sends for this build"
        case "relay-unreachable": "the network couldn’t reach the relay"
        default:
            if reason.hasPrefix("relay-"), let status = Int(reason.dropFirst(6)) { "the relay answered \(status)" } else { nil }
        }
    }
}

/// Why Debug's test notification couldn't be sent, before asking the network.
enum PushTestProblem: LocalizedError, Equatable {
    /// This build has no App Group, so no Keychain item the notification extension can read.
    case noKeys
    case notIn
    /// Notifications are Off for this network.
    case off

    var errorDescription: String? {
        switch self {
        case .noKeys: "This build has nowhere to keep notification keys."
        case .notIn: "You’re not in this network yet."
        case .off: "Notifications are Off for this network. Turn them on in Settings → Notifications."
        }
    }
}

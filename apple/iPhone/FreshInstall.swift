import Foundation
import Security

/// iOS deletes an app's files and settings with it but keeps its Keychain, so a reinstall used to find
/// the old sign-in. On the first launch of a new install, this deletes what an earlier install left in
/// the Keychain, so deleting Fatline starts it fresh. An update keeps the app's files and settings, so
/// it never clears anything. From the Fatline Start Over canvas, November 20, 2026.
enum FreshInstall {
    enum Outcome: Equatable { case earlierInstall, nothingSaved, cleared, unavailable }

    /// Set once a launch has checked, so later launches skip straight past.
    static let markerKey = "installChecked"
    /// Settings an earlier build writes. Some end in a Debug profile's suffix, so they're matched as prefixes.
    static let earlierSettings = [markerKey, "launchLogLastBuild", "pictureCacheMoved", "announcedBuild",
                                  "selectedNetwork", "networkSeenPosts", "networkSeenActivity"]

    /// First thing in `FatlineApp.init`, before anything reads the Keychain.
    static func runForApp() -> Outcome {
        let defaults = UserDefaults.standard
        let saved = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        let outcome = run(folder: Platform.appFolder, settings: Array(saved.keys),
                          service: Bundle.main.bundleIdentifier ?? "Fatline", pushGroup: PushKeychain.appGroup)
        if outcome != .unavailable { defaults.set(true, forKey: markerKey) }
        return outcome
    }

    /// `pushGroup` is the App Group's Keychain access group, where each network's notification key is
    /// kept for the notification extension (`PushKeychain`). It's cleared with the rest.
    static func run(folder: URL, settings: [String], service: String, pushGroup: String? = nil,
                    pushService: String = PushKeychain.service) -> Outcome {
        if hasEarlierInstall(folder: folder, settings: settings) { return .earlierInstall }
        let found = [firstItem(service: service)] + (pushGroup.map { [PushKeychain.firstItem(group: $0, service: pushService)] } ?? [])
        if found.allSatisfy({ $0 == errSecItemNotFound }) { return .nothingSaved }
        // Locked (a launch in the background before the first unlock) or another answer: try next launch.
        guard found.allSatisfy({ $0 == errSecSuccess || $0 == errSecItemNotFound }) else { return .unavailable }
        let cleared = removeAll(service: service) && (pushGroup.map { PushKeychain.removeAll(group: $0, service: pushService) } ?? true)
        return cleared ? .cleared : .unavailable
    }

    static func hasEarlierInstall(folder: URL, settings: [String]) -> Bool {
        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) { return true }
        return settings.contains { key in earlierSettings.contains { key.hasPrefix($0) } }
    }

    /// Asks for an item's data, not just that it exists, so a locked device answers "not now".
    private static func firstItem(service: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        return SecItemCopyMatching(query as CFDictionary, nil)
    }

    /// Every generic password under `service`: the sign-in, the connection, the network key and
    /// memberships, and each Debug profile's copies. On iOS one delete removes every match.
    private static func removeAll(service: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

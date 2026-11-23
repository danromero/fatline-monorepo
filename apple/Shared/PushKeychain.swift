import Foundation
import Security

/// Where `PushRegistrar` keeps each network's handle and key: one Keychain item in the App Group's
/// access group, so the notification extension can open notes with the keys. It's readable once the
/// phone has been unlocked after a restart (`AfterFirstUnlockThisDeviceOnly`), so notes open on a locked
/// phone, and it never leaves this device. A Debug profile keeps its own item, and the extension looks
/// through all of them. The extension compiles this file too. design/push-notifications-plan.md, Phase 3.
struct PushKeychain: Sendable {
    static let service = "Fatline push"
    static let account = "push-keys-v1"

    /// The App Group, which is also a Keychain access group the app and the extension share.
    let group: String
    /// `account` with a Debug profile's suffix.
    var account = Self.account
    /// The app's own, unless a test names another so it never touches real keys.
    var service = Self.service

    /// The App Group this build was signed with, from its Info.plist. Nil on the Mac, which has none yet.
    static var appGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FatlineAppGroup") as? String,
              group.hasPrefix("group."), !group.contains("$") else { return nil }
        return group
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func load() throws -> [PushTarget] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data else { throw Problem(status: status) }
        return try JSONDecoder().decode([PushTarget].self, from: data)
    }

    /// Saves the targets, or with none, deletes the item.
    func save(_ targets: [PushTarget]) throws {
        guard !targets.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Problem(status: status) }
            return
        }
        let data = try JSONEncoder().encode(targets)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
            guard added == errSecSuccess else { throw Problem(status: added) }
        } else if status != errSecSuccess {
            throw Problem(status: status)
        }
    }

    /// Every profile's targets, for the extension, which can't tell which profile a note is for. Empty
    /// when the phone hasn't been unlocked since it started, so the fallback words show.
    static func loadAll(group: String, service: String = service) -> [PushTarget] {
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: group,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &items) == errSecSuccess, let all = items as? [Data] else { return [] }
        return all.flatMap { (try? JSONDecoder().decode([PushTarget].self, from: $0)) ?? [] }
    }

    /// Whether any profile has targets saved, for a fresh install's check. Asks for the data, so a
    /// locked phone answers "not now" rather than "none".
    static func firstItem(group: String, service: String = service) -> OSStatus {
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: group,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(request as CFDictionary, nil)
    }

    /// Every profile's targets, for a fresh install and Start Over.
    static func removeAll(group: String, service: String = service) -> Bool {
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: group,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(request as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    struct Problem: LocalizedError, Equatable {
        let status: OSStatus
        var errorDescription: String? { "The Keychain answered \(status)." }
    }
}

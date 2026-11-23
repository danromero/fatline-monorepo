#if os(iOS)
import Security
import XCTest
@testable import Fatline

/// Each test has its own Keychain service and folder path, and passes settings as a plain list, so
/// nothing touches the app's own sign-in, folder, or defaults.
final class FreshInstallTests: XCTestCase {
    private var service = ""
    private var folder = URL(filePath: "/")

    override func setUp() {
        super.setUp()
        service = "fatline.tests.fresh-install.\(UUID())"
        folder = FileManager.default.temporaryDirectory.appending(path: "FreshInstallTests-\(UUID())", directoryHint: .isDirectory)
    }

    override func tearDown() {
        Self.removeItems(service: service)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private static func removeItems(service: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }

    private func item(_ account: String, service: String? = nil) -> KeychainValue<String> {
        KeychainValue(account: account, service: service ?? self.service)
    }

    /// The sign-in, a Debug profile's connection, and the network memberships.
    private func saveEach() throws {
        for account in ["posting-account-v1", "connection-v1-dev", "network-memberships-v1"] {
            try item(account).save("saved \(account)")
        }
    }

    func testANewInstallClearsWhatAnEarlierOneLeft() throws {
        try saveEach()
        XCTAssertEqual(FreshInstall.run(folder: folder, settings: [], service: service), .cleared)
        for account in ["posting-account-v1", "connection-v1-dev", "network-memberships-v1"] {
            XCTAssertNil(try item(account).load(), account)
        }
    }

    func testTheAppsFolderMeansAnUpdate() throws {
        try saveEach()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(FreshInstall.run(folder: folder, settings: [], service: service), .earlierInstall)
        XCTAssertEqual(try item("posting-account-v1").load(), "saved posting-account-v1")
    }

    func testEachEarlierSettingMeansAnUpdate() throws {
        try saveEach()
        let settings = FreshInstall.earlierSettings + ["launchLogLastBuild-check", "selectedNetwork-dev"]
        for setting in settings {
            XCTAssertEqual(FreshInstall.run(folder: folder, settings: ["AppleLanguages", setting], service: service),
                           .earlierInstall, setting)
        }
        XCTAssertEqual(try item("posting-account-v1").load(), "saved posting-account-v1")
    }

    func testUnrelatedSettingsDontCount() throws {
        try saveEach()
        XCTAssertEqual(FreshInstall.run(folder: folder, settings: ["AppleLanguages", "NSInterfaceStyle"], service: service),
                       .cleared)
    }

    func testNothingSaved() {
        XCTAssertEqual(FreshInstall.run(folder: folder, settings: [], service: service), .nothingSaved)
    }

    func testAnotherServicesItemsSurviveAClear() throws {
        let other = "fatline.tests.fresh-install.other.\(UUID())"
        defer { Self.removeItems(service: other) }
        try item("posting-account-v1", service: other).save("other")
        try saveEach()
        XCTAssertEqual(FreshInstall.run(folder: folder, settings: [], service: service), .cleared)
        XCTAssertEqual(try item("posting-account-v1", service: other).load(), "other")
    }

    // MARK: The notification keys, in the App Group's Keychain group

    private func pushKeychain(_ account: String = PushKeychain.account) throws -> PushKeychain {
        let group = try XCTUnwrap(PushKeychain.appGroup, "The test host is the iPhone app, which has an App Group")
        return PushKeychain(group: group, account: account, service: service + ".push")
    }

    private var pushTarget: PushTarget {
        PushTarget(host: "pine.example", name: "Pine Street", relay: "https://push.fatline.tech",
                   handle: PushHandle(handle: String(repeating: "h", count: 22), secret: String(repeating: "s", count: 43)),
                   key: Data(repeating: 9, count: 32), choices: PushChoices())
    }

    func testANewInstallClearsTheNotificationKeysToo() throws {
        let keys = try pushKeychain()
        defer { _ = PushKeychain.removeAll(group: keys.group, service: keys.service) }
        try saveEach()
        try keys.save([pushTarget])
        XCTAssertEqual(FreshInstall.run(folder: folder, settings: [], service: service, pushGroup: keys.group, pushService: keys.service), .cleared)
        XCTAssertEqual(try keys.load(), [])
        XCTAssertNil(try item("posting-account-v1").load())
    }

    func testNotificationKeysAloneAreClearedToo() throws {
        let keys = try pushKeychain()
        defer { _ = PushKeychain.removeAll(group: keys.group, service: keys.service) }
        try keys.save([pushTarget])
        XCTAssertEqual(FreshInstall.run(folder: folder, settings: [], service: service, pushGroup: keys.group, pushService: keys.service), .cleared)
        XCTAssertEqual(try keys.load(), [])
    }

    func testAnUpdateKeepsTheNotificationKeys() throws {
        let keys = try pushKeychain()
        defer { _ = PushKeychain.removeAll(group: keys.group, service: keys.service) }
        try keys.save([pushTarget])
        XCTAssertEqual(FreshInstall.run(folder: folder, settings: ["installChecked"], service: service, pushGroup: keys.group,
                                        pushService: keys.service), .earlierInstall)
        XCTAssertEqual(try keys.load(), [pushTarget])
    }

    /// The extension reads them on a locked phone: after the first unlock, on this device only, in the
    /// group it shares with the app.
    func testNotificationKeysAreKeptForTheExtension() throws {
        let keys = try pushKeychain()
        let other = try pushKeychain(PushKeychain.account + "-check")
        defer { _ = PushKeychain.removeAll(group: keys.group, service: keys.service) }
        try keys.save([pushTarget])
        var second = pushTarget
        second = PushTarget(host: "cabin.example", name: "Cabin", relay: second.relay, handle: second.handle, key: second.key, choices: second.choices)
        try other.save([second])
        XCTAssertEqual(PushKeychain.loadAll(group: keys.group, service: keys.service).map(\.host).sorted(), ["cabin.example", "pine.example"],
                       "The extension finds every profile's")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keys.service,
            kSecAttrAccount as String: keys.account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var found: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &found), errSecSuccess)
        let attributes = try XCTUnwrap(found as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual((attributes[kSecAttrAccessGroup as String] as? String)?.hasSuffix(keys.group), true)
        try keys.save([])
        XCTAssertEqual(try keys.load(), [], "Saving none deletes the item")
    }
}
#endif

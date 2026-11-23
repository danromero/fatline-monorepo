import SwiftUI
import UIKit
import UserNotifications

/// Notifications on iPhone: the device token, iOS's permission and its one alert, the badge, and where
/// a tapped notification goes. The networks' side, `PushRegistrar`, runs inside `NetworkModel`; this
/// feeds it what iOS says. design/push-notifications-plan.md, Phase 3.
@MainActor
@Observable
final class PushCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushCenter()

    /// What iOS allows, read at launch and each time the app comes forward.
    private(set) var authorization = UNAuthorizationStatus.notDetermined
    /// Notifications are off for Fatline in iOS Settings.
    var offInSettings: Bool { authorization == .denied }
    private var allowed: Bool { [.authorized, .provisional, .ephemeral].contains(authorization) }
    /// Why iOS gave no device token this launch, for Debug's test notification.
    private(set) var registrationError: String?
    /// The last test notification seen arriving while the app was open, for Debug: its network, and
    /// whether the extension opened it. A note it couldn't open has no network.
    @ObservationIgnored private(set) var lastTest: (host: String?, opened: Bool, at: Date)?

    @ObservationIgnored private weak var networks: NetworkModel?
    @ObservationIgnored private var token: Data?
    /// A tap that launched the app before the networks were ready.
    @ObservationIgnored private var waitingTap: PushTap?
    @ObservationIgnored private let group = PushKeychain.appGroup

    /// As the app starts, before a tap that launched it is handed over: iOS gives a device token
    /// whether or not notifications may show.
    func start(_ application: UIApplication) {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
    }

    /// At each launch, and whenever iOS changes it.
    func tokenArrived(_ token: Data) {
        self.token = token
        let allowed = allowed
        Task { await networks?.pushReady(token: token, allowed: allowed) }
    }

    func registrationFailed(_ error: any Error) {
        registrationError = error.localizedDescription
        LaunchLog.record(.failed, "Notifications", "iOS gave no device token: \(error.localizedDescription)")
    }

    /// The app's networks, once they're loaded.
    func attach(_ networks: NetworkModel) {
        guard self.networks !== networks else { return }
        self.networks = networks
        if let group {
            let account = PushKeychain.account + E2EProfile.suffix + DevProfile.suffix
            networks.startPush(store: PushKeychain(group: group, account: account).store)
        }
        networks.networkGone = { [weak self] host in self?.clearBadge(host) }
        networks.postsRead = { host in Self.clearPosts(host) }
        if let tap = waitingTap {
            waitingTap = nil
            networks.open(tap)
        }
        Task { await refreshAuthorization() }
    }

    /// Reads what iOS allows; a change tells the networks.
    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        await networks?.pushReady(token: token, allowed: allowed)
    }

    /// iOS's own alert, with no screen of Fatline's before it: as Request sent appears, on Open after
    /// You're in, and for someone already in a network, once. iOS shows it only until it's answered.
    /// With `host` waiting on its admin, the join goes again with a handle, so it hears "You're in."
    func ask(for host: String?) async {
        await refreshAuthorization()
        if authorization == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorization()
            LaunchLog.record(.info, "Notifications", allowed ? "Allowed" : "Not allowed")
        }
        if let host, allowed { await networks?.pushForWaiting(host) }
    }

    /// Activity opened in `host`, so its replies and mentions are seen.
    func activityOpened(_ host: String) { clearBadge(host) }

    /// A network's feed was on screen, so its new posts are read: their notifications, such as a
    /// twice-a-day summary, leave Notification Center. Replies and mentions stay until they're opened.
    nonisolated static func clearPosts(_ host: String) {
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let read = delivered.compactMap { notification -> String? in
                guard let tap = PushTap(userInfo: notification.request.content.userInfo), tap.host == host, tap.kind == .post else { return nil }
                return notification.request.identifier
            }
            if !read.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: read) }
        }
    }

    private func clearBadge(_ host: String) {
        guard let group, let badge = PushBadge(group: group) else { return }
        let total = badge.clear(host)
        UNUserNotificationCenter.current().setBadgeCount(total) { _ in }
    }

    // MARK: UNUserNotificationCenterDelegate

    // The completion-handler forms, each answered on the main thread: iOS calls the async forms' handlers
    // from wherever the task ends, and UIKit stops the app if that's off the main thread while it comes
    // forward from a tap.

    /// In the app, a notification for the thread on screen doesn't show; any other is a banner, and the
    /// dots refresh.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let tap = PushTap(userInfo: notification.request.content.userInfo)
        let unopened = tap == nil && notification.request.content.body == PushDelivery.fallback.body
        nonisolated(unsafe) let answer = completionHandler
        DispatchQueue.main.async {
            answer(MainActor.assumeIsolated { self.present(tap, unopened: unopened) })
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let tap = PushTap(userInfo: response.notification.request.content.userInfo)
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.opened(tap) }
            done()
        }
    }

    private func present(_ tap: PushTap?, unopened: Bool) -> UNNotificationPresentationOptions {
        let shown: UNNotificationPresentationOptions = [.banner, .list, .sound, .badge]
        if tap?.kind == .test || unopened { lastTest = (tap?.host, !unopened, .now) }
        guard let tap, tap.kind != .test, let networks else { return shown }
        Task {
            await networks.refresh()
            await networks.checkOthers()
        }
        return networks.isShowing(tap) ? [] : shown
    }

    private func opened(_ tap: PushTap?) {
        guard let tap else { return }
        LaunchLog.record(.info, "Opened a notification", tap.kind.rawValue, scope: tap.host)
        if let networks { networks.open(tap) } else { waitingTap = tap }
    }
}

/// The app delegate, for what iOS still hands only to one: the device token, and the notification
/// delegate set before a tap that launched the app arrives.
final class FatlineAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The unit tests' host doesn't register.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { PushCenter.shared.start(application) }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.shared.tokenArrived(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushCenter.shared.registrationFailed(error)
    }
}

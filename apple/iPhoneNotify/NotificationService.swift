import UserNotifications

/// Opens each network's sealed note and writes its words: the network's name as this iPhone saved it,
/// and what happened, from `PushNote`. The keys are in the Keychain the app shares through its App
/// Group (`PushKeychain`), readable once the phone has been unlocked since it started. If anything
/// fails, the note shows "Something new in a network." design/push-notifications-plan.md, Phase 3.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        let group = PushKeychain.appGroup
        let targets = group.map { PushKeychain.loadAll(group: $0) } ?? []
        let delivery = PushDelivery.make(userInfo: request.content.userInfo, targets: targets)
        content.title = delivery.title
        content.body = delivery.body
        content.subtitle = ""
        // Only what a tap needs, written here from the target, never the sealed note or anything the
        // payload carried besides.
        content.userInfo = delivery.tap?.userInfo ?? [:]
        if let thread = delivery.thread { content.threadIdentifier = thread }
        if delivery.countsOnBadge, let group, let badge = PushBadge(group: group) {
            content.badge = NSNumber(value: badge.add(delivery.thread ?? ""))
        } else {
            content.badge = nil
        }
        contentHandler(content)
    }
}

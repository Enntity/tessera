import AppKit
import TesseraKit
import UserNotifications

/// Posts a system notification when a tile starts needing the user while Tessera isn't frontmost;
/// clicking it opens that tile in place.
@MainActor
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var notified: Set<String> = []
    private let onOpen: (String) -> Void

    init(onOpen: @escaping (String) -> Void) {
        self.onOpen = onOpen
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func update(with tiles: [TileInfo]) {
        let waiting = tiles.filter { $0.attention }
        let waitingIds = Set(waiting.map(\.id))
        // Forget tiles that were seen, so their next event notifies again.
        notified.formIntersection(waitingIds)
        guard !NSApp.isActive else {
            notified.formUnion(waitingIds)
            return
        }
        for tile in waiting where !notified.contains(tile.id) {
            notified.insert(tile.id)
            let content = UNMutableNotificationContent()
            content.title = tile.activity == .needsInput ? "\(tile.title) needs you" : "\(tile.title) is \(tile.activity.label.lowercased())"
            content.body = tile.detail ?? tile.subtitle
            content.userInfo = ["tile": tile.id]
            content.sound = tile.activity == .needsInput ? .default : nil
            content.threadIdentifier = tile.flavor.rawValue
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: tile.id, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["tile"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            onOpen(id)
        }
    }
}

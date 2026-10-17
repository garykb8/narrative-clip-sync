import Foundation
import UserNotifications

/// Posts sync results as notifications; the "Clear Camera" action calls `onClearCamera`.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onClearCamera: () -> Void = {}

    private static let syncedCategory = "SYNCED"
    private static let clearAction = "CLEAR_CAMERA"
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        let clear = UNNotificationAction(identifier: Self.clearAction, title: String(localized: "Clear Camera"), options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.syncedCategory, actions: [clear], intentIdentifiers: []),
        ])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postSynced(newPhotos: Int, photosReadyToDelete: Int) {
        let content = UNMutableNotificationContent()
        content.title = newPhotos > 0
            ? String(localized: "Synced \(newPhotos) new photos")
            : String(localized: "All camera photos are backed up")
        if photosReadyToDelete > 0 {
            content.body = String(localized: "\(photosReadyToDelete) photos on the camera are safely backed up to your Mac and can be cleared.")
            content.categoryIdentifier = Self.syncedCategory
        }
        post(content)
    }

    func postCleared(deletedFiles: Int, newPhotos: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Camera Cleared")
        content.body = newPhotos > 0
            ? String(localized: "Also synced \(newPhotos) new photos; deleted \(deletedFiles) verified files from the camera.")
            : String(localized: "Deleted \(deletedFiles) verified files from the camera.")
        post(content)
    }

    private func post(_ content: UNMutableNotificationContent) {
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.clearAction {
            DispatchQueue.main.async { self.onClearCamera() }
        }
        completionHandler()
    }

    /// Show banners even though a menu bar app counts as "active".
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

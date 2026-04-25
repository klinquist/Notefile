import CloudKit
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
final class NotesyncAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let handled = Self.postCloudKitChangeNotification(from: userInfo)
        completionHandler(handled ? .newData : .noData)
    }

    private static func postCloudKitChangeNotification(from userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.subscriptionID == NotesyncCloudKitSubscription.recordZoneSubscriptionID else {
            return false
        }

        NotificationCenter.default.post(name: .notesyncCloudKitRemoteChange, object: nil)
        return true
    }
}
#elseif os(macOS)
final class NotesyncAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        let cloudKitUserInfo = Dictionary(uniqueKeysWithValues: userInfo.map { (AnyHashable($0.key), $0.value) })
        Self.postCloudKitChangeNotification(from: cloudKitUserInfo)
    }

    private static func postCloudKitChangeNotification(from userInfo: [AnyHashable: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.subscriptionID == NotesyncCloudKitSubscription.recordZoneSubscriptionID else {
            return
        }

        NotificationCenter.default.post(name: .notesyncCloudKitRemoteChange, object: nil)
    }
}
#endif

@main
struct NotesyncApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(NotesyncAppDelegate.self) private var appDelegate
#elseif os(macOS)
    @NSApplicationDelegateAdaptor(NotesyncAppDelegate.self) private var appDelegate
#endif

    @StateObject private var repository: NoteRepository
#if os(macOS)
    @StateObject private var localMirrorSyncService: LocalMirrorSyncService
#endif

    init() {
        let repository = NoteRepository()
        _repository = StateObject(wrappedValue: repository)
#if os(macOS)
        _localMirrorSyncService = StateObject(wrappedValue: LocalMirrorSyncService(repository: repository))
#endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(repository)
#if os(macOS)
                .environmentObject(localMirrorSyncService)
#endif
        }
#if os(macOS)
        Settings {
            MacSyncSettingsView()
                .environmentObject(repository)
                .environmentObject(localMirrorSyncService)
        }
#endif
    }
}

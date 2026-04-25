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
    private var statusItem: NSStatusItem?
    private var userDefaultsObserver: NSObjectProtocol?
    private var windowMiniaturizeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
        setupMacMinimizeBehavior()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        let cloudKitUserInfo = Dictionary(uniqueKeysWithValues: userInfo.map { (AnyHashable($0.key), $0.value) })
        Self.postCloudKitChangeNotification(from: cloudKitUserInfo)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    private func setupMacMinimizeBehavior() {
        applyMacMinimizeBehavior()

        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyMacMinimizeBehavior()
        }

        windowMiniaturizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowDidMiniaturize(notification)
        }
    }

    private func applyMacMinimizeBehavior() {
        let behavior = currentMacMinimizeBehavior()
        switch behavior {
        case .dock:
            removeStatusItem()
            NSApplication.shared.setActivationPolicy(.regular)

        case .menuBar:
            configureStatusItem()
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    private func currentMacMinimizeBehavior() -> MacMinimizeBehavior {
        let rawValue = UserDefaults.standard.string(forKey: AppPreferences.macMinimizeBehaviorKey)
            ?? AppPreferences.defaultMacMinimizeBehavior.rawValue
        return AppPreferences.normalizedMacMinimizeBehavior(rawValue)
    }

    private func configureStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Notesync")
        item.button?.imagePosition = .imageOnly
        item.menu = statusMenu()
        statusItem = item
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Notesync", action: #selector(showNotesyncFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettingsFromMenu), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notesync", action: #selector(quitNotesyncFromMenu), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }

        return menu
    }

    private func handleWindowDidMiniaturize(_ notification: Notification) {
        guard currentMacMinimizeBehavior() == .menuBar,
              let window = notification.object as? NSWindow,
              !window.isReleasedWhenClosed else {
            return
        }

        window.deminiaturize(nil)
        window.orderOut(nil)
    }

    @objc private func showNotesyncFromMenu() {
        showMainWindow()
    }

    @objc private func showSettingsFromMenu() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitNotesyncFromMenu() {
        NSApplication.shared.terminate(nil)
    }

    private func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let visibleMainWindows = NSApplication.shared.windows.filter { window in
            !window.isMiniaturized && !window.isSheet && !window.title.localizedCaseInsensitiveContains("Settings")
        }

        if let window = visibleMainWindows.first {
            window.makeKeyAndOrderFront(nil)
            return
        }

        if let window = NSApplication.shared.windows.first(where: { !$0.isSheet && !$0.title.localizedCaseInsensitiveContains("Settings") }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        NSApplication.shared.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
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

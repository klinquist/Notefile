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
@MainActor
final class NotesyncAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private weak var menuBarRestoreWindow: NSWindow?
    private var appliedMacMinimizeBehavior: MacMinimizeBehavior?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
        setupMacMinimizeBehavior()
    }

    nonisolated func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        let cloudKitUserInfo = Dictionary(uniqueKeysWithValues: userInfo.map { (AnyHashable($0.key), $0.value) })
        Self.postCloudKitChangeNotification(from: cloudKitUserInfo)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    private func setupMacMinimizeBehavior() {
        applyMacMinimizeBehavior()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMiniaturize(_:)),
            name: NSWindow.didMiniaturizeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func applyMacMinimizeBehavior() {
        let behavior = currentMacMinimizeBehavior()
        appliedMacMinimizeBehavior = behavior

        switch behavior {
        case .dock:
            leaveMenuBarMode()

        case .menuBar:
            leaveMenuBarMode()
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
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func enterMenuBarMode() {
        configureStatusItem()
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func leaveMenuBarMode() {
        removeStatusItem()
        NSApplication.shared.setActivationPolicy(.regular)
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
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

        menuBarRestoreWindow = window
        enterMenuBarMode()
    }

    @objc nonisolated private func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.handleUserDefaultsDidChange()
        }
    }

    private func handleUserDefaultsDidChange() {
        let behavior = currentMacMinimizeBehavior()
        guard behavior != appliedMacMinimizeBehavior else { return }

        applyMacMinimizeBehavior()
    }

    @objc private func windowDidMiniaturize(_ notification: Notification) {
        handleWindowDidMiniaturize(notification)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            statusMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        } else {
            showMainWindow()
        }
    }

    @objc private func quitNotesyncFromMenu() {
        NSApplication.shared.terminate(nil)
    }

    private func showMainWindow() {
        let targetWindow = menuBarRestoreWindow ?? restorableMainWindow()
        leaveMenuBarMode()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.restoreMainWindow(targetWindow)
        }
    }

    private func restoreMainWindow(_ targetWindow: NSWindow?) {
        NSApplication.shared.unhide(nil)

        if let window = targetWindow ?? restorableMainWindow() {
            restore(window)
            return
        }

        NSApplication.shared.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
    }

    private func restorableMainWindow() -> NSWindow? {
        let visibleMainWindows = NSApplication.shared.windows.filter { window in
            !window.isMiniaturized && !window.isSheet && !window.title.localizedCaseInsensitiveContains("Settings")
        }

        if let window = visibleMainWindows.first {
            return window
        }

        return NSApplication.shared.windows.first {
            !$0.isSheet && !$0.title.localizedCaseInsensitiveContains("Settings")
        }
    }

    private func restore(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        menuBarRestoreWindow = nil
    }

    nonisolated private static func postCloudKitChangeNotification(from userInfo: [AnyHashable: Any]) {
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

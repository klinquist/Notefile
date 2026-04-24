import SwiftUI

@main
struct NotefileApp: App {
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

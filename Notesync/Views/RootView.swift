import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum NoteFontOption: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif
    case monospaced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }

    func swiftUIFont(size: Double) -> Font {
        .system(size: size, design: design)
    }

#if os(iOS)
    func uiFont(size: Double) -> UIFont {
        let resolvedSize = CGFloat(size)
        switch self {
        case .system:
            return .systemFont(ofSize: resolvedSize)
        case .rounded:
            let descriptor = UIFont.systemFont(ofSize: resolvedSize).fontDescriptor.withDesign(.rounded)
            return descriptor.map { UIFont(descriptor: $0, size: resolvedSize) } ?? .systemFont(ofSize: resolvedSize)
        case .serif:
            let descriptor = UIFont.systemFont(ofSize: resolvedSize).fontDescriptor.withDesign(.serif)
            return descriptor.map { UIFont(descriptor: $0, size: resolvedSize) } ?? .systemFont(ofSize: resolvedSize)
        case .monospaced:
            return .monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
        }
    }
#elseif os(macOS)
    func nsFont(size: Double) -> NSFont {
        let resolvedSize = CGFloat(size)
        switch self {
        case .system:
            return .systemFont(ofSize: resolvedSize)
        case .rounded:
            let descriptor = NSFont.systemFont(ofSize: resolvedSize).fontDescriptor.withDesign(.rounded)
            return descriptor.flatMap { NSFont(descriptor: $0, size: resolvedSize) } ?? .systemFont(ofSize: resolvedSize)
        case .serif:
            let descriptor = NSFont.systemFont(ofSize: resolvedSize).fontDescriptor.withDesign(.serif)
            return descriptor.flatMap { NSFont(descriptor: $0, size: resolvedSize) } ?? .systemFont(ofSize: resolvedSize)
        case .monospaced:
            return .monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
        }
    }
#endif
}

enum BrowserDisplayMode: String, CaseIterable, Identifiable {
    case cards
    case list

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cards: "Cards"
        case .list: "List"
        }
    }
}

enum BrowserCardSizeOption: Double, CaseIterable, Identifiable {
    case small = 120
    case medium = 145
    case large = 170
    case extraLarge = 215

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "XL"
        }
    }
}

#if os(macOS)
enum MacMinimizeBehavior: String, CaseIterable, Identifiable {
    case dock
    case menuBar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dock: "Dock"
        case .menuBar: "Menu Bar"
        }
    }
}
#endif

enum AppPreferences {
    static let newEntryThresholdMinutesKey = "Settings.NewEntryThresholdMinutes"
    static let noteFontSizeKey = "Settings.NoteFontSize"
    static let noteFontKey = "Settings.NoteFont"
    static let browserCardSizeKey = "Settings.BrowserCardSize"
    static let browserDisplayModeKey = "Settings.BrowserDisplayMode"
#if os(macOS)
    static let macMinimizeBehaviorKey = "Settings.MacMinimizeBehavior"
#endif

    static let defaultNewEntryThresholdMinutes = 0
    static let defaultNoteFontSize = 17.0
    static let defaultNoteFont = NoteFontOption.system
    static let defaultBrowserCardSize = BrowserCardSizeOption.large.rawValue
    static let defaultBrowserDisplayMode = BrowserDisplayMode.cards
#if os(macOS)
    static let defaultMacMinimizeBehavior = MacMinimizeBehavior.dock
#endif
    static let minimumNoteFontSize = 12.0
    static let maximumNoteFontSize = 30.0

    static func normalizedNewEntryThresholdMinutes(_ value: Int) -> Int {
        min(max(value, 0), 60)
    }

    static func normalizedNoteFontSize(_ value: Double) -> Double {
        min(max(value, minimumNoteFontSize), maximumNoteFontSize)
    }

    static func normalizedNoteFont(_ value: String) -> NoteFontOption {
        NoteFontOption(rawValue: value) ?? defaultNoteFont
    }

    static func normalizedBrowserCardSize(_ value: Double) -> Double {
        BrowserCardSizeOption.allCases.min { first, second in
            abs(first.rawValue - value) < abs(second.rawValue - value)
        }?.rawValue ?? defaultBrowserCardSize
    }

    static func normalizedBrowserDisplayMode(_ value: String) -> BrowserDisplayMode {
        BrowserDisplayMode(rawValue: value) ?? defaultBrowserDisplayMode
    }

#if os(macOS)
    static func normalizedMacMinimizeBehavior(_ value: String) -> MacMinimizeBehavior {
        MacMinimizeBehavior(rawValue: value) ?? defaultMacMinimizeBehavior
    }
#endif

    static func currentNewEntryThresholdMinutes() -> Int {
        normalizedNewEntryThresholdMinutes(
            UserDefaults.standard.object(forKey: newEntryThresholdMinutesKey) as? Int
                ?? defaultNewEntryThresholdMinutes
        )
    }
}

struct NotesyncSettingsView: View {
    @AppStorage(AppPreferences.newEntryThresholdMinutesKey)
    private var newEntryThresholdMinutes = AppPreferences.defaultNewEntryThresholdMinutes

    @AppStorage(AppPreferences.noteFontSizeKey)
    private var noteFontSize = AppPreferences.defaultNoteFontSize

    @AppStorage(AppPreferences.noteFontKey)
    private var noteFontRawValue = AppPreferences.defaultNoteFont.rawValue

    @AppStorage(AppPreferences.browserCardSizeKey)
    private var browserCardSize = AppPreferences.defaultBrowserCardSize

    @AppStorage(AppPreferences.browserDisplayModeKey)
    private var browserDisplayModeRawValue = AppPreferences.defaultBrowserDisplayMode.rawValue

#if os(macOS)
    @AppStorage(AppPreferences.macMinimizeBehaviorKey)
    private var macMinimizeBehaviorRawValue = AppPreferences.defaultMacMinimizeBehavior.rawValue

    @EnvironmentObject private var localMirrorSyncService: LocalMirrorSyncService
#endif

    var body: some View {
        Form {
            notesSection
            browserSection

#if os(macOS)
            macSection
            mirrorSection
#endif
        }
#if os(macOS)
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 540, minHeight: 420)
#endif
    }

    private var notesSection: some View {
        Section("Notes") {
            VStack(alignment: .leading, spacing: 6) {
                thresholdControl

                Text(thresholdExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Note Font Size") {
                    Text("\(Int(noteFontSize.rounded()))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(value: fontSizeBinding, in: AppPreferences.minimumNoteFontSize...AppPreferences.maximumNoteFontSize, step: 1)

                Text("Preview text size")
                    .font(.system(size: fontSizeBinding.wrappedValue))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 10) {
                Picker("Note Font", selection: fontBinding) {
                    ForEach(NoteFontOption.allCases) { option in
                        Text(option.label)
                            .tag(option.rawValue)
                    }
                }

                Text("Preview note font")
                    .font(noteFont.swiftUIFont(size: fontSizeBinding.wrappedValue))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var browserSection: some View {
        Section("Browser") {
            Picker("View Style", selection: browserDisplayModeBinding) {
                ForEach(BrowserDisplayMode.allCases) { mode in
                    Text(mode.label)
                        .tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)

            if AppPreferences.normalizedBrowserDisplayMode(browserDisplayModeRawValue) == .cards {
                Picker("Card Size", selection: browserCardSizeBinding) {
                    ForEach(BrowserCardSizeOption.allCases) { size in
                        Text(size.label)
                            .tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("Smaller cards fit more folders and notes on screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var thresholdControl: some View {
#if os(macOS)
        HStack(spacing: 12) {
            Text("New Entry Threshold")

            Spacer(minLength: 12)

            Text(thresholdLabel)
                .foregroundStyle(.secondary)

            Stepper("", value: thresholdBinding, in: 0...60)
                .labelsHidden()
        }
#else
        Stepper(value: thresholdBinding, in: 0...60) {
            LabeledContent("New Entry Threshold") {
                Text(thresholdLabel)
                    .foregroundStyle(.secondary)
            }
        }
#endif
    }

#if os(macOS)
    private var macSection: some View {
        Section("Mac") {
            Picker("Minimize To", selection: macMinimizeBehaviorBinding) {
                ForEach(MacMinimizeBehavior.allCases) { behavior in
                    Text(behavior.label)
                        .tag(behavior.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Text(macMinimizeBehavior == .menuBar ? "Notesync stays in the menu bar and hides its Dock icon." : "Notesync uses the standard Dock icon and Dock minimization.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        }
    }

    private var mirrorSection: some View {
        Section("Mirror") {
            LabeledContent("Mirror Folder") {
                Text(localMirrorSyncService.mirroredFolderURL?.path ?? "Not configured")
                    .foregroundStyle(.secondary)
            }

            Text(localMirrorSyncService.statusText)
                .foregroundStyle(.secondary)

            HStack {
                Button("Choose Folder") {
                    localMirrorSyncService.chooseFolder()
                }

                Button("Sync Now") {
                    Task {
                        await localMirrorSyncService.syncNow()
                    }
                }
                .disabled(localMirrorSyncService.mirroredFolderURL == nil)
            }
        }
    }
#endif

    private var thresholdBinding: Binding<Int> {
        Binding(
            get: { AppPreferences.normalizedNewEntryThresholdMinutes(newEntryThresholdMinutes) },
            set: { newEntryThresholdMinutes = AppPreferences.normalizedNewEntryThresholdMinutes($0) }
        )
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { AppPreferences.normalizedNoteFontSize(noteFontSize) },
            set: { noteFontSize = AppPreferences.normalizedNoteFontSize($0) }
        )
    }

    private var browserCardSizeBinding: Binding<Double> {
        Binding(
            get: { AppPreferences.normalizedBrowserCardSize(browserCardSize) },
            set: { browserCardSize = AppPreferences.normalizedBrowserCardSize($0) }
        )
    }

    private var browserDisplayModeBinding: Binding<String> {
        Binding(
            get: { AppPreferences.normalizedBrowserDisplayMode(browserDisplayModeRawValue).rawValue },
            set: { browserDisplayModeRawValue = AppPreferences.normalizedBrowserDisplayMode($0).rawValue }
        )
    }

    private var fontBinding: Binding<String> {
        Binding(
            get: { noteFont.rawValue },
            set: { noteFontRawValue = AppPreferences.normalizedNoteFont($0).rawValue }
        )
    }

#if os(macOS)
    private var macMinimizeBehaviorBinding: Binding<String> {
        Binding(
            get: { macMinimizeBehavior.rawValue },
            set: { macMinimizeBehaviorRawValue = AppPreferences.normalizedMacMinimizeBehavior($0).rawValue }
        )
    }

    private var macMinimizeBehavior: MacMinimizeBehavior {
        AppPreferences.normalizedMacMinimizeBehavior(macMinimizeBehaviorRawValue)
    }
#endif

    private var noteFont: NoteFontOption {
        AppPreferences.normalizedNoteFont(noteFontRawValue)
    }

    private var thresholdLabel: String {
        let value = thresholdBinding.wrappedValue
        if value == 0 {
            return "Disabled"
        }
        if value == 1 {
            return "1 minute"
        }
        return "\(value) minutes"
    }

    private var thresholdExplanation: String {
        let value = thresholdBinding.wrappedValue
        if value == 0 {
            return "Always start a new entry when reopening a note."
        }
        return "If you reopen a note within \(thresholdLabel.lowercased()) of the last edit, Notesync continues the previous entry instead of starting a new one."
    }
}

struct RootView: View {
    enum Route: Hashable {
        case folder(String)
        case note(String, UUID?)
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case alphabetical
        case recent

        var id: String { rawValue }

        var label: String {
            switch self {
            case .alphabetical: "A-Z"
            case .recent: "Recent"
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var repository: NoteRepository
    @State private var path: [Route] = []
    @State private var showingCreateNote = false
    @State private var showingCreateFolder = false
    @State private var showingSettings = false
    @State private var showingSearch = false
    @State private var itemPendingDeletion: BrowserItem?
    @State private var itemPendingEdit: BrowserItem?
    @State private var browserRefreshTask: Task<Void, Never>?
    @AppStorage("RootView.SortMode") private var sortModeRawValue = SortMode.alphabetical.rawValue

    var body: some View {
        NavigationStack(path: $path) {
            BrowserGridScreen(
                isRoot: true,
                currentFolderRelativePath: nil,
                title: currentFolderName ?? "Notesync",
                subtitle: currentFolderName == nil ? repository.storageDescription : nil,
                items: sortedItems(in: currentFolderPath),
                favoriteItems: sortedFavoriteItems,
                sortMode: sortMode,
                sortSelection: sortSelection,
                onSelect: openItem,
                onRequestEdit: { itemPendingEdit = $0 },
                onRequestDelete: { itemPendingDeletion = $0 },
                onToggleFavorite: toggleFavorite,
                onCreateFolder: { showingCreateFolder = true },
                onCreateNote: { showingCreateNote = true },
                onOpenSettings: { showingSettings = true },
                onOpenSearch: { showingSearch = true },
                onSelectSearchResult: openSearchResult,
                onRenameTitle: nil
            )
#if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
#endif
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .folder(relativePath):
                    BrowserGridScreen(
                        isRoot: false,
                        currentFolderRelativePath: relativePath,
                        title: URL(fileURLWithPath: relativePath).lastPathComponent,
                        subtitle: nil,
                        items: sortedItems(in: relativePath),
                        favoriteItems: [],
                        sortMode: sortMode,
                        sortSelection: sortSelection,
                        onSelect: openItem,
                        onRequestEdit: { itemPendingEdit = $0 },
                        onRequestDelete: { itemPendingDeletion = $0 },
                        onToggleFavorite: toggleFavorite,
                        onCreateFolder: { showingCreateFolder = true },
                        onCreateNote: { showingCreateNote = true },
                        onOpenSettings: nil,
                        onOpenSearch: nil,
                        onSelectSearchResult: openSearchResult,
                        onRenameTitle: { newName in
                            try await renameFolder(relativePath: relativePath, to: newName)
                        }
                    )
#if os(iOS)
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
#else
                    .navigationTitle(URL(fileURLWithPath: relativePath).lastPathComponent)
#endif
                case let .note(relativePath, targetEntryID):
                    NoteEditorView(notePath: relativePath, initialFocusEntryID: targetEntryID) { updatedPath in
                        replaceCurrentRoute(with: .note(updatedPath, nil))
                    }
                }
            }
        }
        .toolbar {
#if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
#endif
        }
        .task {
            await repository.loadBrowser()
        }
#if os(macOS)
        .task(id: scenePhase) {
            await runMacCloudRefreshLoop()
        }
#endif
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            scheduleBrowserRefresh()
        }
#if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            scheduleBrowserRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
            scheduleBrowserRefresh()
        }
#endif
        .sheet(isPresented: $showingCreateFolder) {
            CreateItemSheet(
                mode: .folder,
                parentLabel: selectedFolderName,
                suggestedAccentStyle: suggestedAccentStyle,
                submit: createFolder
            )
        }
        .sheet(isPresented: $showingCreateNote) {
            CreateItemSheet(
                mode: .note,
                parentLabel: selectedFolderName,
                suggestedAccentStyle: suggestedAccentStyle,
                submit: createNote
            )
        }
        .sheet(item: $itemPendingEdit) { item in
            EditItemSheet(
                kind: item.kind,
                initialName: item.name,
                initialAccentStyle: item.accentStyle
            ) { name, accentStyle in
                try await update(item, name: name, accentStyle: accentStyle)
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                NotesyncSettingsView()
                    .navigationTitle("Settings")
#if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showingSettings = false
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showingSearch) {
            NavigationStack {
                NoteSearchSheet { result in
                    openSearchResult(result)
                }
            }
        }
        .alert("Storage Issue", isPresented: Binding(
            get: { repository.lastErrorMessage != nil },
            set: { if !$0 { repository.lastErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(repository.lastErrorMessage ?? "")
        }
        .confirmationDialog(
            itemPendingDeletion.map(deleteConfirmationTitle(for:)) ?? "Delete Item",
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { if !$0 { itemPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let itemPendingDeletion {
                Button(deleteActionLabel(for: itemPendingDeletion), role: .destructive) {
                    delete(itemPendingDeletion)
                }
            }

            Button("Cancel", role: .cancel) {
                itemPendingDeletion = nil
            }
        } message: {
            if let itemPendingDeletion {
                Text(deleteConfirmationMessage(for: itemPendingDeletion))
            }
        }
    }

    private var sortMode: SortMode {
        get { SortMode(rawValue: sortModeRawValue) ?? .alphabetical }
        set { sortModeRawValue = newValue.rawValue }
    }

    private var sortSelection: Binding<SortMode> {
        Binding(
            get: { sortMode },
            set: { sortModeRawValue = $0.rawValue }
        )
    }

    private var currentFolderPath: String? {
        for route in path.reversed() {
            if case let .folder(relativePath) = route {
                return relativePath
            }
        }
        return nil
    }

    private var currentFolderName: String? {
        currentFolderPath.map { ($0 as NSString).lastPathComponent }
    }

    private func sortedItems(in folderPath: String?) -> [BrowserItem] {
        let items = itemsInFolder(folderPath)
        return sorted(items)
    }

    private var sortedFavoriteItems: [BrowserItem] {
        sorted(flattenedItems(repository.browserItems).filter(\.isFavorite))
    }

    private func sorted(_ items: [BrowserItem]) -> [BrowserItem] {
        switch sortMode {
        case .alphabetical:
            return items.sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .folder
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .recent:
            return items.sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                if lhs.kind != rhs.kind {
                    return lhs.kind == .folder
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func flattenedItems(_ items: [BrowserItem]) -> [BrowserItem] {
        items.flatMap { item in
            [item] + flattenedItems(item.children)
        }
    }

    private func itemsInFolder(_ folderPath: String?) -> [BrowserItem] {
        guard let folderPath else { return repository.browserItems }
        return findFolder(relativePath: folderPath, in: repository.browserItems)?.children ?? []
    }

    private func findFolder(relativePath: String, in items: [BrowserItem]) -> BrowserItem? {
        for item in items where item.kind == .folder {
            if item.relativePath == relativePath {
                return item
            }
            if let nested = findFolder(relativePath: relativePath, in: item.children) {
                return nested
            }
        }
        return nil
    }

    private var selectedFolderName: String? {
        currentFolderName
    }

    private var suggestedAccentStyle: AccentStyle {
        let styles = AccentStyle.allCases
        let usedStyles = itemsInFolder(currentFolderPath).map(\.accentStyle)

        if let firstUnusedStyle = styles.first(where: { style in
            !usedStyles.contains(style)
        }) {
            return firstUnusedStyle
        }

        let index = usedStyles.count % styles.count
        return styles[index]
    }

    private func openItem(_ item: BrowserItem) {
        switch item.kind {
        case .folder:
            path.append(.folder(item.relativePath))
        case .note:
            path.append(.note(item.relativePath, nil))
        }
    }

    private func openSearchResult(_ result: NoteSearchResult) {
        showingSearch = false
        switch result.kind {
        case .folder:
            path = folderRouteChain(for: result.relativePath)
        case .note, .entry:
            var routes = folderRouteChain(for: parentPath(for: result.relativePath))
            routes.append(.note(result.relativePath, result.entryID))
            path = routes
        }
    }

    private func replaceCurrentRoute(with route: Route) {
        guard !path.isEmpty else {
            path = [route]
            return
        }
        path[path.count - 1] = route
    }

    private func folderRouteChain(for folderRelativePath: String?) -> [Route] {
        guard let folderRelativePath, !folderRelativePath.isEmpty else { return [] }

        let pathComponents = (folderRelativePath as NSString).pathComponents.filter { $0 != "/" && !$0.isEmpty }
        var currentPath = ""
        return pathComponents.map { component in
            currentPath = currentPath.isEmpty
                ? component
                : (currentPath as NSString).appendingPathComponent(component)
            return .folder(currentPath)
        }
    }

    private func parentPath(for relativePath: String) -> String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? nil : parent
    }

    private func renameFolder(relativePath: String, to newName: String) async throws {
        let updatedRelativePath = try await repository.renameFolder(relativePath: relativePath, name: newName)
        replaceCurrentRoute(with: .folder(updatedRelativePath))
    }

    private func createFolder(name: String, emoji: String, accentStyle: AccentStyle) async throws {
        let relativePath = try await repository.createFolder(
            name: name,
            emoji: emoji,
            accentStyle: accentStyle,
            parentRelativePath: currentFolderPath
        )
        path.append(.folder(relativePath))
    }

    private func createNote(name: String, emoji: String, accentStyle: AccentStyle) async throws {
        let relativePath = try await repository.createNote(
            title: name,
            emoji: emoji,
            accentStyle: accentStyle,
            parentRelativePath: currentFolderPath
        )
        path.append(.note(relativePath, nil))
    }

    private func update(_ item: BrowserItem, name: String, accentStyle: AccentStyle) async throws {
        switch item.kind {
        case .folder:
            _ = try await repository.updateFolder(relativePath: item.relativePath, name: name, accentStyle: accentStyle)
        case .note:
            _ = try await repository.updateNote(relativePath: item.relativePath, title: name, accentStyle: accentStyle)
        }
    }

    private func delete(_ item: BrowserItem) {
        itemPendingDeletion = nil
        Task {
            do {
                try await repository.delete(item: item)
            } catch {
                await MainActor.run {
                    repository.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func toggleFavorite(_ item: BrowserItem) {
        Task {
            do {
                try repository.setFavorite(!item.isFavorite, for: item)
            } catch {
                await MainActor.run {
                    repository.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func deleteConfirmationTitle(for item: BrowserItem) -> String {
        switch item.kind {
        case .folder:
            return "Delete Folder?"
        case .note:
            return "Delete Note?"
        }
    }

    private func deleteActionLabel(for item: BrowserItem) -> String {
        switch item.kind {
        case .folder:
            return "Delete Folder"
        case .note:
            return "Delete Note"
        }
    }

    private func deleteConfirmationMessage(for item: BrowserItem) -> String {
        switch item.kind {
        case .folder:
            return "Delete \"\(item.name)\" and everything inside it?"
        case .note:
            return "Delete \"\(item.name)\"?"
        }
    }

    private func scheduleBrowserRefresh() {
        browserRefreshTask?.cancel()
        browserRefreshTask = Task {
            await repository.loadBrowser()
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await repository.loadBrowser()
        }
    }

#if os(macOS)
    private func runMacCloudRefreshLoop() async {
        var wasForeground = macCloudRefreshIsForeground()
        var lastBackgroundRefresh = Date()

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }

            if macCloudRefreshIsForeground() {
                wasForeground = true
                await repository.loadBrowser()
            } else {
                if wasForeground {
                    lastBackgroundRefresh = Date()
                    wasForeground = false
                }

                guard Date().timeIntervalSince(lastBackgroundRefresh) >= 15 * 60 else { continue }
                lastBackgroundRefresh = Date()
                await repository.loadBrowser()
            }
        }
    }

    private func macCloudRefreshIsForeground() -> Bool {
        scenePhase == .active
            && NSApplication.shared.isActive
            && NSApplication.shared.windows.contains { $0.isVisible && !$0.isMiniaturized }
    }
#endif
}

private struct BrowserGridScreen: View {
    let isRoot: Bool
    let currentFolderRelativePath: String?
    let title: String
    let subtitle: String?
    let items: [BrowserItem]
    let favoriteItems: [BrowserItem]
    let sortMode: RootView.SortMode
    let sortSelection: Binding<RootView.SortMode>
    let onSelect: (BrowserItem) -> Void
    let onRequestEdit: (BrowserItem) -> Void
    let onRequestDelete: (BrowserItem) -> Void
    let onToggleFavorite: (BrowserItem) -> Void
    let onCreateFolder: () -> Void
    let onCreateNote: () -> Void
    let onOpenSettings: (() -> Void)?
    let onOpenSearch: (() -> Void)?
    let onSelectSearchResult: ((NoteSearchResult) -> Void)?
    let onRenameTitle: ((String) async throws -> Void)?

#if os(iOS)
    @State private var isCreateMenuExpanded = false
#endif
    @EnvironmentObject private var repository: NoteRepository
    @State private var titleDraft = ""
    @State private var isEditingTitle = false
    @State private var isRenaming = false
    @State private var searchQuery = ""
    @State private var searchResults: [NoteSearchResult] = []
    @FocusState private var isTitleFieldFocused: Bool
    @AppStorage(AppPreferences.browserCardSizeKey) private var browserCardSize = AppPreferences.defaultBrowserCardSize
    @AppStorage(AppPreferences.browserDisplayModeKey) private var browserDisplayModeRawValue = AppPreferences.defaultBrowserDisplayMode.rawValue

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if isRoot {
                    homeHero
                } else {
                    folderHeader
                }

                sortHeader

                if isShowingSearchResults {
                    searchResultsContent
                } else {
                    if isRoot, !favoriteItems.isEmpty {
                        favoritesSection
                    }

                    if items.isEmpty {
                        emptyState
                    } else {
                        itemCollection(items)
                    }
                }
#if os(iOS)
                Color.clear
                    .frame(height: 108)
#endif
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .padding(.top, isRoot ? 0 : 20)
        }
        .background(browserBackground)
        .task(id: title) {
            if !isEditingTitle {
                titleDraft = title
            }
        }
        .onChange(of: searchQuery) { _, newValue in
            searchResults = scopedSearchResults(for: newValue)
        }
        .onChange(of: repository.browserItems) { _, _ in
            guard isShowingSearchResults else { return }
            searchResults = scopedSearchResults(for: searchQuery)
        }
#if os(iOS)
        .overlay {
            if isCreateMenuExpanded {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isCreateMenuExpanded = false
                    }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            floatingCreateButton
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isCreateMenuExpanded)
#endif
    }

    private var sortHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let subtitle, !isRoot {
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }

#if os(macOS)
            HStack(alignment: .center, spacing: 12) {
                Picker("Sort", selection: Binding(
                    get: { sortMode },
                    set: { sortSelection.wrappedValue = $0 }
                )) {
                    ForEach(RootView.SortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField(searchPrompt, text: $searchQuery)
                        .textFieldStyle(.plain)

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear Search")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .frame(minWidth: 220, maxWidth: 360)
                .accessibilityLabel(searchPrompt)

                Spacer(minLength: 0)

                Button {
                    onCreateFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    onCreateNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)

                if let onOpenSettings {
                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.bordered)
                }
            }
#else
            HStack(spacing: 12) {
                Picker("Sort", selection: Binding(
                    get: { sortMode },
                    set: { sortSelection.wrappedValue = $0 }
                )) {
                    ForEach(RootView.SortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

#if os(iOS)
                if let onOpenSettings {
                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.bordered)
                }
#endif

#if os(macOS)
                Button {
                    onCreateFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    onCreateNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)

                if let onOpenSettings {
                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.bordered)
                }
#endif
            }
#endif
        }
    }

    private var displayMode: BrowserDisplayMode {
        AppPreferences.normalizedBrowserDisplayMode(browserDisplayModeRawValue)
    }

    private var resolvedCardSize: Double {
        AppPreferences.normalizedBrowserCardSize(browserCardSize)
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: CGFloat(resolvedCardSize),
                    maximum: CGFloat(resolvedCardSize + 84)
                ),
                spacing: 16
            )
        ]
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorites")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)

            itemCollection(favoriteItems)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func itemCollection(_ items: [BrowserItem]) -> some View {
        switch displayMode {
        case .cards:
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
                    itemButton(item)
                }
            }
        case .list:
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    itemButton(item)
                }
            }
        }
    }

    private func itemButton(_ item: BrowserItem) -> some View {
        Button {
            onSelect(item)
        } label: {
            switch displayMode {
            case .cards:
                BrowserTile(item: item, cardSize: resolvedCardSize)
            case .list:
                BrowserListRow(item: item)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onRequestEdit(item)
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button {
                onToggleFavorite(item)
            } label: {
                Label(item.isFavorite ? "Remove Favorite" : "Favorite", systemImage: item.isFavorite ? "star.slash" : "star")
            }

            Button(role: .destructive) {
                onRequestDelete(item)
            } label: {
                Label(item.kind == .folder ? "Delete Folder" : "Delete Note", systemImage: "trash")
            }
        }
    }

    private var isShowingSearchResults: Bool {
#if os(macOS)
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
#else
        false
#endif
    }

    private var searchResultsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if searchResults.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(searchResults) { result in
                        Button {
                            onSelectSearchResult?(result)
                        } label: {
                            NoteSearchResultRow(result: result)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(searchResultBackgroundColor)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchResultBackgroundColor: Color {
#if os(macOS)
        Color(nsColor: .controlBackgroundColor)
#else
        Color(uiColor: .secondarySystemGroupedBackground)
#endif
    }

    private var searchPrompt: String {
        isRoot ? "Search notes" : "Search \(title)"
    }

    private func scopedSearchResults(for query: String) -> [NoteSearchResult] {
        let allResults = repository.search(query: query)
        guard let currentFolderRelativePath, !currentFolderRelativePath.isEmpty else {
            return allResults
        }

        let descendantPrefix = currentFolderRelativePath + "/"
        return allResults.filter { result in
            result.relativePath.hasPrefix(descendantPrefix)
        }
    }

    private var folderHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            if isEditingTitle {
                TextField("Folder Name", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .focused($isTitleFieldFocused)
                    .onSubmit {
                        submitRename()
                    }
            } else {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                if isEditingTitle {
                    submitRename()
                } else {
                    titleDraft = title
                    isEditingTitle = true
                    Task { @MainActor in
                        isTitleFieldFocused = true
                    }
                }
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
#if os(iOS)
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .background(.thinMaterial, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
            )
#else
            .buttonStyle(.borderless)
#endif
            .disabled(isRenaming)
            .accessibilityLabel("Edit Folder Title")
        }
    }

    private func submitRename() {
        guard let onRenameTitle else { return }
        let trimmedName = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            titleDraft = title
            isEditingTitle = false
            return
        }

        isRenaming = true
        Task {
            do {
                try await onRenameTitle(trimmedName)
                await MainActor.run {
                    isEditingTitle = false
                    isRenaming = false
                }
            } catch {
                await MainActor.run {
                    titleDraft = title
                    isEditingTitle = false
                    isRenaming = false
                }
            }
        }
    }

    private var browserBackground: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(uiColor: .systemGroupedBackground)
#endif
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Nothing Here Yet")
                .font(.headline)
            Text("Create a folder or a note to start filling this space.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var homeHero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(heroFillGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.white.opacity(colorScheme == .dark ? 0.04 : 0.18))
                )
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.22 : 0.55),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 8,
                                endRadius: 140
                            )
                        )
                        .frame(width: 180, height: 180)
                        .offset(x: 45, y: -55)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(.white.opacity(colorScheme == .dark ? 0.08 : 0.28), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 10) {
                Text("Notesync")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Fast notes synced through iCloud.")
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

//                if let subtitle {
//                    Text(subtitle)
//                        .font(.footnote.weight(.semibold))
//                        .foregroundStyle(.primary.opacity(0.78))
//                        .padding(.horizontal, 12)
//                        .padding(.vertical, 8)
//                        .background(.ultraThinMaterial, in: Capsule())
//                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 120)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.10), radius: 24, y: 12)
    }

    private var heroFillGradient: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.12, green: 0.24, blue: 0.30),
                    Color(red: 0.11, green: 0.18, blue: 0.24),
                    Color(red: 0.16, green: 0.11, blue: 0.18)
                ]
                : [
                    Color(red: 0.78, green: 0.94, blue: 0.92),
                    Color(red: 0.90, green: 0.92, blue: 0.99),
                    Color(red: 0.99, green: 0.89, blue: 0.84)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

#if os(iOS)
    private var floatingCreateButton: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if let onOpenSearch, isRoot {
                Button {
                    onOpenSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 54, height: 54)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                .accessibilityLabel("Search")
            }

            VStack(alignment: .trailing, spacing: 12) {
                if isCreateMenuExpanded {
                    floatingActionButton(title: "New Folder", systemImage: "folder.badge.plus") {
                        isCreateMenuExpanded = false
                        onCreateFolder()
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                    floatingActionButton(title: "New Note", systemImage: "square.and.pencil") {
                        isCreateMenuExpanded = false
                        onCreateNote()
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Button {
                    isCreateMenuExpanded.toggle()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 58, height: 58)
                        .rotationEffect(.degrees(isCreateMenuExpanded ? 45 : 0))
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
                .accessibilityLabel(isCreateMenuExpanded ? "Close Create Menu" : "Create")
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    private func floatingActionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.headline)

                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
    }
#endif
}

private struct NoteSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repository: NoteRepository

    let onSelect: (NoteSearchResult) -> Void

    @State private var query = ""
    @State private var results: [NoteSearchResult] = []

    var body: some View {
        List(results) { result in
            Button {
                dismiss()
                onSelect(result)
            } label: {
                NoteSearchResultRow(result: result)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Search Notes", systemImage: "magnifyingglass", description: Text("Search folders, note titles, and note contents."))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Search")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search notes")
#else
        .searchable(text: $query, prompt: "Search notes")
#endif
        .onChange(of: query) { _, newValue in
            results = repository.search(query: newValue)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

private struct NoteSearchResultRow: View {
    let result: NoteSearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(result.emoji)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if result.kind == .entry, let entryTimestamp = result.entryTimestamp {
                    Text(MarkdownNoteCodec.displayDateFormatter.string(from: entryTimestamp))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(result.accentStyle.color)
                } else {
                    Text(result.kind == .folder ? "Folder" : "Note")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(result.accentStyle.color)
                }

                if let snippet = result.snippet {
                    Text(snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }
}

private struct BrowserTile: View {
    let item: BrowserItem
    let cardSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(item.emoji)
                    .font(.system(size: emojiSize))
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.yellow)
                    }

                    Image(systemName: item.kind == .folder ? "folder.fill" : "note.text")
                        .foregroundStyle(item.accentStyle.color)
                }
            }

            Spacer()

            Text(item.name)
                .font(.headline)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)

            Text(tileSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(tilePadding)
        .frame(maxWidth: .infinity)
        .frame(minHeight: CGFloat(cardSize))
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(item.accentStyle.color.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(item.accentStyle.color.opacity(0.18), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var tileSubtitle: String {
        switch item.kind {
        case .folder:
            return "Folder"
        case .note:
            return RelativeDateTimeFormatter().localizedString(for: item.modifiedAt, relativeTo: Date())
        }
    }

    private var emojiSize: CGFloat {
        CGFloat(min(max(cardSize * 0.19, 22), 34))
    }

    private var tilePadding: CGFloat {
        CGFloat(min(max(cardSize * 0.10, 12), 18))
    }
}

private struct BrowserListRow: View {
    let item: BrowserItem

    var body: some View {
        HStack(spacing: 14) {
            Text(item.emoji)
                .font(.system(size: 26))
                .frame(width: 42, height: 42)
                .background(item.accentStyle.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)

                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.yellow)
                    }
                }

                Text(rowSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: item.kind == .folder ? "folder.fill" : "note.text")
                .foregroundStyle(item.accentStyle.color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(item.accentStyle.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(item.accentStyle.color.opacity(0.16), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var rowSubtitle: String {
        switch item.kind {
        case .folder:
            return "Folder"
        case .note:
            return RelativeDateTimeFormatter().localizedString(for: item.modifiedAt, relativeTo: Date())
        }
    }
}

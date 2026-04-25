import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import CoreServices
#endif

#if os(macOS)
private final class NoteFileEventStreamBox: @unchecked Sendable {
    private var stream: FSEventStreamRef?

    init(_ stream: FSEventStreamRef) {
        self.stream = stream
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

@MainActor
private final class NoteFileChangeMonitor {
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.linquist.notesync.noteFileEvents")
    private var streamBox: NoteFileEventStreamBox?
    private var scheduledChangeTask: Task<Void, Never>?

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        startWatching(url)
    }

    deinit {
        scheduledChangeTask?.cancel()
        streamBox?.stop()
    }

    func stop() {
        scheduledChangeTask?.cancel()
        scheduledChangeTask = nil
        streamBox?.stop()
        streamBox = nil
    }

    private func startWatching(_ url: URL) {
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, callbackInfo, eventCount, eventPaths, eventFlags, _ in
            guard let callbackInfo else { return }
            let monitor = Unmanaged<NoteFileChangeMonitor>.fromOpaque(callbackInfo).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: eventCount))

            Task { @MainActor in
                monitor.handleFileEvents(paths: paths, flags: flags)
            }
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) {
            streamBox = NoteFileEventStreamBox(stream)
        } else {
            NoteFileEventStreamBox(stream).stop()
        }
    }

    private func handleFileEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard !paths.isEmpty else { return }
        let ignoredFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        guard flags.contains(where: { $0 & ignoredFlags == 0 }) else { return }

        scheduledChangeTask?.cancel()
        scheduledChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.onChange()
            }
        }
    }
}
#endif

struct NoteEditorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var repository: NoteRepository
    @AppStorage(AppPreferences.noteFontSizeKey) private var noteFontSize = AppPreferences.defaultNoteFontSize
    @AppStorage(AppPreferences.noteFontKey) private var noteFontRawValue = AppPreferences.defaultNoteFont.rawValue

    let notePath: String
    let initialFocusEntryID: NoteEntry.ID?
    let onPathChange: (String) -> Void

    @State private var draft: NoteDocument?
    @State private var loadError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var focusTask: Task<Void, Never>?
    @State private var pendingDeletedEntryIDs: Set<UUID> = []
    @State private var hasPendingSave = false
#if os(macOS)
    @State private var noteFileChangeMonitor: NoteFileChangeMonitor?
#endif
    @State private var lastSavedDraft: NoteDocument?
    @State private var lastDiskModifiedAt: Date = .distantPast
    @State private var focusedEntryID: NoteEntry.ID?
    @State private var entryPendingDeletion: NoteEntry.ID?
    @State private var showingCopiedFeedback = false
    @State private var copiedEntryID: NoteEntry.ID?
    @State private var hasAppliedInitialFocus = false
    @State private var isEditingTitle = false
#if os(iOS)
    @FocusState private var isTitleFieldFocused: Bool
#elseif os(macOS)
    @FocusState private var isTitleFieldFocused: Bool
#endif
#if !os(iOS)
    @FocusState private var focusedMacEntryID: NoteEntry.ID?
#endif
    @Environment(\.colorScheme) private var colorScheme

    private var noteFont: NoteFontOption {
        AppPreferences.normalizedNoteFont(noteFontRawValue)
    }

    private var resolvedNoteFontSize: Double {
        AppPreferences.normalizedNoteFontSize(noteFontSize)
    }

    var body: some View {
        Group {
            if let draft {
                editor(for: draft)
            } else if let loadError {
                ContentUnavailableView("Could Not Open Note", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .task(id: notePath) {
            hasAppliedInitialFocus = false
            await loadNote()
            startFileChangeMonitor()
        }
        .onDisappear {
            focusTask?.cancel()
#if os(macOS)
            noteFileChangeMonitor?.stop()
            noteFileChangeMonitor = nil
#endif
            savePendingChanges()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task {
                    await refreshFromDiskIfNeeded(force: true)
                }
            case .inactive:
                savePendingChanges()
            case .background:
                savePendingChanges()
            default:
                break
            }
        }
        .confirmationDialog(
            "Delete Entry?",
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { if !$0 { entryPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Entry", role: .destructive) {
                confirmPendingEntryDeletion()
            }
            Button("Cancel", role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: {
            Text("This will remove the selected entry from the note.")
        }
    }

    private func editor(for note: NoteDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleSection
                    if shouldShowStorageWarning {
                        storageWarning
                    }

                    ForEach(Array(note.entries.enumerated()), id: \.element.id) { index, entry in
                        VStack(spacing: 12) {
                            entryCard(for: entry, index: index)

                            if index == (draft?.entries.count ?? 0) - 1 {
                                addEntryButton
                            }
                        }
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background {
                editorBackground
                    .ignoresSafeArea()
            }
            .onAppear {
                guard !hasAppliedInitialFocus else { return }
                hasAppliedInitialFocus = true
                focusAndRevealNewestEntry(using: proxy, targetEntryID: focusedEntryID ?? note.entries.last?.id)
            }
            .onChange(of: draft?.entries.last?.id) { _, newValue in
                guard let newValue else { return }
                focusAndRevealNewestEntry(using: proxy, targetEntryID: newValue)
            }
        }
    }

    private func copyNoteToClipboard() {
        guard let draft else { return }
        let text = clipboardText(for: draft)
        copyToClipboard(text)

        showingCopiedFeedback = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            showingCopiedFeedback = false
        }
    }

    private func copyEntryToClipboard(_ entry: NoteEntry) {
        copyToClipboard(entry.text.trimmingCharacters(in: .newlines))

        copiedEntryID = entry.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedEntryID == entry.id {
                copiedEntryID = nil
            }
        }
    }

    private func copyToClipboard(_ text: String) {
#if os(iOS)
        UIPasteboard.general.string = text
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#endif
    }

    private func clipboardText(for note: NoteDocument) -> String {
        let visibleEntries = note.entries.filter { entry in
            !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var sections: [String] = [
            note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Note" : note.title
        ]

        for entry in visibleEntries {
            sections.append(MarkdownNoteCodec.displayDateFormatter.string(from: entry.timestamp))
            sections.append(entry.text.trimmingCharacters(in: .newlines))
        }

        return sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func markdownText(for note: NoteDocument) -> String {
        var exportNote = note
        exportNote.entries = note.entries.filter { entry in
            !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return MarkdownNoteCodec.encode(exportNote)
    }

    private func loadNote() async {
        do {
            let note = try await repository.prepareNoteForEditing(relativePath: notePath)
            draft = note
            lastSavedDraft = note
            lastDiskModifiedAt = try repository.noteModificationDate(relativePath: note.relativePath)
            let preferredFocusEntryID = initialFocusEntryID.flatMap { targetEntryID in
                note.entries.contains(where: { $0.id == targetEntryID }) ? targetEntryID : nil
            }
            focusedEntryID = preferredFocusEntryID ?? note.entries.last?.id
#if !os(iOS)
            focusedMacEntryID = preferredFocusEntryID ?? note.entries.last?.id
#endif
            loadError = nil
        } catch {
            draft = nil
            loadError = error.localizedDescription
        }
    }

    private func deleteEntry(at index: Int) {
        guard let entry = draft?.entries[safe: index],
              draft?.entries.indices.contains(index) == true else { return }
        pendingDeletedEntryIDs.insert(entry.id)
        draft?.entries.remove(at: index)
        markPendingSave()
    }

    private func confirmPendingEntryDeletion() {
        guard let entryID = entryPendingDeletion,
              let index = draft?.entries.firstIndex(where: { $0.id == entryID }) else {
            entryPendingDeletion = nil
            return
        }
        entryPendingDeletion = nil
        deleteEntry(at: index)
        savePendingChanges()
    }

    private func addNextEntry() {
        guard var draft else { return }

        if let lastEntry = draft.entries.last,
           lastEntry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedEntryID = lastEntry.id
#if !os(iOS)
            focusedMacEntryID = lastEntry.id
#endif
            return
        }

        let newEntry = NoteEntry(timestamp: Date(), text: "")
        draft.entries.append(newEntry)
        self.draft = draft
        focusedEntryID = newEntry.id
#if !os(iOS)
        focusedMacEntryID = newEntry.id
#endif
        markPendingSave()
    }

    private func markPendingSave() {
        hasPendingSave = true
    }

    private func savePendingChanges() {
        guard hasPendingSave || !pendingDeletedEntryIDs.isEmpty else { return }
        saveTask?.cancel()
        guard let snapshot = draft else { return }
        let deletedEntryIDs = pendingDeletedEntryIDs

        saveTask = Task {
            guard !Task.isCancelled else { return }

            do {
                let saved = try await repository.save(
                    note: snapshot,
                    originalRelativePath: notePath,
                    deletedEntryIDs: deletedEntryIDs
                )
                await repository.waitForPendingCloudSync()
                await MainActor.run {
                    if saved != snapshot {
                        draft = saved
                    }
                    lastSavedDraft = saved
                    lastDiskModifiedAt = (try? repository.noteModificationDate(relativePath: saved.relativePath)) ?? lastDiskModifiedAt
                    pendingDeletedEntryIDs.subtract(deletedEntryIDs)
                    if draft == saved {
                        hasPendingSave = false
                    } else {
                        hasPendingSave = true
                    }
                    if saved.relativePath != notePath {
                        onPathChange(saved.relativePath)
                    }
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                }
            }
        }
    }

    private func startFileChangeMonitor() {
#if os(macOS)
        noteFileChangeMonitor?.stop()
        guard let watchURL = try? repository.noteStorageURLForWatching(relativePath: notePath) else { return }
        noteFileChangeMonitor = NoteFileChangeMonitor(url: watchURL) {
            Task {
                await refreshFromDiskIfNeeded()
            }
        }
#endif
    }

    private func refreshFromDiskIfNeeded(force: Bool = false) async {
#if os(iOS)
        if !force {
            return
        }
#endif
        guard let draft else { return }
        guard let diskModifiedAt = try? repository.noteModificationDate(relativePath: notePath) else { return }

        if !force, diskModifiedAt <= lastDiskModifiedAt.addingTimeInterval(0.5) {
            return
        }

        let hasUnsavedLocalChanges = lastSavedDraft != nil && draft != lastSavedDraft
        if hasUnsavedLocalChanges {
            return
        }

        do {
            let refreshed = try await repository.prepareNoteForEditing(relativePath: notePath)
            self.draft = refreshed
            lastSavedDraft = refreshed
            lastDiskModifiedAt = try repository.noteModificationDate(relativePath: refreshed.relativePath)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func focusAndRevealNewestEntry(using proxy: ScrollViewProxy, targetEntryID: NoteEntry.ID? = nil) {
        guard let entryID = targetEntryID ?? draft?.entries.last?.id else { return }

        focusTask?.cancel()
        focusTask = Task { @MainActor in
            focusedEntryID = entryID
#if !os(iOS)
            focusedMacEntryID = entryID
#endif

            withAnimation {
                proxy.scrollTo(entryID, anchor: .top)
            }

            // Run a second pass after the keyboard starts animating so the active editor stays visible.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, focusedEntryID == entryID else { return }

            withAnimation {
                proxy.scrollTo(entryID, anchor: .top)
            }
        }
    }

    private func entryTextBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { draft?.entries[safe: index]?.text ?? "" },
            set: { newValue in
                guard draft?.entries.indices.contains(index) == true else { return }
                draft?.entries[index].text = newValue
                markPendingSave()
            }
        )
    }

    private var titleSection: some View {
        HStack(alignment: .top, spacing: 12) {
            if isEditingTitle {
                TextField("Title", text: Binding(
                    get: { draft?.title ?? "" },
                    set: { newValue in
                        draft?.title = newValue
                        markPendingSave()
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .focused($isTitleFieldFocused)
                .onSubmit {
                    isEditingTitle = false
                }
            } else {
                Text(displayTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                copyButton
                shareButton

                Button {
                    isEditingTitle = true
                    Task { @MainActor in
                        isTitleFieldFocused = true
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
                .accessibilityLabel("Edit Title")
            }
        }
    }

    private var shouldShowStorageWarning: Bool {
        repository.storageDescription != "iCloud"
    }

    private var displayTitle: String {
        let title = draft?.title ?? ""
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Note" : title
    }

    private var storageWarning: some View {
        Label("Saving to \(repository.storageDescription), not iCloud", systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
#if os(iOS)
            .background(.thinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.8)
            )
#endif
    }

    private var copyButton: some View {
        Button {
            copyNoteToClipboard()
        } label: {
            Image(systemName: showingCopiedFeedback ? "checkmark" : "doc.on.doc")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
        }
#if os(iOS)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(.thinMaterial, in: Circle())
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
        )
#else
        .buttonStyle(.borderless)
#endif
        .accessibilityLabel(showingCopiedFeedback ? "Copied" : "Copy Note")
    }

    private var shareButton: some View {
        ShareLink(
            item: draft.map(markdownText(for:)) ?? "",
            subject: Text(displayTitle),
            message: Text(displayTitle)
        ) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
        }
#if os(iOS)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(.thinMaterial, in: Circle())
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
        )
#else
        .buttonStyle(.borderless)
#endif
        .accessibilityLabel("Share Note")
    }

    private func entryCard(for entry: NoteEntry, index: Int) -> some View {
        let isNewestEntry = index == (draft?.entries.count ?? 0) - 1
        let isHighlightedEntry = highlightedEntryID == entry.id

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text(MarkdownNoteCodec.displayDateFormatter.string(from: entry.timestamp))
                    .font(isNewestEntry ? .headline.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
#if os(iOS)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                    )
#endif

                Spacer()

                Button {
                    copyEntryToClipboard(entry)
                } label: {
                    Image(systemName: copiedEntryID == entry.id ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
#if os(iOS)
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.86))
                .background(.thinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                )
#else
                .buttonStyle(.borderless)
#endif
                .accessibilityLabel(copiedEntryID == entry.id ? "Copied Entry" : "Copy Entry")

                Button(role: .destructive) {
                    entryPendingDeletion = entry.id
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
#if os(iOS)
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.86))
                .background(.thinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                )
#else
                .buttonStyle(.borderless)
#endif
                .accessibilityLabel("Delete Entry")
            }

            entryEditor(for: entry, index: index)
                .scrollContentBackground(.hidden)
                .padding(isNewestEntry ? 16 : 14)
                .background(entryEditorSurface(isHighlightedEntry: isHighlightedEntry))
        }
        .padding(isNewestEntry ? 16 : 14)
        .background(entryCardBackground(isHighlightedEntry: isHighlightedEntry))
    }

    private var addEntryButton: some View {
        Button {
            addNextEntry()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
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
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Add New Entry")
    }

    @ViewBuilder
    private func entryCardBackground(isHighlightedEntry: Bool) -> some View {
#if os(iOS)
        glassCardBackground(
            cornerRadius: 26,
            tint: isHighlightedEntry
                ? (colorScheme == .dark ? Color.accentColor.opacity(0.16) : Color.accentColor.opacity(0.20))
                : (colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.06))
        )
        .shadow(color: .black.opacity(isHighlightedEntry ? 0.14 : 0.09), radius: isHighlightedEntry ? 26 : 18, y: isHighlightedEntry ? 12 : 8)
#else
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isHighlightedEntry ? Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.18) : Color.secondary.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isHighlightedEntry ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.06), lineWidth: 1)
            )
#endif
    }

    @ViewBuilder
    private func entryEditorSurface(isHighlightedEntry: Bool) -> some View {
#if os(iOS)
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                colorScheme == .dark
                    ? Color.white.opacity(isHighlightedEntry ? 0.16 : 0.10)
                    : Color.white.opacity(isHighlightedEntry ? 0.62 : 0.52)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(isHighlightedEntry ? 0.20 : 0.12)
                            : Color.black.opacity(isHighlightedEntry ? 0.08 : 0.06),
                        lineWidth: 0.8
                    )
            )
#else
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isHighlightedEntry ? Color.white.opacity(colorScheme == .dark ? 0.10 : 0.60) : Color.secondary.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isHighlightedEntry ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04), lineWidth: 0.8)
            )
#endif
    }

    private var highlightedEntryID: NoteEntry.ID? {
#if os(iOS)
        focusedEntryID ?? draft?.entries.last?.id
#else
        focusedMacEntryID ?? focusedEntryID ?? draft?.entries.last?.id
#endif
    }

    @ViewBuilder
    private func glassCardBackground(cornerRadius: CGFloat, tint: Color = .clear) -> some View {
#if os(iOS)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(colorScheme == .dark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.white.opacity(0.72)))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.08),
                        lineWidth: 0.9
                    )
            )
#else
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.06))
#endif
    }

    @ViewBuilder
    private var editorBackground: some View {
#if os(iOS)
        LinearGradient(
            colors: [
                Color(red: 0.11, green: 0.14, blue: 0.18).opacity(0.10),
                Color(red: 0.25, green: 0.40, blue: 0.48).opacity(0.06),
                Color(red: 0.92, green: 0.96, blue: 0.99).opacity(0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
#else
        Color.clear
#endif
    }

    @ViewBuilder
    private func entryEditor(for entry: NoteEntry, index: Int) -> some View {
        #if os(iOS)
        let isNewestEntry = index == (draft?.entries.count ?? 0) - 1
        IOSNoteTextView(
            text: entryTextBinding(at: index),
            font: noteFont.uiFont(size: resolvedNoteFontSize),
            isFocused: Binding(
                get: { focusedEntryID == entry.id },
                set: { isFocused in
                    if isFocused {
                        focusedEntryID = entry.id
                    } else if focusedEntryID == entry.id {
                        focusedEntryID = nil
                    }
                }
            )
        )
        .frame(height: estimatedEntryHeight(for: entry.text, isNewestEntry: isNewestEntry))
        #else
        let isNewestEntry = index == (draft?.entries.count ?? 0) - 1
        TextEditor(text: entryTextBinding(at: index))
            .focused($focusedMacEntryID, equals: entry.id)
            .font(noteFont.swiftUIFont(size: resolvedNoteFontSize))
            .frame(height: estimatedEntryHeight(for: entry.text, isNewestEntry: isNewestEntry, minimumHeight: 56, extraPadding: 10))
        #endif
    }

    private func estimatedEntryHeight(
        for text: String,
        isNewestEntry: Bool,
        minimumHeight: CGFloat = 64,
        extraPadding: CGFloat = 28
    ) -> CGFloat {
        if isNewestEntry {
            return 180
        }

        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return minimumHeight }

        let lineCount = max(trimmed.components(separatedBy: .newlines).count, 1)
        let lineHeight = platformLineHeight(for: resolvedNoteFontSize)
        return max(minimumHeight, ceil(CGFloat(lineCount) * lineHeight + extraPadding - lineHeight))
    }

    private func platformLineHeight(for fontSize: Double) -> CGFloat {
#if os(iOS)
        noteFont.uiFont(size: fontSize).lineHeight
#elseif os(macOS)
        let font = noteFont.nsFont(size: fontSize)
        return font.ascender - font.descender + font.leading
#else
        CGFloat(fontSize * 1.25)
#endif
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#if os(iOS)
private struct IOSNoteTextView: UIViewRepresentable {
    @Binding var text: String
    let font: UIFont
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = font
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = false
        view.autocorrectionType = .no
        view.spellCheckingType = .yes
        view.autocapitalizationType = .sentences
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.textContentType = .none
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.keyboardDismissMode = .interactive
        view.text = text
        view.textColor = .label
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }

        if uiView.font != font {
            uiView.font = font
        }

        if isFocused {
            if !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
                let end = uiView.endOfDocument
                uiView.selectedTextRange = uiView.textRange(from: end, to: end)
            }
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text ?? ""
        }
    }
}
#endif

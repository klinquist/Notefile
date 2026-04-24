import CloudKit
import CryptoKit
import Foundation
import OSLog

struct NoteSearchResult: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder
        case note
        case entry
    }

    let kind: Kind
    let relativePath: String
    let title: String
    let emoji: String
    let accentStyle: AccentStyle
    let snippet: String?
    let entryID: UUID?
    let entryTimestamp: Date?

    var id: String { "\(kind)-\(relativePath)-\(entryID?.uuidString ?? "root")" }
}

@MainActor
final class NoteRepository: ObservableObject {
    private static let leakedContainerIdentifier = "com.linquist.notefile"
    private static let notePackageExtension = "note"
    private static let folderMetadataFileName = ".notefile-folder.json"
    private static let noteManifestFileName = ".notefile-note.json"
    private static let entryFileExtension = "md"
    private static let cloudKitContainerIdentifier = "iCloud.com.linquist.notefile"
    private static let cloudRecordZoneID = CKRecordZone.ID(zoneName: "Notefile")
    private static let folderRecordType = "Folder"
    private static let noteRecordType = "Note"
    private static let entryRecordType = "NoteEntry"
    private static let entryTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter
    }()

    @Published private(set) var browserItems: [BrowserItem] = []
    @Published private(set) var storageDescription = "Checking iCloud"
    @Published var lastErrorMessage: String?

    private let fileManager = FileManager.default
    private let cloudContainer = CKContainer(identifier: NoteRepository.cloudKitContainerIdentifier)
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var cachedRootURL: URL?
    private var cloudRecordZoneIsReady = false
    private var cloudSyncTail: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.linquist.notefile", category: "NoteRepository")

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        Task {
            await loadBrowser()
        }
    }

    func loadBrowser() async {
        do {
            try await refreshCloudCache()
        } catch {
            lastErrorMessage = error.localizedDescription
            logger.error("loadBrowser cloud refresh failed error=\(error.localizedDescription, privacy: .public)")
        }

        do {
            try reloadLocalBrowser()
            let rootURL = try storageRootURL()
            lastErrorMessage = nil
            logger.info("loadBrowser completed root=\(rootURL.path, privacy: .public) items=\(self.browserItems.count)")
        } catch {
            browserItems = []
            lastErrorMessage = error.localizedDescription
            logger.error("loadBrowser failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func storageRootURL() throws -> URL {
        if let cachedRootURL {
            return cachedRootURL
        }

        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cacheRoot = appSupport.appendingPathComponent("NotefileCloudKitCache", isDirectory: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        cachedRootURL = cacheRoot
        logger.info("storageRootURL using CloudKit cache root=\(cacheRoot.path, privacy: .public)")
        return cacheRoot
    }

    func createFolder(name: String, emoji: String, accentStyle: AccentStyle, parentRelativePath: String?) async throws -> String {
        let sanitizedName = sanitizeName(name, fallback: "New Folder")
        let parentURL = try folderURL(for: parentRelativePath)
        let folderName = try uniqueDirectoryName(for: sanitizedName, in: parentURL)
        let folderURL = parentURL.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let metadata = FolderMetadata(emoji: emoji.ifBlank("📁"), accentStyle: accentStyle)
        try saveFolderMetadata(metadata, at: folderURL)
        let relativePath = self.relativePath(for: folderURL)
        let modifiedAt = Date()
        queueCloudSync("createFolder") { repository in
            try await repository.uploadFolder(relativePath: relativePath, metadata: metadata, modifiedAt: modifiedAt)
        }
        logger.info("createFolder parent=\(parentRelativePath ?? "<root>", privacy: .public) folder=\(relativePath, privacy: .public)")
        try reloadLocalBrowser()
        return relativePath
    }

    func renameFolder(relativePath: String, name: String) async throws -> String {
        let currentURL = try folderURL(for: relativePath)
        guard fileManager.fileExists(atPath: currentURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let parentRelativePath = parentPath(for: relativePath)
        let parentURL = try folderURL(for: parentRelativePath)
        let sanitizedName = sanitizeName(name, fallback: "New Folder")
        let targetName = try uniqueDirectoryName(for: sanitizedName, in: parentURL, excluding: currentURL.lastPathComponent)
        let targetURL = parentURL.appendingPathComponent(targetName, isDirectory: true)

        if currentURL != targetURL {
            try fileManager.moveItem(at: currentURL, to: targetURL)
        }

        let updatedRelativePath = self.relativePath(for: targetURL)
        queueCloudSync("renameFolder") { repository in
            try await repository.deleteCloudTree(relativePath: relativePath)
            try await repository.uploadFolderTree(at: targetURL)
        }
        logger.info("renameFolder from=\(relativePath, privacy: .public) to=\(updatedRelativePath, privacy: .public)")
        try reloadLocalBrowser()
        return updatedRelativePath
    }

    func createNote(title: String, emoji: String, accentStyle: AccentStyle, parentRelativePath: String?) async throws -> String {
        let cleanTitle = sanitizeName(title, fallback: "Untitled Note")
        let relativePath = try uniqueNoteRelativePath(
            for: cleanTitle,
            in: parentRelativePath,
            excluding: nil
        )
        let note = NoteDocument(
            relativePath: relativePath,
            title: cleanTitle,
            metadata: NoteMetadata(emoji: emoji.ifBlank("📝"), accentStyle: accentStyle),
            entries: []
        )
        try persistNotePackage(note: note, modifiedAt: nil)
        queueCloudSync("createNote") { repository in
            try await repository.uploadNote(note)
        }
        logger.info("createNote parent=\(parentRelativePath ?? "<root>", privacy: .public) note=\(relativePath, privacy: .public)")
        try reloadLocalBrowser()
        return relativePath
    }

    func delete(item: BrowserItem) async throws {
        switch item.kind {
        case .folder:
            let itemURL = try folderURL(for: item.relativePath)
            guard fileManager.fileExists(atPath: itemURL.path) else {
                try reloadLocalBrowser()
                return
            }
            try fileManager.removeItem(at: itemURL)
            let relativePath = item.relativePath
            queueCloudSync("deleteFolder") { repository in
                try await repository.deleteCloudTree(relativePath: relativePath)
            }
        case .note:
            try await deleteNote(relativePath: item.relativePath)
        }

        try reloadLocalBrowser()
    }

    func deleteNote(relativePath: String) async throws {
        logger.notice("deleteNote relativePath=\(relativePath, privacy: .public)")
        try removeNoteStorageIfExists(relativePath: relativePath)
        queueCloudSync("deleteNote") { repository in
            try await repository.deleteCloudNote(relativePath: relativePath)
        }
    }

    func exportCombinedMarkdown(relativePath: String) throws -> String {
        var note = try loadNote(relativePath: relativePath)
        note.entries = persistedEntries(from: note.entries)
        logger.debug("exportCombinedMarkdown relativePath=\(relativePath, privacy: .public) entries=\(note.entries.count)")
        return MarkdownNoteCodec.encode(note)
    }

    func importCombinedMarkdown(_ markdown: String, relativePath: String, sourceModifiedAt: Date? = nil) async throws {
        let fallbackMetadata = (try? loadNote(relativePath: relativePath).metadata) ?? .default
        var note = MarkdownNoteCodec.decode(
            relativePath: relativePath,
            markdown: markdown,
            fallbackMetadata: fallbackMetadata
        )
        note.title = sanitizeName(
            fileStem(for: relativePath),
            fallback: "Untitled Note"
        )
        if let existing = try? loadNote(relativePath: relativePath) {
            note.entries = reconcileImportedEntries(note.entries, existing: existing.entries)
        }
        logger.info("importCombinedMarkdown relativePath=\(relativePath, privacy: .public) importedEntries=\(note.entries.count)")
        _ = try await save(
            note: note,
            originalRelativePath: relativePath,
            reloadBrowser: false,
            mergeWithExisting: false,
            sourceModifiedAt: sourceModifiedAt
        )
    }

    func prepareNoteForEditing(relativePath: String) async throws -> NoteDocument {
        try await refreshCloudNote(relativePath: relativePath)
        var note = try loadNote(relativePath: relativePath)
        if note.entries.last?.text.isEmpty != true {
            let thresholdMinutes = AppPreferences.currentNewEntryThresholdMinutes()
            if thresholdMinutes > 0,
               !note.entries.isEmpty,
               let modifiedAt = try? noteModificationDate(relativePath: relativePath),
               Date().timeIntervalSince(modifiedAt) <= Double(thresholdMinutes * 60) {
                logger.debug("prepareNoteForEditing resumedLastEntry relativePath=\(relativePath, privacy: .public) thresholdMinutes=\(thresholdMinutes)")
                return note
            }

            note.entries.append(NoteEntry(timestamp: Date(), text: ""))
            note = try await save(note: note, originalRelativePath: relativePath, reloadBrowser: true)
            logger.debug("prepareNoteForEditing appendedDraft relativePath=\(relativePath, privacy: .public) entryCount=\(note.entries.count)")
        } else {
            logger.debug("prepareNoteForEditing reusedDraft relativePath=\(relativePath, privacy: .public) entryCount=\(note.entries.count)")
        }
        return note
    }

    func loadNote(relativePath: String) throws -> NoteDocument {
        let packageURL = try notePackageURL(for: relativePath)
        if fileManager.fileExists(atPath: packageURL.path) {
            let note = try loadNotePackage(at: packageURL, relativePath: relativePath)
            logger.debug("loadNote package relativePath=\(relativePath, privacy: .public) entries=\(note.entries.count)")
            return note
        }

        let legacyURL = try legacyNoteURL(for: relativePath)
        guard fileManager.fileExists(atPath: legacyURL.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        prepareUbiquitousItemForReading(at: legacyURL)
        let markdown = (try? String(contentsOf: legacyURL, encoding: .utf8)) ?? ""
        let metadata = loadLegacyNoteMetadata(for: legacyURL) ?? .default
        let note = MarkdownNoteCodec.decode(relativePath: relativePath, markdown: markdown, fallbackMetadata: metadata)
        logger.debug("loadNote legacy relativePath=\(relativePath, privacy: .public) entries=\(note.entries.count)")
        return note
    }

    func noteModificationDate(relativePath: String) throws -> Date {
        let packageURL = try notePackageURL(for: relativePath)
        if fileManager.fileExists(atPath: packageURL.path) {
            return try notePackageModificationDate(at: packageURL)
        }

        let legacyURL = try legacyNoteURL(for: relativePath)
        prepareUbiquitousItemForReading(at: legacyURL)
        return (try? legacyURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    func search(query: String) -> [NoteSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let foldedQuery = trimmedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var results: [NoteSearchResult] = []
        appendSearchResults(in: browserItems, foldedQuery: foldedQuery, results: &results)
        return results.sorted { lhs, rhs in
            let lhsRank = searchRank(for: lhs, foldedQuery: foldedQuery)
            let rhsRank = searchRank(for: rhs, foldedQuery: foldedQuery)

            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    @discardableResult
    func save(
        note: NoteDocument,
        originalRelativePath: String? = nil,
        reloadBrowser: Bool = false,
        deletedEntryIDs: Set<UUID> = []
    ) async throws -> NoteDocument {
        try await save(
            note: note,
            originalRelativePath: originalRelativePath ?? note.relativePath,
            reloadBrowser: reloadBrowser,
            mergeWithExisting: true,
            sourceModifiedAt: nil,
            deletedEntryIDs: deletedEntryIDs
        )
    }

    func parentFolderPath(for item: BrowserItem?) -> String? {
        guard let item else { return nil }
        switch item.kind {
        case .folder:
            return item.relativePath.isEmpty ? nil : item.relativePath
        case .note:
            return parentPath(for: item.relativePath)
        }
    }

    private func save(
        note: NoteDocument,
        originalRelativePath: String,
        reloadBrowser: Bool,
        mergeWithExisting: Bool,
        sourceModifiedAt: Date?,
        deletedEntryIDs: Set<UUID> = []
    ) async throws -> NoteDocument {
        let cleanTitle = sanitizeName(note.title, fallback: "Untitled Note")
        let normalizedParentPath = parentPath(for: originalRelativePath)
        let targetRelativePath = try uniqueNoteRelativePath(
            for: cleanTitle,
            in: normalizedParentPath,
            excluding: originalRelativePath
        )

        var savedNote = note
        savedNote.title = cleanTitle
        savedNote.relativePath = targetRelativePath

        if mergeWithExisting,
           let diskNote = try? loadNote(relativePath: targetRelativePath) {
            savedNote.entries = mergeEntries(local: savedNote.entries, disk: diskNote.entries, deletedEntryIDs: deletedEntryIDs)
        }

        savedNote.entries = normalizeEntries(savedNote.entries)
        try persistNotePackage(note: savedNote, modifiedAt: sourceModifiedAt)
        try cleanupLegacyArtifacts(for: savedNote.relativePath)
        let persistedEntryCount = persistedEntries(from: savedNote.entries).count
        logger.info("save note original=\(originalRelativePath, privacy: .public) saved=\(savedNote.relativePath, privacy: .public) entries=\(savedNote.entries.count) persistedEntries=\(persistedEntryCount)")

        if originalRelativePath != savedNote.relativePath {
            try removeNoteStorageIfExists(relativePath: originalRelativePath)
        } else if fileManager.fileExists(atPath: try legacyNoteURL(for: savedNote.relativePath).path) {
            try cleanupLegacyArtifacts(for: savedNote.relativePath)
        }

        queueCloudSync("saveNote") { repository in
            try await repository.uploadNote(savedNote, modifiedAt: sourceModifiedAt)
            if originalRelativePath != savedNote.relativePath {
                try await repository.deleteCloudNote(relativePath: originalRelativePath)
            }
        }

        if reloadBrowser {
            try reloadLocalBrowser()
        }

        return savedNote
    }

    private func reloadLocalBrowser() throws {
        let rootURL = try storageRootURL()
        browserItems = try loadFolderContents(at: rootURL, relativePath: nil)
        logger.info("reloadLocalBrowser completed root=\(rootURL.path, privacy: .public) items=\(self.browserItems.count)")
    }

    private func queueCloudSync(_ label: String, operation: @escaping (NoteRepository) async throws -> Void) {
        let previousTask = cloudSyncTail
        cloudSyncTail = Task { [weak self] in
            await previousTask?.value
            guard let self else { return }
            do {
                try await operation(self)
                self.storageDescription = "iCloud"
                self.logger.info("queueCloudSync completed label=\(label, privacy: .public)")
            } catch {
                self.lastErrorMessage = error.localizedDescription
                self.logger.error("queueCloudSync failed label=\(label, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func persistNotePackage(note: NoteDocument, modifiedAt: Date?) throws {
        let packageURL = try notePackageURL(for: note.relativePath)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let manifestURL = packageManifestURL(for: packageURL)
        let manifest = NotePackageManifest(metadata: note.metadata)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        let existingEntryURLs = try noteEntryURLs(at: packageURL)
        var expectedFileNames: Set<String> = []
        let persistedEntries = persistedEntries(from: note.entries)

        for entry in persistedEntries {
            let fileName = entryFileName(for: entry)
            expectedFileNames.insert(fileName)
            let entryURL = packageURL.appendingPathComponent(fileName)
            try entry.text.write(to: entryURL, atomically: true, encoding: .utf8)
            if let modifiedAt {
                try setModificationDate(modifiedAt, at: entryURL)
            }
        }

        for entryURL in existingEntryURLs where !expectedFileNames.contains(entryURL.lastPathComponent) {
            try fileManager.removeItem(at: entryURL)
        }

        if let modifiedAt {
            try setModificationDate(modifiedAt, at: manifestURL)
            try setModificationDate(modifiedAt, at: packageURL)
        }

        logger.debug("persistNotePackage path=\(note.relativePath, privacy: .public) package=\(packageURL.path, privacy: .public) persistedEntries=\(persistedEntries.count)")
    }

    private func folderURL(for relativePath: String?) throws -> URL {
        guard let relativePath, !relativePath.isEmpty else {
            return try storageRootURL()
        }
        return try storageRootURL().appendingPathComponent(relativePath, isDirectory: true)
    }

    private func notePackageURL(for relativePath: String) throws -> URL {
        let rootURL = try storageRootURL()
        let baseRelativePath = (relativePath as NSString).deletingPathExtension
        let packageRelativePath = (baseRelativePath as NSString).appendingPathExtension(Self.notePackageExtension)
            ?? "\(baseRelativePath).\(Self.notePackageExtension)"
        return rootURL.appendingPathComponent(packageRelativePath, isDirectory: true)
    }

    private func legacyNoteURL(for relativePath: String) throws -> URL {
        try storageRootURL().appendingPathComponent(relativePath)
    }

    private func packageManifestURL(for packageURL: URL) -> URL {
        packageURL.appendingPathComponent(Self.noteManifestFileName)
    }

    private func relativePath(for absoluteURL: URL) -> String {
        guard let rootURL = try? storageRootURL() else {
            return absoluteURL.lastPathComponent
        }

        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let absoluteComponents = absoluteURL.standardizedFileURL.pathComponents
        guard absoluteComponents.count > rootComponents.count,
              Array(absoluteComponents.prefix(rootComponents.count)) == rootComponents else {
            return absoluteURL.lastPathComponent
        }

        return absoluteComponents
            .dropFirst(rootComponents.count)
            .joined(separator: "/")
    }

    private func appendSearchResults(in items: [BrowserItem], foldedQuery: String, results: inout [NoteSearchResult]) {
        for item in items {
            switch item.kind {
            case .folder:
                if item.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(foldedQuery) {
                    results.append(
                        NoteSearchResult(
                            kind: .folder,
                            relativePath: item.relativePath,
                            title: item.name,
                            emoji: item.emoji,
                            accentStyle: item.accentStyle,
                            snippet: nil,
                            entryID: nil,
                            entryTimestamp: nil
                        )
                    )
                }
                appendSearchResults(in: item.children, foldedQuery: foldedQuery, results: &results)
            case .note:
                let titleMatch = item.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(foldedQuery)
                if titleMatch {
                    results.append(
                        NoteSearchResult(
                            kind: .note,
                            relativePath: item.relativePath,
                            title: item.name,
                            emoji: item.emoji,
                            accentStyle: item.accentStyle,
                            snippet: nil,
                            entryID: nil,
                            entryTimestamp: nil
                        )
                    )
                }

                appendEntrySearchResults(
                    noteRelativePath: item.relativePath,
                    noteTitle: item.name,
                    emoji: item.emoji,
                    accentStyle: item.accentStyle,
                    foldedQuery: foldedQuery,
                    results: &results
                )
            }
        }
    }

    private func appendEntrySearchResults(
        noteRelativePath: String,
        noteTitle: String,
        emoji: String,
        accentStyle: AccentStyle,
        foldedQuery: String,
        results: inout [NoteSearchResult]
    ) {
        guard let note = try? loadNote(relativePath: noteRelativePath) else { return }

        for entry in note.entries {
            guard let snippet = searchSnippet(for: entry, foldedQuery: foldedQuery) else { continue }
            results.append(
                NoteSearchResult(
                    kind: .entry,
                    relativePath: noteRelativePath,
                    title: noteTitle,
                    emoji: emoji,
                    accentStyle: accentStyle,
                    snippet: snippet,
                    entryID: entry.id,
                    entryTimestamp: entry.timestamp
                )
            )
        }
    }

    private func searchSnippet(for entry: NoteEntry, foldedQuery: String) -> String? {
        let collapsed = entry.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }

        let foldedText = collapsed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let range = foldedText.range(of: foldedQuery) {
            let lowerDistance = foldedText.distance(from: foldedText.startIndex, to: range.lowerBound)
            let startOffset = max(0, lowerDistance - 24)
            let endOffset = min(collapsed.count, lowerDistance + foldedQuery.count + 48)
            let startIndex = collapsed.index(collapsed.startIndex, offsetBy: startOffset)
            let endIndex = collapsed.index(collapsed.startIndex, offsetBy: endOffset)
            let prefix = startOffset > 0 ? "..." : ""
            let suffix = endOffset < collapsed.count ? "..." : ""
            return prefix + String(collapsed[startIndex..<endIndex]) + suffix
        }

        return nil
    }

    private func searchSnippet(for relativePath: String, foldedQuery: String) -> String? {
        guard let note = try? loadNote(relativePath: relativePath) else { return nil }

        for entry in note.entries {
            if let snippet = searchSnippet(for: entry, foldedQuery: foldedQuery) {
                return snippet
            }
        }

        return nil
    }

    private func searchRank(for result: NoteSearchResult, foldedQuery: String) -> Int {
        let foldedTitle = result.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        if foldedTitle == foldedQuery {
            return 0
        }

        if foldedTitle.hasPrefix(foldedQuery) {
            return 1
        }

        if foldedTitle.contains(foldedQuery) {
            return 2
        }

        return result.kind == .entry ? 3 : 4
    }

    private func logicalNoteRelativePath(for packageURL: URL, parentRelativePath: String?) -> String {
        let fileName = packageURL.deletingPathExtension().lastPathComponent + ".md"
        return joinedRelativePath(parentRelativePath, component: fileName)
    }

    private func loadFolderContents(at folderURL: URL, relativePath: String?) throws -> [BrowserItem] {
        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var folders: [BrowserItem] = []
        var notes: [BrowserItem] = []

        for url in urls {
            let component = url.lastPathComponent
            let itemRelativePath = joinedRelativePath(relativePath, component: component)
            guard !shouldHideLeakedContainerPath(itemRelativePath) else {
                continue
            }

            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values.isDirectory == true {
                if url.pathExtension.lowercased() == Self.notePackageExtension {
                    let noteRelativePath = logicalNoteRelativePath(for: url, parentRelativePath: relativePath)
                    let metadata = loadNoteMetadataFromPackage(at: url) ?? .default
                    notes.append(
                        BrowserItem(
                            kind: .note,
                            relativePath: noteRelativePath,
                            name: url.deletingPathExtension().lastPathComponent,
                            emoji: metadata.emoji,
                            accentStyle: metadata.accentStyle,
                            modifiedAt: (try? notePackageModificationDate(at: url)) ?? .distantPast,
                            children: []
                        )
                    )
                } else {
                    let metadata = loadFolderMetadata(at: url) ?? .default
                    folders.append(
                        BrowserItem(
                            kind: .folder,
                            relativePath: itemRelativePath,
                            name: component,
                            emoji: metadata.emoji,
                            accentStyle: metadata.accentStyle,
                            modifiedAt: values.contentModificationDate ?? .distantPast,
                            children: try loadFolderContents(at: url, relativePath: itemRelativePath)
                        )
                    )
                }
                continue
            }

            guard url.pathExtension.lowercased() == "md" else {
                continue
            }

            let noteRelativePath = joinedRelativePath(relativePath, component: component)
            let metadata = loadLegacyNoteMetadataFromMarkdown(for: url, relativePath: noteRelativePath)
            notes.append(
                BrowserItem(
                    kind: .note,
                    relativePath: noteRelativePath,
                    name: url.deletingPathExtension().lastPathComponent,
                    emoji: metadata.emoji,
                    accentStyle: metadata.accentStyle,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    children: []
                )
            )
        }

        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        notes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        logger.debug("loadFolderContents folder=\(relativePath ?? "<root>", privacy: .public) folders=\(folders.count) notes=\(notes.count)")
        return folders + notes
    }

    private func loadFolderMetadata(at folderURL: URL) -> FolderMetadata? {
        let metadataURL = folderURL.appendingPathComponent(Self.folderMetadataFileName)
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? decoder.decode(FolderMetadata.self, from: data)
    }

    private func saveFolderMetadata(_ metadata: FolderMetadata, at folderURL: URL) throws {
        let metadataURL = folderURL.appendingPathComponent(Self.folderMetadataFileName)
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func loadNoteMetadataFromPackage(at packageURL: URL) -> NoteMetadata? {
        let manifestURL = packageManifestURL(for: packageURL)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? decoder.decode(NotePackageManifest.self, from: data) else {
            return nil
        }
        return manifest.metadata
    }

    private func loadLegacyNoteMetadata(for noteURL: URL) -> NoteMetadata? {
        let metadataURL = legacyMetadataURL(for: noteURL)
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? decoder.decode(NoteMetadata.self, from: data)
    }

    private func loadLegacyNoteMetadataFromMarkdown(for noteURL: URL, relativePath: String) -> NoteMetadata {
        prepareUbiquitousItemForReading(at: noteURL)
        let markdown = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
        let fallbackMetadata = loadLegacyNoteMetadata(for: noteURL) ?? .default
        return MarkdownNoteCodec.decode(
            relativePath: relativePath,
            markdown: markdown,
            fallbackMetadata: fallbackMetadata
        ).metadata
    }

    private func loadNotePackage(at packageURL: URL, relativePath: String) throws -> NoteDocument {
        prepareUbiquitousItemForReading(at: packageURL)
        let title = fileStem(for: relativePath)
        let metadata = loadNoteMetadataFromPackage(at: packageURL) ?? .default
        let entryURLs = try noteEntryURLs(at: packageURL)

        let entries = entryURLs.compactMap { entryURL -> NoteEntry? in
            prepareUbiquitousItemForReading(at: entryURL)
            let text = (try? String(contentsOf: entryURL, encoding: .utf8)) ?? ""
            let parsed = parseEntryFileName(entryURL.lastPathComponent)
            let timestamp = parsed?.timestamp
                ?? (try? entryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return NoteEntry(id: parsed?.id ?? UUID(), timestamp: timestamp, text: text)
        }
        .sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let note = NoteDocument(
            relativePath: relativePath,
            title: title.isEmpty ? "Untitled Note" : title,
            metadata: metadata,
            entries: entries
        )
        logger.debug("loadNotePackage path=\(relativePath, privacy: .public) package=\(packageURL.path, privacy: .public) entryFiles=\(entryURLs.count)")
        return note
    }

    private func noteEntryURLs(at packageURL: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        )
        .filter { url in
            !url.lastPathComponent.hasPrefix(".")
                && url.pathExtension.lowercased() == Self.entryFileExtension
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func notePackageModificationDate(at packageURL: URL) throws -> Date {
        var latestDate = (try? packageURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        for entryURL in try noteEntryURLs(at: packageURL) {
            let modifiedAt = (try? entryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            latestDate = max(latestDate, modifiedAt)
        }

        let manifestURL = packageManifestURL(for: packageURL)
        if fileManager.fileExists(atPath: manifestURL.path) {
            let manifestDate = (try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            latestDate = max(latestDate, manifestDate)
        }

        return latestDate
    }

    private func prepareUbiquitousItemForReading(at url: URL) {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else {
            return
        }

        if values.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
        }
    }

    private func legacyMetadataURL(for noteURL: URL) -> URL {
        noteURL.deletingPathExtension().appendingPathExtension("notefile.json")
    }

    private func uniqueDirectoryName(for baseName: String, in folderURL: URL, excluding excludedName: String? = nil) throws -> String {
        var candidate = baseName
        var counter = 2
        while candidate != excludedName &&
            fileManager.fileExists(atPath: folderURL.appendingPathComponent(candidate, isDirectory: true).path) {
            candidate = "\(baseName) \(counter)"
            counter += 1
        }
        return candidate
    }

    private func uniqueNoteRelativePath(for title: String, in parentRelativePath: String?, excluding excludedRelativePath: String?) throws -> String {
        var counter = 1
        while true {
            let candidateTitle = counter == 1 ? title : "\(title) \(counter)"
            let candidateRelativePath = joinedRelativePath(parentRelativePath, component: "\(candidateTitle).md")
            let storageExists = try noteStorageExists(relativePath: candidateRelativePath)
            if candidateRelativePath == excludedRelativePath || !storageExists {
                return candidateRelativePath
            }
            counter += 1
        }
    }

    private func noteStorageExists(relativePath: String) throws -> Bool {
        let packageURL = try notePackageURL(for: relativePath)
        if fileManager.fileExists(atPath: packageURL.path) {
            return true
        }

        let legacyURL = try legacyNoteURL(for: relativePath)
        return fileManager.fileExists(atPath: legacyURL.path)
    }

    private func removeNoteStorageIfExists(relativePath: String) throws {
        let packageURL = try notePackageURL(for: relativePath)
        if fileManager.fileExists(atPath: packageURL.path) {
            logger.notice("removeNoteStorageIfExists removingPackage path=\(relativePath, privacy: .public) package=\(packageURL.path, privacy: .public)")
            try fileManager.removeItem(at: packageURL)
        }

        let legacyURL = try legacyNoteURL(for: relativePath)
        if fileManager.fileExists(atPath: legacyURL.path) {
            logger.notice("removeNoteStorageIfExists removingLegacy path=\(relativePath, privacy: .public) file=\(legacyURL.path, privacy: .public)")
            try fileManager.removeItem(at: legacyURL)
        }

        let metadataURL = legacyMetadataURL(for: legacyURL)
        if fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.removeItem(at: metadataURL)
        }
    }

    private func cleanupLegacyArtifacts(for relativePath: String) throws {
        let legacyURL = try legacyNoteURL(for: relativePath)
        if fileManager.fileExists(atPath: legacyURL.path) {
            try fileManager.removeItem(at: legacyURL)
        }

        let metadataURL = legacyMetadataURL(for: legacyURL)
        if fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.removeItem(at: metadataURL)
        }
    }

    private func entryFileName(for entry: NoteEntry) -> String {
        let timestamp = Self.entryTimestampFormatter.string(from: entry.timestamp)
        return "\(timestamp)--\(entry.id.uuidString).\(Self.entryFileExtension)"
    }

    private func parseEntryFileName(_ fileName: String) -> (timestamp: Date, id: UUID)? {
        let baseName = (fileName as NSString).deletingPathExtension
        let components = baseName.components(separatedBy: "--")
        guard components.count == 2,
              let timestamp = Self.entryTimestampFormatter.date(from: components[0]),
              let id = UUID(uuidString: components[1]) else {
            return nil
        }
        return (timestamp, id)
    }

    private func sanitizeName(_ value: String, fallback: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func joinedRelativePath(_ parent: String?, component: String) -> String {
        guard let parent, !parent.isEmpty else { return component }
        return (parent as NSString).appendingPathComponent(component)
    }

    private func parentPath(for relativePath: String) -> String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "." else { return nil }
        return parent
    }

    private func fileStem(for relativePath: String) -> String {
        let fileName = (relativePath as NSString).lastPathComponent
        return (fileName as NSString).deletingPathExtension
    }

    private func shouldHideLeakedContainerPath(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count >= 5 else { return false }

        return components[0] == "Users"
            && components[2] == "Library"
            && components[3] == "Containers"
            && components[4] == Self.leakedContainerIdentifier
    }

    private func mergeEntries(local: [NoteEntry], disk: [NoteEntry], deletedEntryIDs: Set<UUID>) -> [NoteEntry] {
        let localHasDraftEntry = local.last?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
        var mergedByID: [UUID: NoteEntry] = [:]
        disk.forEach { entry in
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !deletedEntryIDs.contains(entry.id) {
                mergedByID[entry.id] = entry
            }
        }

        for entry in local {
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                mergedByID.removeValue(forKey: entry.id)
            } else {
                mergedByID[entry.id] = entry
            }
        }

        for deletedEntryID in deletedEntryIDs {
            mergedByID.removeValue(forKey: deletedEntryID)
        }

        var mergedEntries = Array(mergedByID.values).sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        if localHasDraftEntry {
            let draft = local.last(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                ?? NoteEntry(timestamp: Date(), text: "")
            mergedEntries.append(NoteEntry(id: draft.id, timestamp: draft.timestamp, text: ""))
        }

        return mergedEntries
    }

    private func reconcileImportedEntries(_ imported: [NoteEntry], existing: [NoteEntry]) -> [NoteEntry] {
        var buckets: [String: [NoteEntry]] = [:]
        for entry in existing {
            buckets[importMatchKey(for: entry), default: []].append(entry)
        }

        return imported.map { entry in
            let key = importMatchKey(for: entry)
            guard var matches = buckets[key], !matches.isEmpty else {
                return entry
            }

            let matched = matches.removeFirst()
            buckets[key] = matches
            return NoteEntry(id: matched.id, timestamp: matched.timestamp, text: entry.text)
        }
    }

    private func importMatchKey(for entry: NoteEntry) -> String {
        "\(MarkdownNoteCodec.storageTimestampString(for: entry.timestamp))\u{001F}\(entry.text)"
    }

    private func normalizeEntries(_ entries: [NoteEntry]) -> [NoteEntry] {
        var seenTimestamps: [Date: Int] = [:]

        return entries.map { entry in
            let duplicateOffset = seenTimestamps[entry.timestamp, default: 0]
            seenTimestamps[entry.timestamp] = duplicateOffset + 1

            let adjustedTimestamp = duplicateOffset == 0
                ? entry.timestamp
                : entry.timestamp.addingTimeInterval(Double(duplicateOffset) / 1_000)
            return NoteEntry(id: entry.id, timestamp: adjustedTimestamp, text: entry.text)
        }
    }

    private func persistedEntries(from entries: [NoteEntry]) -> [NoteEntry] {
        entries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var privateDatabase: CKDatabase {
        cloudContainer.privateCloudDatabase
    }

    private func refreshCloudCache() async throws {
        guard try await cloudAccountIsAvailable() else { return }

        let cloudRecords = try await fetchAllCloudRecords()
        let folderRecords = cloudRecords.filter { $0.recordType == Self.folderRecordType }
        let noteRecords = cloudRecords.filter { $0.recordType == Self.noteRecordType }
        let entryRecords = cloudRecords.filter { $0.recordType == Self.entryRecordType }
        let rootURL = try storageRootURL()

        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let folders = folderRecords
            .compactMap(folderSnapshot(from:))
            .sorted { directoryDepth(of: $0.relativePath) < directoryDepth(of: $1.relativePath) }

        for folder in folders {
            let folderURL = try folderURL(for: folder.relativePath)
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try saveFolderMetadata(folder.metadata, at: folderURL)
            try setModificationDate(folder.modifiedAt, at: folderURL)
        }

        let entriesByNotePath = Dictionary(grouping: entryRecords.compactMap(entrySnapshot(from:))) { $0.notePath }

        for noteRecord in noteRecords {
            guard let note = noteSnapshot(from: noteRecord) else { continue }
            let entries = (entriesByNotePath[note.relativePath] ?? [])
                .map { NoteEntry(id: $0.id, timestamp: $0.timestamp, text: $0.text) }
                .sorted { lhs, rhs in
                    if lhs.timestamp != rhs.timestamp {
                        return lhs.timestamp < rhs.timestamp
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            let document = NoteDocument(
                relativePath: note.relativePath,
                title: note.title,
                metadata: note.metadata,
                entries: entries
            )
            try persistNotePackage(note: document, modifiedAt: note.modifiedAt)
        }

        storageDescription = "iCloud"
        logger.info("refreshCloudCache folders=\(folders.count) notes=\(noteRecords.count) entries=\(entryRecords.count)")
    }

    private func refreshCloudNote(relativePath: String) async throws {
        guard try await cloudAccountIsAvailable() else { return }
        guard let noteRecord = try await fetchRecord(recordType: Self.noteRecordType, key: relativePath),
              let note = noteSnapshot(from: noteRecord) else {
            return
        }

        let entries = try await fetchCloudEntries(relativePath: relativePath)
            .map { NoteEntry(id: $0.id, timestamp: $0.timestamp, text: $0.text) }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        let document = NoteDocument(
            relativePath: note.relativePath,
            title: note.title,
            metadata: note.metadata,
            entries: entries
        )
        try persistNotePackage(note: document, modifiedAt: note.modifiedAt)
    }

    private func uploadFolderTree(at folderURL: URL) async throws {
        guard try await cloudAccountIsAvailable() else { return }
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let rootRelativePath = relativePath(for: folderURL)
        let rootMetadata = loadFolderMetadata(at: folderURL) ?? .default
        let rootModifiedAt = (try? folderURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        try await uploadFolder(relativePath: rootRelativePath, metadata: rootMetadata, modifiedAt: rootModifiedAt)

        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values.isDirectory == true else { continue }

            if url.pathExtension.lowercased() == Self.notePackageExtension {
                let noteRelativePath = logicalNoteRelativePath(for: url, parentRelativePath: parentPath(for: relativePath(for: url)))
                let note = try loadNote(relativePath: noteRelativePath)
                try await uploadNote(note)
                enumerator.skipDescendants()
            } else {
                let metadata = loadFolderMetadata(at: url) ?? .default
                try await uploadFolder(
                    relativePath: relativePath(for: url),
                    metadata: metadata,
                    modifiedAt: values.contentModificationDate ?? Date()
                )
            }
        }
    }

    private func uploadFolder(relativePath: String, metadata: FolderMetadata, modifiedAt: Date) async throws {
        guard try await cloudAccountIsAvailable() else { return }
        let record = try await recordForSave(recordType: Self.folderRecordType, key: relativePath)
        record["relativePath"] = relativePath as CKRecordValue
        record["name"] = ((relativePath as NSString).lastPathComponent) as CKRecordValue
        record["parentPath"] = parentPath(for: relativePath) as CKRecordValue?
        record["emoji"] = metadata.emoji as CKRecordValue
        record["accentStyle"] = metadata.accentStyle.rawValue as CKRecordValue
        record["modifiedAt"] = modifiedAt as CKRecordValue
        try await modifyRecords(saving: [record], deleting: [])
    }

    private func uploadNote(_ note: NoteDocument, modifiedAt: Date? = nil) async throws {
        guard try await cloudAccountIsAvailable() else { return }
        let noteModifiedAt = modifiedAt ?? Date()
        let noteRecord = try await recordForSave(recordType: Self.noteRecordType, key: note.relativePath)
        noteRecord["relativePath"] = note.relativePath as CKRecordValue
        noteRecord["title"] = note.title as CKRecordValue
        noteRecord["parentPath"] = parentPath(for: note.relativePath) as CKRecordValue?
        noteRecord["emoji"] = note.metadata.emoji as CKRecordValue
        noteRecord["accentStyle"] = note.metadata.accentStyle.rawValue as CKRecordValue
        noteRecord["modifiedAt"] = noteModifiedAt as CKRecordValue

        let persistedEntries = persistedEntries(from: note.entries)
        let existingEntries = try await fetchCloudEntries(relativePath: note.relativePath)
        let expectedEntryIDs = Set(persistedEntries.map(\.id))
        let staleRecordIDs = existingEntries
            .filter { !expectedEntryIDs.contains($0.id) }
            .map { recordID(recordType: Self.entryRecordType, key: entryRecordKey(notePath: note.relativePath, entryID: $0.id)) }

        var entryRecords: [CKRecord] = []
        for entry in persistedEntries {
            let record = try await recordForSave(
                recordType: Self.entryRecordType,
                key: entryRecordKey(notePath: note.relativePath, entryID: entry.id)
            )
            record["notePath"] = note.relativePath as CKRecordValue
            record["entryID"] = entry.id.uuidString as CKRecordValue
            record["timestamp"] = entry.timestamp as CKRecordValue
            record["text"] = entry.text as CKRecordValue
            record["modifiedAt"] = noteModifiedAt as CKRecordValue
            entryRecords.append(record)
        }

        try await modifyRecords(saving: [noteRecord] + entryRecords, deleting: staleRecordIDs)
        storageDescription = "iCloud"
    }

    private func deleteCloudTree(relativePath: String) async throws {
        guard try await cloudAccountIsAvailable() else { return }
        let cloudRecords = try await fetchAllCloudRecords()
        let folderRecords = cloudRecords.filter { $0.recordType == Self.folderRecordType }
        let noteRecords = cloudRecords.filter { $0.recordType == Self.noteRecordType }
        let entryRecords = cloudRecords.filter { $0.recordType == Self.entryRecordType }

        let folderIDs = folderRecords
            .compactMap { record -> CKRecord.ID? in
                guard let path = record["relativePath"] as? String,
                      path == relativePath || path.hasPrefix(relativePath + "/") else {
                    return nil
                }
                return record.recordID
            }
        let notePaths = Set(
            noteRecords.compactMap { record -> String? in
                guard let path = record["relativePath"] as? String,
                      path == relativePath || path.hasPrefix(relativePath + "/") else {
                    return nil
                }
                return path
            }
        )
        let noteIDs = noteRecords.filter { record in
            guard let path = record["relativePath"] as? String else { return false }
            return notePaths.contains(path)
        }.map(\.recordID)
        let entryIDs = entryRecords.filter { record in
            guard let notePath = record["notePath"] as? String else { return false }
            return notePaths.contains(notePath)
        }.map(\.recordID)

        try await modifyRecords(saving: [], deleting: folderIDs + noteIDs + entryIDs)
    }

    private func deleteCloudNote(relativePath: String) async throws {
        guard try await cloudAccountIsAvailable() else { return }
        let entries = try await fetchCloudEntries(relativePath: relativePath)
        let entryIDs = entries.map {
            recordID(recordType: Self.entryRecordType, key: entryRecordKey(notePath: relativePath, entryID: $0.id))
        }
        var recordIDsToDelete = entryIDs
        if let noteRecord = try await fetchRecord(recordType: Self.noteRecordType, key: relativePath) {
            recordIDsToDelete.append(noteRecord.recordID)
        }
        try await modifyRecords(
            saving: [],
            deleting: recordIDsToDelete
        )
    }

    private func fetchCloudEntries(relativePath: String) async throws -> [CloudEntrySnapshot] {
        try await fetchAllCloudRecords()
            .filter { $0.recordType == Self.entryRecordType }
            .compactMap(entrySnapshot(from:))
            .filter { $0.notePath == relativePath }
    }

    private func cloudAccountIsAvailable() async throws -> Bool {
        let status: CKAccountStatus = try await withCheckedThrowingContinuation { continuation in
            cloudContainer.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }

        if status == .available {
            storageDescription = "iCloud"
            return true
        }

        storageDescription = "On My Device"
        logger.warning("cloudAccountIsAvailable unavailable status=\(String(describing: status), privacy: .public)")
        return false
    }

    private func fetchRecord(recordType: String, key: String) async throws -> CKRecord? {
        try await ensureCloudRecordZoneExists()
        let id = recordID(recordType: recordType, key: key)
        return try await withCheckedThrowingContinuation { continuation in
            privateDatabase.fetch(withRecordID: id) { record, error in
                if let ckError = error as? CKError, ckError.code == .unknownItem {
                    continuation.resume(returning: nil)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: record)
                }
            }
        }
    }

    private func recordForSave(recordType: String, key: String) async throws -> CKRecord {
        if let record = try await fetchRecord(recordType: recordType, key: key) {
            return record
        }
        return CKRecord(recordType: recordType, recordID: recordID(recordType: recordType, key: key))
    }

    private func fetchAllCloudRecords() async throws -> [CKRecord] {
        try await ensureCloudRecordZoneExists()
        var records: [CKRecord] = []
        var changeToken: CKServerChangeToken?
        var moreComing = true

        while moreComing {
            let changes = try await privateDatabase.recordZoneChanges(
                inZoneWith: Self.cloudRecordZoneID,
                since: changeToken
            )
            for result in changes.modificationResultsByID.values {
                records.append(try result.get().record)
            }
            changeToken = changes.changeToken
            moreComing = changes.moreComing
        }

        return records
    }

    private func modifyRecords(saving recordsToSave: [CKRecord], deleting recordIDsToDelete: [CKRecord.ID]) async throws {
        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return }
        try await ensureCloudRecordZoneExists()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete)
            operation.savePolicy = .changedKeys
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
            privateDatabase.add(operation)
        }
    }

    private func recordID(recordType: String, key: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(recordType)-\(sha256(key))", zoneID: Self.cloudRecordZoneID)
    }

    private func ensureCloudRecordZoneExists() async throws {
        guard !cloudRecordZoneIsReady else { return }

        let zoneID = Self.cloudRecordZoneID
        let zones = try await privateDatabase.recordZones(for: [zoneID])
        if case .success = zones[zoneID] {
            cloudRecordZoneIsReady = true
            return
        }

        if case let .failure(error) = zones[zoneID],
           !isMissingCloudKitItemError(error) {
            throw error
        }

        let result = try await privateDatabase.modifyRecordZones(
            saving: [CKRecordZone(zoneID: zoneID)],
            deleting: []
        )
        if let saveResult = result.saveResults[zoneID] {
            _ = try saveResult.get()
        }
        cloudRecordZoneIsReady = true
        logger.info("ensureCloudRecordZoneExists created zone=\(zoneID.zoneName, privacy: .public)")
    }

    private func isMissingCloudKitItemError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .unknownItem || ckError.code == .zoneNotFound
    }

    private func entryRecordKey(notePath: String, entryID: UUID) -> String {
        "\(notePath)#\(entryID.uuidString)"
    }

    private func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func folderSnapshot(from record: CKRecord) -> CloudFolderSnapshot? {
        guard let relativePath = record["relativePath"] as? String else { return nil }
        return CloudFolderSnapshot(
            relativePath: relativePath,
            metadata: FolderMetadata(
                emoji: (record["emoji"] as? String)?.ifBlank("📁") ?? "📁",
                accentStyle: AccentStyle(rawValue: record["accentStyle"] as? String ?? "") ?? .sky
            ),
            modifiedAt: (record["modifiedAt"] as? Date) ?? record.modificationDate ?? .distantPast
        )
    }

    private func noteSnapshot(from record: CKRecord) -> CloudNoteSnapshot? {
        guard let relativePath = record["relativePath"] as? String else { return nil }
        let title = (record["title"] as? String) ?? fileStem(for: relativePath)
        return CloudNoteSnapshot(
            relativePath: relativePath,
            title: title,
            metadata: NoteMetadata(
                emoji: (record["emoji"] as? String)?.ifBlank("📝") ?? "📝",
                accentStyle: AccentStyle(rawValue: record["accentStyle"] as? String ?? "") ?? .mint
            ),
            modifiedAt: (record["modifiedAt"] as? Date) ?? record.modificationDate ?? .distantPast
        )
    }

    private func entrySnapshot(from record: CKRecord) -> CloudEntrySnapshot? {
        guard let notePath = record["notePath"] as? String,
              let entryIDString = record["entryID"] as? String,
              let entryID = UUID(uuidString: entryIDString) else {
            return nil
        }

        return CloudEntrySnapshot(
            notePath: notePath,
            id: entryID,
            timestamp: (record["timestamp"] as? Date) ?? record.modificationDate ?? .distantPast,
            text: (record["text"] as? String) ?? ""
        )
    }

    private func directoryDepth(of relativePath: String) -> Int {
        relativePath.split(separator: "/").count
    }

    private func setModificationDate(_ date: Date, at url: URL) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

private struct CloudFolderSnapshot {
    let relativePath: String
    let metadata: FolderMetadata
    let modifiedAt: Date
}

private struct CloudNoteSnapshot {
    let relativePath: String
    let title: String
    let metadata: NoteMetadata
    let modifiedAt: Date
}

private struct CloudEntrySnapshot {
    let notePath: String
    let id: UUID
    let timestamp: Date
    let text: String
}

private struct NotePackageManifest: Codable {
    var version = 2
    var metadata: NoteMetadata
}

private extension String {
    func ifBlank(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}

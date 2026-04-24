#if os(macOS)
import AppKit
import CoreServices
import Foundation
import OSLog

private final class FileEventStreamBox: @unchecked Sendable {
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
final class LocalMirrorSyncService: ObservableObject {
    private static let leakedContainerIdentifier = "com.linquist.notefile"
    private static let folderMetadataFileName = ".notefile-folder.json"
    private static let notePackageExtension = "note"

    @Published private(set) var mirroredFolderURL: URL?
    @Published private(set) var statusText = "Select a local folder to mirror your iCloud notes."

    private let bookmarkKey = "LocalMirrorFolderBookmark"
    private let syncManifestKey = "LocalMirrorSyncManifest"
    private weak var repository: NoteRepository?
    private var scheduledSyncTask: Task<Void, Never>?
    private var fileEventStream: FileEventStreamBox?
    private var isSyncing = false
    private var needsFollowUpSync = false
    private let fileEventQueue = DispatchQueue(label: "com.linquist.notefile.localMirrorEvents")
    private let logger = Logger(subsystem: "com.linquist.notefile", category: "LocalMirrorSync")

    init(repository: NoteRepository) {
        self.repository = repository
        repository.localMirrorSyncHandler = { [weak self] reason in
            self?.scheduleSync(reason: reason)
        }
        restoreBookmark()
        startWatchingMirrorFolder()
        scheduleSync(reason: "startup", debounce: .milliseconds(500))
    }

    deinit {
        scheduledSyncTask?.cancel()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"

        if panel.runModal() == .OK, let url = panel.url {
            saveBookmark(for: url)
            mirroredFolderURL = url
            statusText = "Mirroring with \(url.path)"
            startWatchingMirrorFolder()
            scheduleSync(reason: "chooseFolder", debounce: .milliseconds(100))
        }
    }

    func syncNow() async {
        if isSyncing {
            needsFollowUpSync = true
            return
        }

        guard let mirroredFolderURL else {
            statusText = "Select a local folder to mirror your iCloud notes."
            return
        }

        guard let repository else { return }
        isSyncing = true
        defer {
            isSyncing = false
            if needsFollowUpSync {
                needsFollowUpSync = false
                scheduleSync(reason: "followUp", debounce: .seconds(1))
            }
        }

        let didAccess = mirroredFolderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                mirroredFolderURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let cloudRoot = try repository.storageRootURL()
            try FileManager.default.createDirectory(at: mirroredFolderURL, withIntermediateDirectories: true)
            logger.info("syncNow start cloudRoot=\(cloudRoot.path, privacy: .public) localRoot=\(mirroredFolderURL.path, privacy: .public)")

            let previousManifest = loadSyncManifest(for: mirroredFolderURL)
            let previousFiles = previousManifest?.files ?? []
            let previousDirectories = previousManifest?.directories ?? []

            var currentCloudSnapshot = try cloudSnapshot(at: cloudRoot, repository: repository)
            var currentLocalSnapshot = try localSnapshot(at: mirroredFolderURL)
            logger.debug("syncNow snapshot cloudFiles=\(currentCloudSnapshot.files.count) localFiles=\(currentLocalSnapshot.files.count) previousFiles=\(previousFiles.count)")

            let allFiles = Set(currentCloudSnapshot.files.keys)
                .union(currentLocalSnapshot.files.keys)
                .union(previousFiles)

            for relativePath in allFiles.sorted() {
                let cloudFile = currentCloudSnapshot.files[relativePath]
                let localFile = currentLocalSnapshot.files[relativePath]

                switch (cloudFile, localFile) {
                case let (cloudFile?, nil):
                    if previousFiles.contains(relativePath) {
                        logger.notice("syncNow deleteFromCloud relativePath=\(relativePath, privacy: .public) reason=missingLocalPreviouslySynced")
                        try await removeCloudFile(relativePath: relativePath, kind: cloudFile.kind, cloudRoot: cloudRoot, repository: repository)
                    } else {
                        logger.info("syncNow copyCloudToLocal relativePath=\(relativePath, privacy: .public)")
                        try copyCloudFileToLocal(
                            relativePath: relativePath,
                            file: cloudFile,
                            localRoot: mirroredFolderURL,
                            repository: repository
                        )
                    }

                case let (nil, localFile?):
                    if previousFiles.contains(relativePath) {
                        logger.notice("syncNow deleteFromLocal relativePath=\(relativePath, privacy: .public) reason=missingCloudPreviouslySynced")
                        try removeItemIfExists(at: localFile.url)
                    } else {
                        logger.info("syncNow copyLocalToCloud relativePath=\(relativePath, privacy: .public)")
                        try await copyLocalFileToCloud(
                            relativePath: relativePath,
                            file: localFile,
                            cloudRoot: cloudRoot,
                            repository: repository
                        )
                    }

                case let (cloudFile?, localFile?):
                    if cloudFile.modifiedAt > localFile.modifiedAt.addingTimeInterval(1) {
                        logger.info("syncNow updateLocalFromCloud relativePath=\(relativePath, privacy: .public)")
                        try copyCloudFileToLocal(
                            relativePath: relativePath,
                            file: cloudFile,
                            localRoot: mirroredFolderURL,
                            repository: repository
                        )
                    } else if localFile.modifiedAt > cloudFile.modifiedAt.addingTimeInterval(1) {
                        logger.info("syncNow updateCloudFromLocal relativePath=\(relativePath, privacy: .public)")
                        try await copyLocalFileToCloud(
                            relativePath: relativePath,
                            file: localFile,
                            cloudRoot: cloudRoot,
                            repository: repository
                        )
                    }

                default:
                    continue
                }
            }

            currentCloudSnapshot = try cloudSnapshot(at: cloudRoot, repository: repository)
            currentLocalSnapshot = try localSnapshot(at: mirroredFolderURL)

            let allDirectories = Set(currentCloudSnapshot.directories)
                .union(currentLocalSnapshot.directories)
                .union(previousDirectories)

            let directoriesToCreate = allDirectories
                .filter { relativePath in
                    let inCloud = currentCloudSnapshot.directories.contains(relativePath)
                    let inLocal = currentLocalSnapshot.directories.contains(relativePath)
                    let existedPreviously = previousDirectories.contains(relativePath)
                    return !existedPreviously && inCloud != inLocal
                }
                .sorted { directoryDepth(of: $0) < directoryDepth(of: $1) }

            let directoriesToDelete = allDirectories
                .filter { relativePath in
                    let inCloud = currentCloudSnapshot.directories.contains(relativePath)
                    let inLocal = currentLocalSnapshot.directories.contains(relativePath)
                    let existedPreviously = previousDirectories.contains(relativePath)
                    return existedPreviously && inCloud != inLocal
                }
                .sorted { directoryDepth(of: $0) > directoryDepth(of: $1) }

            for relativePath in directoriesToCreate {
                if currentCloudSnapshot.directories.contains(relativePath) {
                    logger.info("syncNow createLocalDirectory relativePath=\(relativePath, privacy: .public)")
                    try createDirectoryIfNeeded(relativePath, under: mirroredFolderURL)
                } else if currentLocalSnapshot.directories.contains(relativePath) {
                    logger.info("syncNow createCloudDirectory relativePath=\(relativePath, privacy: .public)")
                    try createDirectoryIfNeeded(relativePath, under: cloudRoot)
                }
            }

            for relativePath in directoriesToDelete {
                if currentCloudSnapshot.directories.contains(relativePath) {
                    logger.notice("syncNow deleteCloudDirectory relativePath=\(relativePath, privacy: .public)")
                    try removeItemIfExists(at: cloudRoot.appendingPathComponent(relativePath, isDirectory: true))
                } else if currentLocalSnapshot.directories.contains(relativePath) {
                    logger.notice("syncNow deleteLocalDirectory relativePath=\(relativePath, privacy: .public)")
                    try removeItemIfExists(at: mirroredFolderURL.appendingPathComponent(relativePath, isDirectory: true))
                }
            }

            let finalCloudSnapshot = try cloudSnapshot(at: cloudRoot, repository: repository)
            let finalLocalSnapshot = try localSnapshot(at: mirroredFolderURL)
            saveSyncManifest(
                SyncManifest(
                    mirroredFolderPath: mirroredFolderURL.path,
                    files: Set(finalCloudSnapshot.files.keys).union(finalLocalSnapshot.files.keys),
                    directories: Set(finalCloudSnapshot.directories).union(finalLocalSnapshot.directories)
                )
            )

            statusText = "Last sync: \(MarkdownNoteCodec.displayDateFormatter.string(from: Date()))"
            logger.info("syncNow completed finalCloudFiles=\(finalCloudSnapshot.files.count) finalLocalFiles=\(finalLocalSnapshot.files.count)")
            await repository.loadBrowser()
        } catch {
            statusText = "Sync failed: \(error.localizedDescription)"
            logger.error("syncNow failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleSync(reason: String, debounce: Duration = .seconds(1)) {
        guard mirroredFolderURL != nil else { return }

        if isSyncing {
            needsFollowUpSync = true
            logger.debug("scheduleSync deferred while syncing reason=\(reason, privacy: .public)")
            return
        }

        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
        logger.debug("scheduleSync reason=\(reason, privacy: .public)")
    }

    private func startWatchingMirrorFolder() {
        stopWatchingMirrorFolder()

        guard let mirroredFolderURL else { return }

        let didAccess = mirroredFolderURL.startAccessingSecurityScopedResource()
        if didAccess {
            mirroredFolderURL.stopAccessingSecurityScopedResource()
        }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, callbackInfo, eventCount, eventPaths, eventFlags, _ in
            guard let callbackInfo else { return }
            let service = Unmanaged<LocalMirrorSyncService>.fromOpaque(callbackInfo).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: eventCount))

            Task { @MainActor in
                service.handleMirrorFileEvents(paths: paths, flags: flags)
            }
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [mirroredFolderURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.75,
            flags
        ) else {
            logger.error("startWatchingMirrorFolder failed path=\(mirroredFolderURL.path, privacy: .public)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, fileEventQueue)
        if FSEventStreamStart(stream) {
            fileEventStream = FileEventStreamBox(stream)
            logger.info("startWatchingMirrorFolder path=\(mirroredFolderURL.path, privacy: .public)")
        } else {
            FileEventStreamBox(stream).stop()
            logger.error("startWatchingMirrorFolder could not start path=\(mirroredFolderURL.path, privacy: .public)")
        }
    }

    private func stopWatchingMirrorFolder() {
        guard let fileEventStream else { return }
        fileEventStream.stop()
        self.fileEventStream = nil
    }

    private func handleMirrorFileEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard mirroredFolderURL != nil else { return }

        if isSyncing {
            needsFollowUpSync = true
            return
        }

        let ignoredFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        let hasMeaningfulEvent = flags.contains { flags in
            flags & ignoredFlags == 0
        }

        guard hasMeaningfulEvent else { return }
        logger.debug("handleMirrorFileEvents count=\(paths.count)")
        scheduleSync(reason: "mirrorFileEvent", debounce: .seconds(1))
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            mirroredFolderURL = url
            if isStale {
                saveBookmark(for: url)
            }
            statusText = "Mirroring with \(url.path)"
        } catch {
            statusText = "Could not reopen the previous mirror folder."
        }
    }

    private func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            statusText = "Could not save access to \(url.lastPathComponent)."
        }
    }

    private func loadSyncManifest(for mirroredFolderURL: URL) -> SyncManifest? {
        guard let data = UserDefaults.standard.data(forKey: syncManifestKey),
              let manifest = try? JSONDecoder().decode(SyncManifest.self, from: data),
              manifest.mirroredFolderPath == mirroredFolderURL.path else {
            return nil
        }

        let filteredFiles = manifest.files.filter { isValidMirrorRelativePath($0) }
        let filteredDirectories = manifest.directories.filter { isValidMirrorRelativePath($0) }

        if filteredFiles != manifest.files || filteredDirectories != manifest.directories {
            let cleanedManifest = SyncManifest(
                mirroredFolderPath: manifest.mirroredFolderPath,
                files: filteredFiles,
                directories: filteredDirectories
            )
            saveSyncManifest(cleanedManifest)
            logger.warning("loadSyncManifest removed stale absolute paths files=\(manifest.files.count - filteredFiles.count) directories=\(manifest.directories.count - filteredDirectories.count)")
            return cleanedManifest
        }

        return manifest
    }

    private func saveSyncManifest(_ manifest: SyncManifest) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        UserDefaults.standard.set(data, forKey: syncManifestKey)
    }

    private func cloudSnapshot(at rootURL: URL, repository: NoteRepository) throws -> MirrorSnapshot {
        let fileManager = FileManager.default
        var files: [String: MirrorFileRecord] = [:]
        var directories: Set<String> = []

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        ) else {
            return MirrorSnapshot(files: [:], directories: [])
        }

        for case let fileURL as URL in enumerator {
            guard let relativePath = relativePath(from: fileURL, under: rootURL) else {
                continue
            }

            guard !shouldSkipRelativePath(relativePath) else {
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values.isDirectory == true {
                if fileURL.pathExtension.lowercased() == Self.notePackageExtension {
                    let noteRelativePath = logicalNoteRelativePath(fromPackageRelativePath: relativePath)
                    files[noteRelativePath] = MirrorFileRecord(
                        kind: .note,
                        url: fileURL,
                        modifiedAt: try repository.noteModificationDate(relativePath: noteRelativePath)
                    )
                    enumerator.skipDescendants()
                    continue
                }

                if shouldSkipDirectory(named: fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }

                directories.insert(relativePath)
                continue
            }

            if fileURL.lastPathComponent == Self.folderMetadataFileName {
                files[relativePath] = MirrorFileRecord(
                    kind: .folderMetadata,
                    url: fileURL,
                    modifiedAt: values.contentModificationDate ?? .distantPast
                )
            } else if fileURL.pathExtension.lowercased() == "md" {
                files[relativePath] = MirrorFileRecord(
                    kind: .note,
                    url: fileURL,
                    modifiedAt: try repository.noteModificationDate(relativePath: relativePath)
                )
            }
        }

        return MirrorSnapshot(files: files, directories: directories)
    }

    private func localSnapshot(at rootURL: URL) throws -> MirrorSnapshot {
        let fileManager = FileManager.default
        var files: [String: MirrorFileRecord] = [:]
        var directories: Set<String> = []

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        ) else {
            return MirrorSnapshot(files: [:], directories: [])
        }

        for case let fileURL as URL in enumerator {
            guard let relativePath = relativePath(from: fileURL, under: rootURL) else {
                continue
            }

            guard !shouldSkipRelativePath(relativePath) else {
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values.isDirectory == true {
                if shouldSkipDirectory(named: fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                directories.insert(relativePath)
                continue
            }

            if fileURL.lastPathComponent == Self.folderMetadataFileName {
                files[relativePath] = MirrorFileRecord(
                    kind: .folderMetadata,
                    url: fileURL,
                    modifiedAt: values.contentModificationDate ?? .distantPast
                )
            } else if fileURL.pathExtension.lowercased() == "md" {
                files[relativePath] = MirrorFileRecord(
                    kind: .note,
                    url: fileURL,
                    modifiedAt: values.contentModificationDate ?? .distantPast
                )
            }
        }

        return MirrorSnapshot(files: files, directories: directories)
    }

    private func copyCloudFileToLocal(
        relativePath: String,
        file: MirrorFileRecord,
        localRoot: URL,
        repository: NoteRepository
    ) throws {
        let localURL = localRoot.appendingPathComponent(relativePath)

        switch file.kind {
        case .note:
            let markdown = try repository.exportCombinedMarkdown(relativePath: relativePath)
            try writeText(markdown, to: localURL, modifiedAt: file.modifiedAt)
            logger.debug("copyCloudFileToLocal note relativePath=\(relativePath, privacy: .public) destination=\(localURL.path, privacy: .public)")

        case .folderMetadata:
            try copyItem(from: file.url, to: localURL)
            logger.debug("copyCloudFileToLocal metadata relativePath=\(relativePath, privacy: .public) destination=\(localURL.path, privacy: .public)")
        }
    }

    private func copyLocalFileToCloud(
        relativePath: String,
        file: MirrorFileRecord,
        cloudRoot: URL,
        repository: NoteRepository
    ) async throws {
        switch file.kind {
        case .note:
            let markdown = try String(contentsOf: file.url, encoding: .utf8)
            try await repository.importCombinedMarkdown(
                markdown,
                relativePath: relativePath,
                sourceModifiedAt: file.modifiedAt
            )
            logger.debug("copyLocalFileToCloud note relativePath=\(relativePath, privacy: .public) source=\(file.url.path, privacy: .public)")

        case .folderMetadata:
            let destinationURL = cloudRoot.appendingPathComponent(relativePath)
            try copyItem(from: file.url, to: destinationURL)
            logger.debug("copyLocalFileToCloud metadata relativePath=\(relativePath, privacy: .public) destination=\(destinationURL.path, privacy: .public)")
        }
    }

    private func removeCloudFile(
        relativePath: String,
        kind: MirrorFileKind,
        cloudRoot: URL,
        repository: NoteRepository
    ) async throws {
        switch kind {
        case .note:
            logger.notice("removeCloudFile note relativePath=\(relativePath, privacy: .public)")
            try await repository.deleteNote(relativePath: relativePath)

        case .folderMetadata:
            logger.notice("removeCloudFile metadata relativePath=\(relativePath, privacy: .public)")
            try removeItemIfExists(at: cloudRoot.appendingPathComponent(relativePath))
        }
    }

    private func createDirectoryIfNeeded(_ relativePath: String, under rootURL: URL) throws {
        guard !relativePath.isEmpty else { return }
        let directoryURL = rootURL.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func copyItem(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        let modifiedAt = try sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
        try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: destinationURL.path)
    }

    private func writeText(_ text: String, to destinationURL: URL, modifiedAt: Date) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: destinationURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: destinationURL.path)
    }

    private func removeItemIfExists(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func directoryDepth(of relativePath: String) -> Int {
        relativePath.split(separator: "/").count
    }

    private func shouldSkipDirectory(named name: String) -> Bool {
        name.hasPrefix(".")
    }

    private func relativePath(from url: URL, under rootURL: URL) -> String? {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents

        guard urlComponents.count > rootComponents.count,
              Array(urlComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }

        return urlComponents
            .dropFirst(rootComponents.count)
            .joined(separator: "/")
    }

    private func logicalNoteRelativePath(fromPackageRelativePath relativePath: String) -> String {
        let basePath = (relativePath as NSString).deletingPathExtension
        return (basePath as NSString).appendingPathExtension("md") ?? "\(basePath).md"
    }

    private func shouldSkipRelativePath(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count >= 5 else { return false }

        return components[0] == "Users"
            && components[2] == "Library"
            && components[3] == "Containers"
            && components[4] == Self.leakedContainerIdentifier
    }

    private func isValidMirrorRelativePath(_ relativePath: String) -> Bool {
        !relativePath.isEmpty
            && !relativePath.hasPrefix("/")
            && !shouldSkipRelativePath(relativePath)
    }
}

private struct MirrorSnapshot {
    let files: [String: MirrorFileRecord]
    let directories: Set<String>
}

private struct MirrorFileRecord {
    let kind: MirrorFileKind
    let url: URL
    let modifiedAt: Date
}

private enum MirrorFileKind: String, Codable {
    case note
    case folderMetadata
}

private struct SyncManifest: Codable {
    let mirroredFolderPath: String
    let files: Set<String>
    let directories: Set<String>
}
#endif

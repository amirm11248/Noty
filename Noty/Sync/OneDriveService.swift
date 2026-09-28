import Foundation
import Observation

/// Mirrors rendered PDFs into a folder the user selected from Files. Selecting
/// a OneDrive location works through the OneDrive File Provider, so the user
/// signs in with Microsoft's own app and Noty never handles credentials.
@MainActor
@Observable
final class OneDriveService {
    private(set) var isConnected = false
    private(set) var mirrorFolderName: String?
    private(set) var syncStatus = "Choose a OneDrive folder in Files to connect."
    private(set) var lastError: String?

    @ObservationIgnored private var mirrorFolderURL: URL?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var syncRequestedAgain = false

    private let bookmarkKey = "noty.onedrive.folder.bookmark"
    private let fileMapKeyPrefix = "noty.onedrive.mirrored-files."
    private let revisionsKeyPrefix = "noty.onedrive.document-revisions."

    init() {
        restoreFolderBookmark()
    }

    /// Keeps the API expected by the app root. The Files folder picker is
    /// presented by LibraryView; this method validates the persisted grant.
    func connect() async throws {
        guard let url = resolvedFolderURL() else {
            throw OneDriveError.folderSelectionRequired
        }
        try withFolderAccess(url) { _ in }
        isConnected = true
        mirrorFolderName = url.lastPathComponent
        syncStatus = "Folder selected: \(url.lastPathComponent)."
        lastError = nil
    }

    /// Persists the security-scoped folder selected through the Files picker.
    func configureMirrorFolder(folderURL: URL) throws {
        var accessError: Error?
        let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let values = try folderURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw OneDriveError.notAFolder
            }
            let bookmark = try Self.persistentFolderBookmark(for: folderURL)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            mirrorFolderURL = folderURL
            mirrorFolderName = folderURL.lastPathComponent
            isConnected = true
            lastError = nil
            syncStatus = "Folder selected: \(folderURL.lastPathComponent)."

        } catch {
            accessError = error
        }

        if let accessError {
            lastError = accessError.localizedDescription
            syncStatus = "Could not use the selected OneDrive folder."
            isConnected = false
            throw accessError
        }
    }

    /// Disconnecting removes Noty's saved folder grant. Files already written
    /// to OneDrive remain there.
    func disconnect() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        mirrorFolderURL = nil
        mirrorFolderName = nil
        isConnected = false
        lastError = nil
        syncStatus = "Choose a OneDrive folder in Files to connect."
    }

    /// Exports each note, book, and imported PDF to a stable PDF in the
    /// selected File Provider folder. Calls during a sync request one final
    /// pass so edits made during rendering are not missed.
    func syncAllPDFs(store: NotyStore) async {
        if isSyncing {
            syncRequestedAgain = true
            return
        }

        isSyncing = true
        repeat {
            syncRequestedAgain = false
            await performSync(store: store)
        } while syncRequestedAgain
        isSyncing = false
    }

    private func performSync(store: NotyStore) async {
        guard let folderURL = resolvedFolderURL() else {
            isConnected = false
            syncStatus = "Choose or re-select a OneDrive folder in Files."
            return
        }

        syncStatus = "Saving PDF copies to the selected Files folder…"
        lastError = nil
        isConnected = true
        mirrorFolderName = folderURL.lastPathComponent

        do {
            var syncErrors: [String] = []
            var syncedCount = 0
            var skippedCount = 0
            var hadRetainedCopies = false
            let documents = store.documents
            let documentIDs = Set(documents.map { $0.id.uuidString })
            let fileMapKey = folderMetadataKey(prefix: fileMapKeyPrefix, folderURL: folderURL)
            let revisionsKey = folderMetadataKey(prefix: revisionsKeyPrefix, folderURL: folderURL)
            var fileMap = UserDefaults.standard.dictionary(forKey: fileMapKey) as? [String: String] ?? [:]
            var revisions = UserDefaults.standard.dictionary(forKey: revisionsKey) as? [String: Double] ?? [:]

            try withFolderAccess(folderURL) { accessibleFolder in
                for document in documents {
                    let key = document.id.uuidString
                    let revision = document.updatedAt.timeIntervalSince1970

                    do {
                        let previousFileName = fileMap[key]
                        let fileName = Self.fileName(for: document)
                        let destination = accessibleFolder.appendingPathComponent(fileName, isDirectory: false)
                        let fileExists = FileManager.default.fileExists(atPath: destination.path)
                        if fileExists, revisions[key] == revision, previousFileName == fileName {
                            skippedCount += 1
                            continue
                        }

                        let renderedPDF = try NotyExportService.exportPDFForSync(
                            documentID: document.id,
                            store: store
                        )
                        let pdfData = try Data(contentsOf: renderedPDF)
                        try Self.coordinatedWrite(pdfData, to: destination)

                        var oldFileRemoved = true
                        if let oldName = previousFileName, oldName != fileName {
                            let oldURL = accessibleFolder.appendingPathComponent(oldName, isDirectory: false)
                            do {
                                try Self.coordinatedDelete(oldURL)
                            } catch {
                                oldFileRemoved = false
                                syncErrors.append("Could not remove the previous copy of \(document.title): \(error.localizedDescription)")
                            }
                        }
                        if oldFileRemoved {
                            fileMap[key] = fileName
                        }
                        revisions[key] = revision
                        syncedCount += 1
                    } catch {
                        syncErrors.append("\(document.title): \(error.localizedDescription)")
                    }
                }

                // Retire tracking for documents that have been deleted from
                // the library, but keep their exported PDFs as recoverable
                // copies in the user's Files folder.
                let obsoleteEntries = fileMap.filter { !documentIDs.contains($0.key) }
                hadRetainedCopies = !obsoleteEntries.isEmpty
                for (documentID, _) in obsoleteEntries {
                    fileMap.removeValue(forKey: documentID)
                    revisions.removeValue(forKey: documentID)
                }
            }

            UserDefaults.standard.set(fileMap, forKey: fileMapKey)
            UserDefaults.standard.set(revisions, forKey: revisionsKey)
            if syncErrors.isEmpty {
                lastError = nil
                if documents.isEmpty {
                    syncStatus = hadRetainedCopies
                        ? "No current documents. Previously saved PDF copies remain in the selected folder."
                        : "Folder selected. No PDFs to save yet; folder write access has not been tested."
                } else {
                    syncStatus = "PDF copies saved to selected folder · \(syncedCount) updated, \(skippedCount) unchanged."
                }
            } else {
                lastError = syncErrors.joined(separator: "\n")
                syncStatus = "Saved \(syncedCount) PDF cop\(syncedCount == 1 ? "y" : "ies") to the selected folder; \(syncErrors.count) had error\(syncErrors.count == 1 ? "" : "s")."
            }
            isConnected = true
        } catch {
            let description = Self.friendlyDescription(for: error)
            lastError = description
            syncStatus = description
            // A write/network failure does not revoke the saved Files grant.
            // Keep the folder selected so the user can retry manually.
            isConnected = mirrorFolderURL != nil
        }
    }

    private func resolvedFolderURL() -> URL? {
        if let mirrorFolderURL {
            return mirrorFolderURL
        }
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }

        do {
            let resolved = try Self.resolvePersistentFolderBookmark(bookmark)
            let url = resolved.url
            mirrorFolderURL = url
            mirrorFolderName = url.lastPathComponent
            if resolved.isStale {
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let refreshedBookmark = try Self.persistentFolderBookmark(for: url)
                UserDefaults.standard.set(refreshedBookmark, forKey: bookmarkKey)
            }
            return url
        } catch {
            mirrorFolderURL = nil
            mirrorFolderName = nil
            isConnected = false
            lastError = "Selected Files folder access expired. Re-select the folder in Files."
            syncStatus = lastError ?? "OneDrive folder access expired."
            return nil
        }
    }

    private func restoreFolderBookmark() {
        guard let url = resolvedFolderURL() else { return }
        mirrorFolderName = url.lastPathComponent
        isConnected = true
        syncStatus = "Folder selected: \(url.lastPathComponent)."
    }

    private func withFolderAccess<T>(_ folderURL: URL, body: (URL) throws -> T) throws -> T {
        let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try folderURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw OneDriveError.notAFolder
        }
        return try body(folderURL)
    }

    private func folderMetadataKey(prefix: String, folderURL: URL) -> String {
        prefix + folderURL.standardizedFileURL.path
    }

    /// On iOS, persist the directory-picker grant as a minimal bookmark so a
    /// File Provider folder (including OneDrive) can be reopened after relaunch.
    private static func persistentFolderBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func resolvePersistentFolderBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private static func coordinatedDelete(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var deletionError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                deletionError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let deletionError { throw deletionError }
    }

    private static func fileName(for document: NotyDocument) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let cleaned = document.title
            .components(separatedBy: disallowed)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))
        return "\(title) · \(document.id.uuidString.prefix(8)).pdf"
    }

    private static func friendlyDescription(for error: Error) -> String {
        if let error = error as? OneDriveError {
            return error.localizedDescription
        }
        return "The selected Files folder could not be reached. Re-select it if access expired. \(error.localizedDescription)"
    }
}

private enum OneDriveError: LocalizedError {
    case folderSelectionRequired
    case notAFolder

    var errorDescription: String? {
        switch self {
        case .folderSelectionRequired:
            return "Choose a writable OneDrive folder in Files to connect."
        case .notAFolder:
            return "The selected location is not a folder. Choose a OneDrive folder in Files."
        }
    }
}

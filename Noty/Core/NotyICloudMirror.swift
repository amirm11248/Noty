import Foundation

struct NotyICloudSyncResult {
    let manifest: NotyStoreManifest
    let localManifestChanged: Bool
    let syncedAt: Date
    let note: String?
    let restoredDocumentIDs: [UUID]
    private let installedAssets: [NotyInstalledAsset]

    func rollbackInstalledAssets() {
        for installedAsset in installedAssets.reversed() {
            installedAsset.rollback()
        }
    }

    func finalizeInstalledAssets() {
        for installedAsset in installedAssets {
            installedAsset.finalize()
        }
    }

    fileprivate init(
        manifest: NotyStoreManifest,
        localManifestChanged: Bool,
        syncedAt: Date,
        note: String?,
        restoredDocumentIDs: [UUID],
        installedAssets: [NotyInstalledAsset]
    ) {
        self.manifest = manifest
        self.localManifestChanged = localManifestChanged
        self.syncedAt = syncedAt
        self.note = note
        self.restoredDocumentIDs = restoredDocumentIDs
        self.installedAssets = installedAssets
    }
}

private struct NotyMirrorCurrent: Codable {
    var version: Int
    var generationID: UUID
    var savedAt: Date
}

private struct NotyMirrorSnapshot: Codable {
    var version: Int
    var generationID: UUID
    var createdAt: Date
    var manifest: NotyStoreManifest
    var packages: [NotyMirrorPackageReference]
}

private struct NotyMirrorPackageReference: Codable, Hashable {
    var documentID: UUID
    var revisionID: UUID
    var updatedAt: Date
}

private struct NotyAssetReplacement {
    var documentID: UUID
    var stagedURL: URL
    var finalURL: URL
}

private struct NotyInstalledAsset {
    var finalURL: URL
    var backupURL: URL?
    var installedNewDirectory: Bool

    func rollback() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: finalURL.path) {
            try? fileManager.removeItem(at: finalURL)
        }
        if let backupURL, fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.moveItem(at: backupURL, to: finalURL)
        }
    }

    func finalize() {
        guard let backupURL, FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try? FileManager.default.removeItem(at: backupURL)
    }
}

@MainActor
extension NotyStore {
    static func performICloudSync(
        localDirectory: URL,
        selectedFolderURL: URL,
        initialManifest: NotyStoreManifest
    ) throws -> NotyICloudSyncResult {
        try NotyMirrorSynchronizer(
            localDirectory: localDirectory,
            selectedFolderURL: selectedFolderURL,
            localManifest: initialManifest
        ).sync()
    }
}

private struct NotyMirrorSynchronizer {
    private let localDirectory: URL
    private let selectedFolderURL: URL
    private let localManifest: NotyStoreManifest
    private let fileManager = FileManager.default

    private var preferredSyncRootURL: URL { selectedFolderURL.appendingPathComponent("Noty Sync", isDirectory: true) }
    private var legacyBackupRootURL: URL { selectedFolderURL.appendingPathComponent("Noty Backup", isDirectory: true) }
    private var backupRootURL: URL {
        if fileManager.fileExists(atPath: preferredSyncRootURL.path) { return preferredSyncRootURL }
        if fileManager.fileExists(atPath: legacyBackupRootURL.path) { return legacyBackupRootURL }
        return preferredSyncRootURL
    }
    private var snapshotsURL: URL { backupRootURL.appendingPathComponent("Snapshots", isDirectory: true) }
    private var packagesURL: URL { backupRootURL.appendingPathComponent("Packages", isDirectory: true) }
    private var currentURL: URL { backupRootURL.appendingPathComponent("Current.json") }
    private var localAssetsURL: URL { localDirectory.appendingPathComponent("Assets", isDirectory: true) }
    private var localMirrorStagingURL: URL { localDirectory.appendingPathComponent(".mirror-staging", isDirectory: true) }
    private var localMirrorPreviousURL: URL { localDirectory.appendingPathComponent(".mirror-previous", isDirectory: true) }

    init(localDirectory: URL, selectedFolderURL: URL, localManifest: NotyStoreManifest) {
        self.localDirectory = localDirectory
        self.selectedFolderURL = selectedFolderURL
        self.localManifest = localManifest
    }

    func sync() throws -> NotyICloudSyncResult {
        let beganAccess = selectedFolderURL.startAccessingSecurityScopedResource()
        defer {
            if beganAccess { selectedFolderURL.stopAccessingSecurityScopedResource() }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: selectedFolderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NotyStoreError.iCloudFolderUnavailable
        }
        try fileManager.createDirectory(at: backupRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: packagesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: localMirrorStagingURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: localMirrorPreviousURL, withIntermediateDirectories: true)

        let remoteSnapshot = try readCurrentSnapshot()
        let merge = try merge(local: localManifest, remote: remoteSnapshot)
        var installedAssets: [NotyInstalledAsset] = []
        do {
            for replacement in merge.assetReplacements {
                installedAssets.append(try install(replacement))
            }
            let remoteAlreadyMatches = remoteSnapshot.map { snapshot in
                Self.fingerprint(merge.manifest) == Self.fingerprint(snapshot.manifest)
                    && merge.assetReplacements.isEmpty
                    && merge.packageReferences.count == merge.manifest.documents.count
            } ?? false
            if !remoteAlreadyMatches {
                try writeSnapshot(merge: merge)
            }
        } catch {
            for installedAsset in installedAssets.reversed() {
                installedAsset.rollback()
            }
            throw error
        }

        let manifestChanged = Self.fingerprint(merge.manifest) != Self.fingerprint(localManifest)
        return NotyICloudSyncResult(
            manifest: merge.manifest,
            localManifestChanged: manifestChanged,
            syncedAt: .now,
            note: merge.note,
            restoredDocumentIDs: merge.restoredDocumentIDs,
            installedAssets: installedAssets
        )
    }

    private func readCurrentSnapshot() throws -> NotyMirrorSnapshot? {
        guard fileManager.fileExists(atPath: currentURL.path) else { return nil }
        let data: Data
        do {
            data = try coordinatedRead(currentURL)
        } catch {
            throw NotyStoreError.invalidMirrorSnapshot(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pointer: NotyMirrorCurrent
        do {
            pointer = try decoder.decode(NotyMirrorCurrent.self, from: data)
        } catch {
            throw NotyStoreError.invalidMirrorSnapshot("the current backup index is damaged")
        }
        guard pointer.version == 1 else {
            throw NotyStoreError.invalidMirrorSnapshot("the backup version is not supported by this app")
        }
        let snapshotURL = snapshotsURL.appendingPathComponent(pointer.generationID.uuidString, isDirectory: true)
            .appendingPathComponent("manifest.json")
        let snapshotData: Data
        do {
            snapshotData = try coordinatedRead(snapshotURL)
        } catch {
            throw NotyStoreError.invalidMirrorSnapshot("the current backup generation is missing or unavailable")
        }
        do {
            let snapshot = try decoder.decode(NotyMirrorSnapshot.self, from: snapshotData)
            guard snapshot.version == 1, snapshot.generationID == pointer.generationID else {
                throw NotyStoreError.invalidMirrorSnapshot("the backup generation index does not match its contents")
            }
            return snapshot
        } catch let error as NotyStoreError {
            throw error
        } catch {
            throw NotyStoreError.invalidMirrorSnapshot("the saved library manifest is damaged")
        }
    }

    private struct MergeResult {
        var manifest: NotyStoreManifest
        var assetReplacements: [NotyAssetReplacement]
        var packageReferences: [UUID: NotyMirrorPackageReference]
        var restoredDocumentIDs: [UUID]
        var note: String?
    }

    private func merge(local: NotyStoreManifest, remote: NotyMirrorSnapshot?) throws -> MergeResult {
        let remoteManifest = remote?.manifest ?? NotyStoreManifest()
        let documentTombstones = newestByID(local.deletions + remoteManifest.deletions, date: \.deletedAt)
        let folderTombstones = newestByID(local.folderDeletions + remoteManifest.folderDeletions, date: \.deletedAt)
        let localFolders = Dictionary(uniqueKeysWithValues: local.folders.map { ($0.id, $0) })
        var mergedFolders = local.folders
        for remoteFolder in remoteManifest.folders where localFolders[remoteFolder.id] == nil {
            mergedFolders.append(remoteFolder)
        }
        mergedFolders.removeAll { folderTombstones[$0.id] != nil }
        let validFolderIDs = Set(mergedFolders.map(\.id))

        let localDocuments = Dictionary(uniqueKeysWithValues: local.documents.map { ($0.id, $0) })
        let remoteDocuments = Dictionary(uniqueKeysWithValues: remoteManifest.documents.map { ($0.id, $0) })
        let remotePackages = Dictionary(uniqueKeysWithValues: (remote?.packages ?? []).map { ($0.documentID, $0) })
        let ids = orderedIDs(local.documents.map(\.id), remoteManifest.documents.map(\.id))
        var mergedDocuments: [NotyDocument] = []
        var assetReplacements: [NotyAssetReplacement] = []
        var packageReferences: [UUID: NotyMirrorPackageReference] = [:]
        var restoredDocumentIDs: [UUID] = []

        for id in ids {
            let localDocument = localDocuments[id]
            let remoteDocument = remoteDocuments[id]
            guard localDocument != nil || remoteDocument != nil else { continue }
            let latestDocumentDate = max(localDocument?.updatedAt ?? .distantPast, remoteDocument?.updatedAt ?? .distantPast)
            if let tombstone = documentTombstones[id], tombstone.deletedAt >= latestDocumentDate {
                continue
            }

            var chosen = localDocument
            var chosenRemoteReference: NotyMirrorPackageReference?
            if let remoteDocument, localDocument == nil || remoteDocument.updatedAt > localDocument!.updatedAt {
                guard let reference = remotePackages[id] else {
                    throw NotyStoreError.invalidMirrorSnapshot("a document package reference is missing")
                }
                let remotePackageURL = packageURL(reference)
                guard fileManager.fileExists(atPath: remotePackageURL.path) else {
                    throw NotyStoreError.invalidMirrorSnapshot("a document package is missing from the backup")
                }
                let stagingURL = localMirrorStagingURL.appendingPathComponent("\(id.uuidString)-\(UUID().uuidString)", isDirectory: true)
                try fileManager.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try copyRemotePackage(from: remotePackageURL, to: stagingURL)
                    guard isCompletePackage(stagingURL, for: remoteDocument) else {
                        throw NotyStoreError.invalidMirrorSnapshot("a document package is incomplete")
                    }
                } catch {
                    try? fileManager.removeItem(at: stagingURL)
                    throw error
                }
                assetReplacements.append(NotyAssetReplacement(
                    documentID: id,
                    stagedURL: stagingURL,
                    finalURL: localAssetsURL.appendingPathComponent(id.uuidString, isDirectory: true)
                ))
                chosen = remoteDocument
                chosenRemoteReference = reference
                if localDocument == nil || remoteDocument.updatedAt > localDocument!.updatedAt {
                    restoredDocumentIDs.append(id)
                }
            } else if let localDocument {
                chosen = localDocument
                if let remoteDocument,
                   remoteDocument.updatedAt == localDocument.updatedAt,
                   let reference = remotePackages[id],
                   fileManager.fileExists(atPath: packageURL(reference).path) {
                    chosenRemoteReference = reference
                }
            }

            guard var document = chosen else { continue }
            if let folderID = document.folderID, !validFolderIDs.contains(folderID) {
                document.folderID = nil
            }
            mergedDocuments.append(document)
            if let chosenRemoteReference {
                packageReferences[id] = chosenRemoteReference
            }
        }

        let mergedManifest = NotyStoreManifest(
            folders: mergedFolders,
            documents: mergedDocuments,
            deletions: documentTombstones.values.sorted { $0.deletedAt < $1.deletedAt },
            folderDeletions: folderTombstones.values.sorted { $0.deletedAt < $1.deletedAt }
        )
        return MergeResult(
            manifest: mergedManifest,
            assetReplacements: assetReplacements,
            packageReferences: packageReferences,
            restoredDocumentIDs: restoredDocumentIDs,
            note: nil
        )
    }

    private func writeSnapshot(merge: MergeResult) throws {
        let generationID = UUID()
        let createdAt = Date.now
        let snapshotDirectory = snapshotsURL.appendingPathComponent(generationID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        var references: [NotyMirrorPackageReference] = []
        do {
            for document in merge.manifest.documents {
                if let existingReference = merge.packageReferences[document.id],
                   existingReference.updatedAt == document.updatedAt {
                    references.append(existingReference)
                    continue
                }

                let revisionID = UUID()
                let reference = NotyMirrorPackageReference(
                    documentID: document.id,
                    revisionID: revisionID,
                    updatedAt: document.updatedAt
                )
                let source = localAssetsURL.appendingPathComponent(document.id.uuidString, isDirectory: true)
                let destination = packageURL(reference)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyLocalPackage(from: source, to: destination)
                references.append(reference)
            }

            let snapshot = NotyMirrorSnapshot(
                version: 1,
                generationID: generationID,
                createdAt: createdAt,
                manifest: merge.manifest,
                packages: references
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let snapshotData = try encoder.encode(snapshot)
            try writeRemoteData(snapshotData, to: snapshotDirectory.appendingPathComponent("manifest.json"))

            let pointer = NotyMirrorCurrent(version: 1, generationID: generationID, savedAt: createdAt)
            try writeRemoteData(encoder.encode(pointer), to: currentURL)
        } catch {
            try? fileManager.removeItem(at: snapshotDirectory)
            throw error
        }
    }

    private func install(_ replacement: NotyAssetReplacement) throws -> NotyInstalledAsset {
        let backupURL = localMirrorPreviousURL.appendingPathComponent("\(replacement.documentID.uuidString)-\(UUID().uuidString)", isDirectory: true)
        let hasExisting = fileManager.fileExists(atPath: replacement.finalURL.path)
        if hasExisting {
            try fileManager.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: replacement.finalURL, to: backupURL)
        }
        do {
            try fileManager.createDirectory(at: replacement.finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: replacement.stagedURL, to: replacement.finalURL)
        } catch {
            if hasExisting, fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: replacement.finalURL)
            }
            throw error
        }
        return NotyInstalledAsset(finalURL: replacement.finalURL, backupURL: hasExisting ? backupURL : nil, installedNewDirectory: !hasExisting)
    }

    private func packageURL(_ reference: NotyMirrorPackageReference) -> URL {
        packagesURL.appendingPathComponent(reference.documentID.uuidString, isDirectory: true)
            .appendingPathComponent(reference.revisionID.uuidString, isDirectory: true)
    }

    private func isCompletePackage(_ directoryURL: URL, for document: NotyDocument) -> Bool {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return false }
        let hasPDFBackedPage = document.pages.contains { $0.sourcePageIndex != nil }
        if hasPDFBackedPage {
            return fileManager.fileExists(atPath: directoryURL.appendingPathComponent("source.pdf").path)
        }
        return true
    }

    private func copyRemotePackage(from source: URL, to destination: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NotyStoreError.invalidMirrorSnapshot("a document package is unavailable")
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            let target = destination.appendingPathComponent(child.lastPathComponent, isDirectory: (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            let isChildDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isChildDirectory {
                try copyRemotePackage(from: child, to: target)
            } else {
                let data = try coordinatedRead(child)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
        }
    }

    private func copyLocalPackage(from source: URL, to destination: URL) throws {
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            let isChildDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let target = destination.appendingPathComponent(child.lastPathComponent, isDirectory: isChildDirectory)
            if isChildDirectory {
                try copyLocalPackage(from: child, to: target)
            } else {
                try writeRemoteData(Data(contentsOf: child, options: .mappedIfSafe), to: target)
            }
        }
    }

    private func coordinatedRead(_ url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var readError: Error?
        var result: Data?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            do {
                result = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return result
    }

    private func writeRemoteData(_ data: Data, to destinationURL: URL) throws {
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: destinationURL, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        guard fileManager.fileExists(atPath: destinationURL.path) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func newestByID<Record: Identifiable>(
        _ records: [Record],
        date: (Record) -> Date
    ) -> [UUID: Record] where Record.ID == UUID {
        var result: [UUID: Record] = [:]
        for record in records {
            guard let existing = result[record.id] else {
                result[record.id] = record
                continue
            }
            if date(record) > date(existing) {
                result[record.id] = record
            }
        }
        return result
    }

    private func orderedIDs(_ first: [UUID], _ second: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return (first + second).filter { seen.insert($0).inserted }
    }

    private static func fingerprint(_ manifest: NotyStoreManifest) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(manifest)) ?? Data()
    }
}

import Foundation
import CryptoKit
import UniformTypeIdentifiers
import Observation

@MainActor
@Observable
final class NotyCloudSyncService {
    private(set) var isSyncing = false
    private(set) var syncStatus = "Sign in to use Noty Cloud."
    private(set) var lastError: String?

    @ObservationIgnored private var syncRequestedAgain = false
    @ObservationIgnored private var checkpoints: [UUID: CloudCheckpoint] = [:]
    @ObservationIgnored private let fileManager = FileManager.default

    func sync(store: NotyStore, account: NotyAccountService) async {
        guard account.isAuthenticated else {
            syncStatus = "Sign in to use Noty Cloud."
            lastError = nil
            return
        }

        if isSyncing {
            syncRequestedAgain = true
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        repeat {
            syncRequestedAgain = false
            do {
                try await performSync(store: store, account: account)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                syncStatus = "Noty Cloud sync needs attention."
            }
        } while syncRequestedAgain && !Task.isCancelled
    }

    private func performSync(store: NotyStore, account: NotyAccountService) async throws {
        guard let userID = account.accountUserID else { throw NotyCloudError.notSignedIn }
        syncStatus = "Checking Noty Cloud…"

        async let folderData = account.backendData(
            path: "/rest/v1/noty_web_folders?select=user_id,id,name,parent_id,color,payload,updated_at",
            method: "GET"
        )
        async let documentData = account.backendData(
            path: "/rest/v1/noty_web_documents?select=user_id,id,title,kind,folder_id,payload,starred,trashed_at,created_at,updated_at,revision",
            method: "GET"
        )
        async let assetData = account.backendData(
            path: "/rest/v1/noty_cloud_assets?select=user_id,document_id,relative_path,object_key,sha256,byte_size,content_type,updated_at",
            method: "GET"
        )
        async let tombstoneData = account.backendData(
            path: "/rest/v1/noty_cloud_tombstones?select=user_id,entity_type,entity_id,deleted_at",
            method: "GET"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let remoteFolders = try decoder.decode([CloudFolderRow].self, from: try await folderData)
        let remoteDocuments = try decoder.decode([CloudDocumentRow].self, from: try await documentData)
        let assetRows = try decoder.decode([CloudAssetRow].self, from: try await assetData)
        // A document revision points at immutable file versions. The mutable asset
        // index is only a fallback for older clients and unfinished transfers.
        let remoteAssets = remoteDocuments.flatMap { row -> [CloudAssetRow] in
            guard let manifest = row.payload.assetManifest, !manifest.isEmpty else { return assetRows.filter { $0.document_id == row.id } }
            return manifest.map { path, ref in CloudAssetRow(document_id: row.id, relative_path: path, object_key: ref.object_key, sha256: ref.sha256, byte_size: ref.byte_size, content_type: ref.content_type, updated_at: row.updated_at) }
        }
        let remoteTombstones = try decoder.decode([CloudTombstoneRow].self, from: try await tombstoneData)

        let checkpointURL = store.storageDirectoryURL.appendingPathComponent("cloud-checkpoints-\(userID).json")
        checkpoints = (try? JSONDecoder().decode([UUID: CloudCheckpoint].self, from: Data(contentsOf: checkpointURL))) ?? [:]
        let startingLocalRevision = store.localRevision
        let local = store.currentManifest()
        var folders = Dictionary(uniqueKeysWithValues: local.folders.map { ($0.id, $0) })
        var documents = Dictionary(uniqueKeysWithValues: local.documents.map { ($0.id, $0) })
        var documentDeletions = Dictionary(uniqueKeysWithValues: local.deletions.map { ($0.id, $0.deletedAt) })
        var folderDeletions = Dictionary(uniqueKeysWithValues: local.folderDeletions.map { ($0.id, $0.deletedAt) })

        let remoteFolderMap = Dictionary(uniqueKeysWithValues: remoteFolders.map { ($0.id, $0) })
        let remoteDocumentMap = Dictionary(uniqueKeysWithValues: remoteDocuments.map { ($0.id, $0) })
        var remoteDocumentDeletions: [UUID: Date] = [:]
        var remoteFolderDeletions: [UUID: Date] = [:]

        for tombstone in remoteTombstones {
            guard let deletedAt = Self.parseDate(tombstone.deleted_at) else { continue }
            if tombstone.entity_type == "document" {
                remoteDocumentDeletions[tombstone.entity_id] = max(remoteDocumentDeletions[tombstone.entity_id] ?? .distantPast, deletedAt)
            } else if tombstone.entity_type == "folder" {
                remoteFolderDeletions[tombstone.entity_id] = max(remoteFolderDeletions[tombstone.entity_id] ?? .distantPast, deletedAt)
            }
        }
        for row in remoteDocuments {
            if let trashedAtRaw = row.trashed_at, let trashedAt = Self.parseDate(trashedAtRaw) {
                remoteDocumentDeletions[row.id] = max(remoteDocumentDeletions[row.id] ?? .distantPast, trashedAt)
            }
        }

        var purgedDocuments = Set<UUID>()
        var localAuthoritativeDocuments = Set<UUID>()
        var remoteAuthoritativeDocuments = Set<UUID>()
        var localAuthoritativeFolders = Set<UUID>()

        // Remote deletions win unless this device has a strictly newer active edit.
        for (id, deletedAt) in remoteDocumentDeletions {
            if let localDocument = documents[id], localDocument.updatedAt > deletedAt {
                documentDeletions[id] = nil
                localAuthoritativeDocuments.insert(id)
                try await deleteTombstone(entityType: "document", id: id, account: account)
            } else {
                documents[id] = nil
                documentDeletions[id] = max(documentDeletions[id] ?? .distantPast, deletedAt)
            }
        }
        for (id, deletedAt) in remoteFolderDeletions {
            let localUpdatedAt = folders[id]?.updatedAt ?? .distantPast
            if folders[id] != nil, localUpdatedAt > deletedAt {
                folderDeletions[id] = nil
                localAuthoritativeFolders.insert(id)
                try await deleteTombstone(entityType: "folder", id: id, account: account)
            } else {
                folders[id] = nil
                folderDeletions[id] = max(folderDeletions[id] ?? .distantPast, deletedAt)
            }
        }

        // Merge live folders using last-write-wins timestamps.
        for row in remoteFolders {
            guard let remoteUpdatedAt = Self.parseDate(row.updated_at) else { continue }
            if let deletion = folderDeletions[row.id], deletion >= remoteUpdatedAt {
                continue
            }
            let remoteFolder = row.toFolder(updatedAt: remoteUpdatedAt)
            if let localFolder = folders[row.id] {
                let localUpdatedAt = localFolder.updatedAt ?? .distantPast
                if remoteUpdatedAt > localUpdatedAt {
                    folders[row.id] = remoteFolder
                } else if localUpdatedAt > remoteUpdatedAt {
                    localAuthoritativeFolders.insert(row.id)
                }
            } else {
                folders[row.id] = remoteFolder
            }
            folderDeletions[row.id] = nil
        }

        // A known baseline makes simultaneous and offline edits distinguishable.
        // Preserve a divergent local notebook, including every binary file, before accepting remote metadata.
        for row in remoteDocuments where row.trashed_at == nil {
            guard let original = documents[row.id],
                  let remoteDate = Self.parseDate(row.updated_at),
                  let createdDate = Self.parseDate(row.created_at),
                  let remote = row.toDocument(createdAt: createdDate, updatedAt: remoteDate) else { continue }
            var comparable = original
            comparable.updatedAt = remote.updatedAt
            comparable.createdAt = remote.createdAt
            let baseline = checkpoints[row.id]
            let localChanged = baseline.map { original.updatedAt != $0.localUpdatedAt } ?? (comparable != remote)
            let remoteChanged = baseline.map { row.revision != $0.revision } ?? (comparable != remote)
            if localChanged && remoteChanged && comparable != remote {
                var copy = original
                copy.id = UUID()
                copy.title = String(original.title.prefix(270)) + " (iPad conflict copy)"
                copy.createdAt = Date()
                copy.updatedAt = copy.createdAt
                let source = store.assetDirectoryURL(documentID: original.id)
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.copyItem(at: source, to: store.assetDirectoryURL(documentID: copy.id))
                }
                documents[copy.id] = copy
                localAuthoritativeDocuments.insert(copy.id)
                documents[row.id] = remote
                remoteAuthoritativeDocuments.insert(row.id)
                localAuthoritativeDocuments.remove(row.id)
            } else if let baseline, !localChanged && row.revision != baseline.revision {
                documents[row.id] = remote
                remoteAuthoritativeDocuments.insert(row.id)
            }
        }

        // Merge live documents using last-write-wins timestamps.
        for row in remoteDocuments where row.trashed_at == nil {
            guard let remoteUpdatedAt = Self.parseDate(row.updated_at),
                  let remoteCreatedAt = Self.parseDate(row.created_at),
                  let remoteDocument = row.toDocument(createdAt: remoteCreatedAt, updatedAt: remoteUpdatedAt) else { continue }
            if let deletion = documentDeletions[row.id] {
                if deletion >= remoteUpdatedAt {
                    continue
                }
                documentDeletions[row.id] = nil
            }
            if let localDocument = documents[row.id] {
                if remoteUpdatedAt > localDocument.updatedAt {
                    documents[row.id] = remoteDocument
                    remoteAuthoritativeDocuments.insert(row.id)
                    localAuthoritativeDocuments.remove(row.id)
                } else if localDocument.updatedAt > remoteUpdatedAt {
                    localAuthoritativeDocuments.insert(row.id)
                }
            } else {
                documents[row.id] = remoteDocument
                remoteAuthoritativeDocuments.insert(row.id)
            }
        }

        // Local-only live entities need to be uploaded.
        for folder in local.folders where remoteFolderMap[folder.id] == nil && folderDeletions[folder.id] == nil {
            if folders[folder.id] != nil { localAuthoritativeFolders.insert(folder.id) }
        }
        for document in local.documents where remoteDocumentMap[document.id] == nil && documentDeletions[document.id] == nil {
            if documents[document.id] != nil { localAuthoritativeDocuments.insert(document.id) }
        }

        // A local tombstone can beat an older remote live row.
        for (id, deletedAt) in Array(documentDeletions) {
            if let row = remoteDocumentMap[id], row.trashed_at == nil, let remoteUpdatedAt = Self.parseDate(row.updated_at), remoteUpdatedAt > deletedAt {
                documentDeletions[id] = nil
                if let remoteCreatedAt = Self.parseDate(row.created_at),
                   let remoteDocument = row.toDocument(createdAt: remoteCreatedAt, updatedAt: remoteUpdatedAt) {
                    documents[id] = remoteDocument
                    remoteAuthoritativeDocuments.insert(id)
                }
            }
        }
        for (id, deletedAt) in Array(folderDeletions) {
            if let row = remoteFolderMap[id], let remoteUpdatedAt = Self.parseDate(row.updated_at), remoteUpdatedAt > deletedAt {
                folderDeletions[id] = nil
                folders[id] = row.toFolder(updatedAt: remoteUpdatedAt)
            }
        }

        // Normalize broken parent references created by a deleted/moved folder.
        let now = Date()
        let folderIDs = Set(folders.keys)
        for id in Array(folders.keys) {
            guard var folder = folders[id] else { continue }
            if let parentID = folder.parentID, !folderIDs.contains(parentID) {
                folder.parentID = nil
                folder.updatedAt = max(folder.updatedAt ?? .distantPast, now)
                folders[id] = folder
                localAuthoritativeFolders.insert(id)
            } else if folder.updatedAt == nil {
                folder.updatedAt = now
                folders[id] = folder
                localAuthoritativeFolders.insert(id)
            }
        }
        for id in Array(documents.keys) {
            guard var document = documents[id] else { continue }
            if let folderID = document.folderID, !folderIDs.contains(folderID) {
                document.folderID = nil
                document.updatedAt = max(document.updatedAt, now)
                documents[id] = document
                localAuthoritativeDocuments.insert(id)
                remoteAuthoritativeDocuments.remove(id)
            }
        }

        // Push/clear tombstones before live rows, so restores are explicit.
        for (id, deletedAt) in documentDeletions {
            if let item = store.trashItems.first(where: { $0.id == id }), remoteDocumentDeletions[id] == nil {
                // Trashing is reversible on every device; never purge B2 files here.
                try store.stageCloudTrashAssets(id: id)
                _ = try await syncAssets(document: item.document, remoteAssets: remoteAssets.filter { $0.document_id == id }, authority: .local, store: store, userID: userID, account: account)
                try await upsert(document: item.document, existing: remoteDocumentMap[id], userID: userID, account: account, trashedAt: deletedAt)
            } else if remoteDocumentMap[id]?.trashed_at != nil {
                if store.trashItems.contains(where: { $0.id == id }) { continue }
                if let row = remoteDocumentMap[id], let changed = Self.parseDate(row.updated_at), deletedAt > changed {
                    try await upsertTombstone(entityType: "document", id: id, deletedAt: deletedAt, userID: userID, account: account)
                    try await deleteRemoteDocument(id: id, account: account)
                    try await deleteRemoteDocumentAssets(documentID: id, account: account)
                    purgedDocuments.insert(id)
                }
                continue
            } else {
                try await upsertTombstone(entityType: "document", id: id, deletedAt: deletedAt, userID: userID, account: account)
                if let row = remoteDocumentMap[id], let updatedAt = Self.parseDate(row.updated_at), updatedAt <= deletedAt {
                    try await deleteRemoteDocument(id: id, account: account)
                }
            }
        }
        for (id, deletedAt) in folderDeletions {
            try await upsertTombstone(entityType: "folder", id: id, deletedAt: deletedAt, userID: userID, account: account)
            if let row = remoteFolderMap[id], let updatedAt = Self.parseDate(row.updated_at), updatedAt <= deletedAt {
                try await deleteRemoteFolder(id: id, account: account)
            }
        }

        for id in localAuthoritativeFolders {
            guard let folder = folders[id] else { continue }
            try await deleteTombstone(entityType: "folder", id: id, account: account)
            try await upsert(folder: folder, existing: remoteFolderMap[id], userID: userID, account: account)
        }
        for id in localAuthoritativeDocuments {
            guard let document = documents[id] else { continue }
            try await deleteTombstone(entityType: "document", id: id, account: account)
            // Upload binaries before publishing page metadata that references them.
            try store.refreshCloudInkPreviews(documentID: id)
            _ = try await syncAssets(document: document, remoteAssets: remoteAssets.filter { $0.document_id == id }, authority: .local, store: store, userID: userID, account: account)
            try await upsert(document: document, existing: remoteDocumentMap[id], userID: userID, account: account)
            if let checkpoint = checkpoints[id], var updated = documents[id] {
                updated.updatedAt = checkpoint.localUpdatedAt
                documents[id] = updated
            }
        }

        // A user edit while requests were in flight must never be overwritten by this snapshot.
        guard store.localRevision == startingLocalRevision else {
            syncRequestedAgain = true
            return
        }
        // Persist the merged metadata locally before transferring assets.
        let mergedManifest = NotyStoreManifest(
            folders: folders.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            documents: documents.values.sorted { left, right in
                if left.createdAt == right.createdAt { return left.id.uuidString < right.id.uuidString }
                return left.createdAt < right.createdAt
            },
            deletions: documentDeletions.map { NotyDeletionRecord(id: $0.key, deletedAt: $0.value) },
            folderDeletions: folderDeletions.map { NotyFolderDeletionRecord(id: $0.key, deletedAt: $0.value) }
        )
        guard store.applyCloudManifest(mergedManifest) else { throw NotyCloudError.localPersistence }

        // Remove cloud assets for deleted documents once the metadata tombstone is durable.
        var remainingRemoteAssets = remoteAssets
        for documentID in documentDeletions.keys where remoteTombstones.contains(where: { $0.entity_type == "document" && $0.entity_id == documentID }) && remainingRemoteAssets.contains(where: { $0.document_id == documentID }) {
            try await deleteRemoteDocumentAssets(documentID: documentID, account: account)
            remainingRemoteAssets.removeAll { $0.document_id == documentID }
        }

        var uploaded = 0
        var downloaded = 0
        var deleted = 0
        let remoteAssetsByDocument = Dictionary(grouping: remainingRemoteAssets, by: \.document_id)

        for document in store.documents {
            if Task.isCancelled { throw CancellationError() }
            let mode: AssetAuthority
            if remoteAuthoritativeDocuments.contains(document.id) {
                mode = .remote
            } else if localAuthoritativeDocuments.contains(document.id) {
                mode = .local
            } else {
                mode = .merge
            }
            let result = try await syncAssets(
                document: document,
                remoteAssets: remoteAssetsByDocument[document.id] ?? [],
                authority: mode,
                store: store,
                userID: userID,
                account: account
            )
            uploaded += result.uploaded
            downloaded += result.downloaded
            deleted += result.deleted
        }

        // Download remotely trashed notebooks into a recoverable package as well.
        for row in remoteDocuments where !purgedDocuments.contains(row.id) {
            guard let raw = row.trashed_at, let deletedAt = Self.parseDate(raw),
                  let createdAt = Self.parseDate(row.created_at), let updatedAt = Self.parseDate(row.updated_at),
                  let document = row.toDocument(createdAt: createdAt, updatedAt: updatedAt) else { continue }
            if !store.trashItems.contains(where: { $0.id == row.id && $0.deletedAt >= deletedAt }) {
                for asset in remoteAssets where asset.document_id == row.id {
                    try await download(remote: asset, documentID: row.id, store: store, account: account)
                }
                try store.retainCloudTrash(document: document, deletedAt: deletedAt)
            }
        }
        for row in remoteDocuments where !localAuthoritativeDocuments.contains(row.id) {
            if let localDocument = store.documents.first(where: { $0.id == row.id }) {
                checkpoints[row.id] = CloudCheckpoint(revision: row.revision, localUpdatedAt: localDocument.updatedAt)
            }
        }
        try JSONEncoder().encode(checkpoints).write(to: checkpointURL, options: .atomic)
        store.ensureHandwritingSearchIndex()
        syncStatus = "Noty Cloud synced · \(store.documents.count) document\(store.documents.count == 1 ? "" : "s") · \(uploaded) uploaded, \(downloaded) downloaded\(deleted > 0 ? ", \(deleted) removed" : "")."
    }

    private func syncAssets(
        document: NotyDocument,
        remoteAssets: [CloudAssetRow],
        authority: AssetAuthority,
        store: NotyStore,
        userID: String,
        account: NotyAccountService
    ) async throws -> (uploaded: Int, downloaded: Int, deleted: Int) {
        let localAssets = try await localAssets(documentID: document.id, store: store)
        let localMap = Dictionary(uniqueKeysWithValues: localAssets.map { ($0.relativePath, $0) })
        let remoteMap = Dictionary(uniqueKeysWithValues: remoteAssets.compactMap { row -> (String, CloudAssetRow)? in
            guard Self.safeRelativePath(row.relative_path) != nil else { return nil }
            return (row.relative_path, row)
        })
        let allPaths = Set(localMap.keys).union(remoteMap.keys)
        var uploaded = 0
        var downloaded = 0
        var deleted = 0

        for path in allPaths.sorted() {
            if Task.isCancelled { throw CancellationError() }
            let localAsset = localMap[path]
            let remoteAsset = remoteMap[path]

            switch (localAsset, remoteAsset) {
            case let (.some(local), .some(remote)):
                if local.sha256 == remote.sha256 && remote.object_key.contains("/versions/\(local.sha256)/") { continue }
                if authority == .remote {
                    try await download(remote: remote, documentID: document.id, store: store, account: account)
                    downloaded += 1
                } else if authority == .local {
                    try await upload(local: local, documentID: document.id, userID: userID, account: account)
                    uploaded += 1
                } else if local.modifiedAt > (Self.parseDate(remote.updated_at) ?? .distantPast) {
                    try await upload(local: local, documentID: document.id, userID: userID, account: account)
                    uploaded += 1
                } else {
                    try await download(remote: remote, documentID: document.id, store: store, account: account)
                    downloaded += 1
                }

            case let (.some(local), .none):
                if authority == .remote {
                    // Keep unreferenced local bytes until explicit deletion; interrupted uploads can be retried.
                    continue
                } else {
                    try await upload(local: local, documentID: document.id, userID: userID, account: account)
                    uploaded += 1
                }

            case let (.none, .some(remote)):
                try await download(remote: remote, documentID: document.id, store: store, account: account)
                downloaded += 1

            case (.none, .none):
                break
            }
        }

        return (uploaded, downloaded, deleted)
    }

    private func localAssets(documentID: UUID, store: NotyStore) async throws -> [LocalAsset] {
        let root = store.assetDirectoryURL(documentID: documentID)
        let candidates = try Self.localAssetCandidates(root: root)

        var result: [LocalAsset] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates {
            let digest = try await Task.detached(priority: .utility) {
                try Self.sha256(fileURL: candidate.url)
            }.value
            let contentType = UTType(filenameExtension: candidate.url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            result.append(LocalAsset(
                relativePath: candidate.relativePath,
                url: candidate.url,
                sha256: digest,
                byteSize: candidate.byteSize,
                contentType: contentType,
                modifiedAt: candidate.modifiedAt
            ))
        }
        return result
    }

    nonisolated private static func localAssetCandidates(root: URL) throws -> [LocalAssetCandidate] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [LocalAssetCandidate] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            guard safeRelativePath(relativePath) != nil,
                  !relativePath.hasPrefix("Handwriting/") else { continue }
            candidates.append(LocalAssetCandidate(
                relativePath: relativePath,
                url: url,
                byteSize: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        return candidates
    }

    private func upload(local: LocalAsset, documentID: UUID, userID: String, account: NotyAccountService) async throws {
        // Upload a stable file snapshot even if PencilKit replaces the original while awaiting the network.
        let snapshot = fileManager.temporaryDirectory.appendingPathComponent("noty-upload-\(UUID().uuidString)")
        try fileManager.copyItem(at: local.url, to: snapshot)
        defer { try? fileManager.removeItem(at: snapshot) }
        let digest = try await Task.detached(priority: .utility) { try Self.sha256(fileURL: snapshot) }.value
        guard digest == local.sha256 else {
            throw NotyCloudError.transfer("This file changed while preparing its upload. The local edit is retained; sync again.")
        }
        let signed = try await signedURL(
            action: "presign_upload",
            documentID: documentID,
            relativePath: local.relativePath,
            contentType: local.contentType,
            sha256: local.sha256,
            account: account
        )
        guard let url = URL(string: signed.url) else { throw NotyCloudError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 180
        request.setValue(local.contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: snapshot)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NotyCloudError.transfer("Upload failed for \(local.relativePath).")
        }

        let body: [String: Any] = [
            "user_id": userID,
            "document_id": documentID.uuidString.lowercased(),
            "relative_path": local.relativePath,
            "object_key": signed.objectKey,
            "sha256": local.sha256,
            "byte_size": local.byteSize,
            "content_type": local.contentType,
            "updated_at": Self.formatDate(.now)
        ]
        _ = try await account.backendData(
            path: "/rest/v1/noty_cloud_assets?on_conflict=user_id,document_id,relative_path",
            method: "POST",
            jsonBody: body,
            prefer: "resolution=merge-duplicates,return=minimal"
        )
    }

    private func download(remote: CloudAssetRow, documentID: UUID, store: NotyStore, account: NotyAccountService) async throws {
        let revisionAtStart = store.localRevision
        guard let relativePath = Self.safeRelativePath(remote.relative_path) else { throw NotyCloudError.invalidResponse }
        let signed = try await signedURL(
            action: "presign_download",
            documentID: documentID,
            relativePath: relativePath,
            contentType: nil,
            objectKey: remote.object_key,
            account: account
        )
        guard let url = URL(string: signed.url) else { throw NotyCloudError.invalidResponse }
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NotyCloudError.transfer("Download failed for \(relativePath).")
        }
        let digest = try await Task.detached(priority: .utility) {
            try Self.sha256(fileURL: temporaryURL)
        }.value
        guard digest == remote.sha256 else { throw NotyCloudError.transfer("Cloud file verification failed for \(relativePath).") }

        guard store.localRevision == revisionAtStart else {
            throw NotyCloudError.transfer("A local edit arrived while downloading. It was preserved; sync again to reconcile it.")
        }
        let destination = store.assetDirectoryURL(documentID: documentID).appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporaryURL, to: destination)
    }

    private func delete(remote: CloudAssetRow, documentID: UUID, account: NotyAccountService) async throws {
        guard let relativePath = Self.safeRelativePath(remote.relative_path) else { return }
        _ = try await account.backendData(
            path: "/functions/v1/noty-cloud-object",
            method: "POST",
            jsonBody: [
                "action": "delete_object",
                "documentID": documentID.uuidString.lowercased(),
                "relativePath": relativePath
            ]
        )
        let encodedPath = Self.queryValue(relativePath)
        _ = try await account.backendData(
            path: "/rest/v1/noty_cloud_assets?document_id=eq.\(documentID.uuidString.lowercased())&relative_path=eq.\(encodedPath)",
            method: "DELETE"
        )
    }

    private func signedURL(
        action: String,
        documentID: UUID,
        relativePath: String,
        contentType: String?,
        sha256: String? = nil,
        objectKey: String? = nil,
        account: NotyAccountService
    ) async throws -> SignedURLResponse {
        var body: [String: Any] = [
            "action": action,
            "documentID": documentID.uuidString.lowercased(),
            "relativePath": relativePath
        ]
        if let contentType { body["contentType"] = contentType }
        if let sha256 { body["sha256"] = sha256 }
        if let objectKey { body["objectKey"] = objectKey }
        let data = try await account.backendData(
            path: "/functions/v1/noty-cloud-object",
            method: "POST",
            jsonBody: body
        )
        return try JSONDecoder().decode(SignedURLResponse.self, from: data)
    }

    private func upsert(folder: NotyFolder, existing: CloudFolderRow?, userID: String, account: NotyAccountService) async throws {
        let payload = CloudFolderPayload(design: folder.design, symbol: folder.symbol, imageData: folder.imageData)
        let body: [String: Any] = [
            "user_id": userID,
            "id": folder.id.uuidString.lowercased(),
            "name": folder.name,
            "parent_id": folder.parentID?.uuidString.lowercased() ?? NSNull(),
            "color": "#\((folder.design?.colorHex ?? existing?.color.trimmingCharacters(in: CharacterSet(charactersIn: "#")) ?? "294fe3"))",
            "payload": try Self.jsonObject(payload),
            "updated_at": Self.formatDate(folder.updatedAt ?? .now)
        ]
        let data: Data
        if let existing {
            data = try await account.backendData(path: "/rest/v1/noty_web_folders?id=eq.\(folder.id.uuidString.lowercased())&updated_at=eq.\(Self.queryValue(existing.updated_at))", method: "PATCH", jsonBody: body, prefer: "return=representation")
        } else {
            data = try await account.backendData(path: "/rest/v1/noty_web_folders", method: "POST", jsonBody: body, prefer: "return=representation")
        }
        guard !((try? JSONSerialization.jsonObject(with: data) as? [Any]) ?? []).isEmpty else {
            throw NotyCloudError.transfer("This folder changed during sync. Retry to receive its newer version.")
        }
    }

    private func upsert(document: NotyDocument, existing: CloudDocumentRow?, userID: String, account: NotyAccountService, trashedAt: Date? = nil) async throws {
        var payload = CloudDocumentPayload(
            pages: document.pages,
            cover: document.cover,
            studyCards: document.studyCards,
            audioClips: document.audioClips
        )
        var assetManifest = existing?.payload.assetManifest ?? [:]
        for asset in try await localAssets(documentID: document.id, store: store) {
            assetManifest[asset.relativePath] = CloudAssetReference(object_key: "users/\(userID)/documents/\(document.id.uuidString.lowercased())/versions/\(asset.sha256)/\(asset.relativePath)", sha256: asset.sha256, byte_size: asset.byteSize, content_type: asset.contentType)
        }
        payload.assetManifest = assetManifest
        let body: [String: Any] = [
            "user_id": userID,
            "id": document.id.uuidString.lowercased(),
            "title": document.title,
            "kind": document.kind.rawValue,
            "folder_id": document.folderID?.uuidString.lowercased() ?? NSNull(),
            "payload": try Self.jsonObject(payload),
            "starred": existing?.starred ?? false,
            "trashed_at": trashedAt.map(Self.formatDate) as Any? ?? NSNull(),
            "created_at": Self.formatDate(document.createdAt),
            "updated_at": Self.formatDate(document.updatedAt),
            "revision": max((existing?.revision ?? 0) + 1, 1)
        ]
        let data: Data
        if let existing {
            data = try await account.backendData(
                path: "/rest/v1/noty_web_documents?id=eq.\(document.id.uuidString.lowercased())&revision=eq.\(existing.revision)",
                method: "PATCH", jsonBody: body, prefer: "return=representation"
            )
        } else {
            data = try await account.backendData(path: "/rest/v1/noty_web_documents", method: "POST", jsonBody: body, prefer: "return=representation")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let rows = try decoder.decode([CloudDocumentRow].self, from: data)
        guard let row = rows.first, let serverDate = Self.parseDate(row.updated_at) else {
            throw NotyCloudError.transfer("This notebook changed during sync. The local copy is retained; sync again to resolve it.")
        }
        checkpoints[document.id] = CloudCheckpoint(revision: row.revision, localUpdatedAt: serverDate)
    }

    private func upsertTombstone(entityType: String, id: UUID, deletedAt: Date, userID: String, account: NotyAccountService) async throws {
        let body: [String: Any] = [
            "user_id": userID,
            "entity_type": entityType,
            "entity_id": id.uuidString.lowercased(),
            "deleted_at": Self.formatDate(deletedAt)
        ]
        _ = try await account.backendData(
            path: "/rest/v1/noty_cloud_tombstones?on_conflict=user_id,entity_type,entity_id",
            method: "POST",
            jsonBody: body,
            prefer: "resolution=merge-duplicates,return=minimal"
        )
    }

    private func deleteTombstone(entityType: String, id: UUID, account: NotyAccountService) async throws {
        _ = try await account.backendData(
            path: "/rest/v1/noty_cloud_tombstones?entity_type=eq.\(entityType)&entity_id=eq.\(id.uuidString.lowercased())",
            method: "DELETE"
        )
    }

    private func deleteRemoteDocument(id: UUID, account: NotyAccountService) async throws {
        _ = try await account.backendData(
            path: "/rest/v1/noty_web_documents?id=eq.\(id.uuidString.lowercased())",
            method: "DELETE"
        )
    }

    private func deleteRemoteFolder(id: UUID, account: NotyAccountService) async throws {
        _ = try await account.backendData(
            path: "/rest/v1/noty_web_folders?id=eq.\(id.uuidString.lowercased())",
            method: "DELETE"
        )
    }

    private func deleteRemoteDocumentAssets(documentID: UUID, account: NotyAccountService) async throws {
        _ = try await account.backendData(
            path: "/functions/v1/noty-cloud-object",
            method: "POST",
            jsonBody: [
                "action": "delete_document",
                "documentID": documentID.uuidString.lowercased()
            ]
        )
        _ = try await account.backendData(
            path: "/rest/v1/noty_cloud_assets?document_id=eq.\(documentID.uuidString.lowercased())",
            method: "DELETE"
        )
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated private static func safeRelativePath(_ raw: String) -> String? {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              path.count <= 900,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts.joined(separator: "/")
    }

    private static func queryValue(_ raw: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+#")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    nonisolated private static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private enum AssetAuthority {
    case local
    case remote
    case merge
}

private struct LocalAsset {
    let relativePath: String
    let url: URL
    let sha256: String
    let byteSize: Int64
    let contentType: String
    let modifiedAt: Date
}

private struct LocalAssetCandidate {
    let relativePath: String
    let url: URL
    let byteSize: Int64
    let modifiedAt: Date
}

private struct SignedURLResponse: Decodable {
    let url: String
    let objectKey: String
    let expiresIn: Int
}

private struct CloudFolderPayload: Codable {
    var design: NotyNotebookCover?
    var symbol: String?
    var imageData: Data?

    init(design: NotyNotebookCover? = nil, symbol: String? = nil, imageData: Data? = nil) {
        self.design = design
        self.symbol = symbol
        self.imageData = imageData
    }
}

private struct CloudDocumentPayload: Codable {
    var pages: [NotyPage]
    var cover: NotyNotebookCover?
    var studyCards: [NotyStudyCard]?
    var audioClips: [NotyAudioClip]?
    var assetManifest: [String: CloudAssetReference]?

    init(
        pages: [NotyPage] = [NotyPage()],
        cover: NotyNotebookCover? = nil,
        studyCards: [NotyStudyCard]? = nil,
        audioClips: [NotyAudioClip]? = nil
    ) {
        self.pages = pages
        self.cover = cover
        self.studyCards = studyCards
        self.audioClips = audioClips
    }

    private enum CodingKeys: String, CodingKey {
        case pages, cover, studyCards, audioClips, assetManifest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pages = try container.decodeIfPresent([NotyPage].self, forKey: .pages) ?? [NotyPage()]
        cover = try container.decodeIfPresent(NotyNotebookCover.self, forKey: .cover)
        studyCards = try container.decodeIfPresent([NotyStudyCard].self, forKey: .studyCards)
        audioClips = try container.decodeIfPresent([NotyAudioClip].self, forKey: .audioClips)
        assetManifest = try container.decodeIfPresent([String: CloudAssetReference].self, forKey: .assetManifest)
    }
}

private struct CloudFolderRow: Decodable {
    let id: UUID
    let name: String
    let parent_id: UUID?
    let color: String
    let payload: CloudFolderPayload
    let updated_at: String

    func toFolder(updatedAt: Date) -> NotyFolder {
        let fallbackHex = color.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        let design = payload.design ?? NotyNotebookCover(style: .minimal, colorHex: fallbackHex.isEmpty ? "294FE3" : fallbackHex)
        return NotyFolder(
            id: id,
            name: name,
            parentID: parent_id,
            design: design,
            symbol: payload.symbol,
            imageData: payload.imageData,
            updatedAt: updatedAt
        )
    }
}

private struct CloudDocumentRow: Decodable {
    let id: UUID
    let title: String
    let kind: String
    let folder_id: UUID?
    let payload: CloudDocumentPayload
    let starred: Bool
    let trashed_at: String?
    let created_at: String
    let updated_at: String
    let revision: Int64

    func toDocument(createdAt: Date, updatedAt: Date) -> NotyDocument? {
        guard let documentKind = NotyDocumentKind(rawValue: kind) else { return nil }
        return NotyDocument(
            id: id,
            title: title,
            kind: documentKind,
            folderID: folder_id,
            pages: payload.pages.isEmpty ? [NotyPage()] : payload.pages,
            createdAt: createdAt,
            updatedAt: updatedAt,
            cover: payload.cover,
            studyCards: payload.studyCards,
            audioClips: payload.audioClips
        )
    }
}

private struct CloudAssetRow: Decodable {
    let document_id: UUID
    let relative_path: String
    let object_key: String
    let sha256: String
    let byte_size: Int64
    let content_type: String
    let updated_at: String
}

private struct CloudTombstoneRow: Decodable {
    let entity_type: String
    let entity_id: UUID
    let deleted_at: String
}

private enum NotyCloudError: LocalizedError {
    case notSignedIn
    case invalidResponse
    case localPersistence
    case transfer(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to your Noty account first."
        case .invalidResponse:
            return "Noty Cloud returned an invalid response."
        case .localPersistence:
            return "Noty Cloud merged changes, but the local library could not be saved."
        case .transfer(let message):
            return message
        }
    }
}

private struct CloudCheckpoint: Codable { let revision: Int64; let localUpdatedAt: Date }

private struct CloudAssetReference: Codable { let object_key: String; let sha256: String; let byte_size: Int64; let content_type: String }

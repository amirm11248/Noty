import Foundation
import Observation
import PDFKit
import PencilKit
import UniformTypeIdentifiers
import UIKit

struct NotyDeletionRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var deletedAt: Date
}

struct NotyFolderDeletionRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var deletedAt: Date
}

struct NotyStoreManifest: Codable {
    var version: Int
    var folders: [NotyFolder]
    var documents: [NotyDocument]
    var deletions: [NotyDeletionRecord]
    var folderDeletions: [NotyFolderDeletionRecord]

    init(
        version: Int = 1,
        folders: [NotyFolder] = [],
        documents: [NotyDocument] = [],
        deletions: [NotyDeletionRecord] = [],
        folderDeletions: [NotyFolderDeletionRecord] = []
    ) {
        self.version = version
        self.folders = folders
        self.documents = documents
        self.deletions = deletions
        self.folderDeletions = folderDeletions
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case folders
        case documents
        case deletions
        case folderDeletions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        folders = try container.decodeIfPresent([NotyFolder].self, forKey: .folders) ?? []
        documents = try container.decodeIfPresent([NotyDocument].self, forKey: .documents) ?? []
        deletions = try container.decodeIfPresent([NotyDeletionRecord].self, forKey: .deletions) ?? []
        folderDeletions = try container.decodeIfPresent([NotyFolderDeletionRecord].self, forKey: .folderDeletions) ?? []
    }
}

@MainActor
@Observable
final class NotyStore {
    private(set) var folders: [NotyFolder] = []
    private(set) var documents: [NotyDocument] = []
    private(set) var syncStatus = "iCloud Drive backup not configured"
    private(set) var iCloudMirrorFolderURL: URL?
    private(set) var isSyncingICloudMirror = false
    private(set) var lastPersistenceError: String?
    private(set) var lastOperationMessage: String?
    private(set) var trashItems: [NotyTrashedDocument] = []

    @ObservationIgnored let storageDirectoryURL: URL
    @ObservationIgnored let fileManager = FileManager.default
    @ObservationIgnored var deletionRecords: [NotyDeletionRecord] = []
    @ObservationIgnored var folderDeletionRecords: [NotyFolderDeletionRecord] = []
    @ObservationIgnored var localRevision: UInt64 = 0
    @ObservationIgnored var mirrorDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var handwritingRecognitionJobs: [NotyHandwritingPageKey: NotyHandwritingRecognitionJob] = [:]

    var hasICloudMirror: Bool { iCloudMirrorFolderURL != nil }

    init(storageDirectoryURL: URL? = nil) {
        if let storageDirectoryURL {
            self.storageDirectoryURL = storageDirectoryURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.storageDirectoryURL = applicationSupport.appendingPathComponent("Noty", isDirectory: true)
        }

        do {
            try fileManager.createDirectory(at: self.storageDirectoryURL, withIntermediateDirectories: true)
            loadLocalManifest()
            loadLocalTrash()
            restoreMirrorBookmark()
        } catch {
            lastPersistenceError = "Noty could not open its local library: \(error.localizedDescription)"
        }
    }

    func createFolder(name: String, parentID: UUID?) {
        guard let normalizedName = normalizedName(name) else {
            lastOperationMessage = NotyStoreError.invalidName.localizedDescription
            return
        }
        guard parentID == nil || folders.contains(where: { $0.id == parentID }) else {
            lastOperationMessage = NotyStoreError.folderNotFound.localizedDescription
            return
        }
        folders.append(NotyFolder(name: normalizedName, parentID: parentID))
        lastOperationMessage = nil
        persistCurrentManifest()
    }

    func renameFolder(id: UUID, name: String) {
        guard let normalizedName = normalizedName(name) else {
            lastOperationMessage = NotyStoreError.invalidName.localizedDescription
            return
        }
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            lastOperationMessage = NotyStoreError.folderNotFound.localizedDescription
            return
        }
        folders[index].name = normalizedName
        lastOperationMessage = nil
        persistCurrentManifest()
    }

    func deleteFolder(id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        for index in folders.indices where folders[index].parentID == id {
            folders[index].parentID = folder.parentID
        }
        for index in documents.indices where documents[index].folderID == id {
            documents[index].folderID = folder.parentID
            touchDocument(at: index)
        }
        folders.removeAll { $0.id == id }
        folderDeletionRecords.removeAll { $0.id == id }
        folderDeletionRecords.append(NotyFolderDeletionRecord(id: id, deletedAt: Self.storeTimestamp()))
        persistCurrentManifest()
    }

    @discardableResult
    func createDocument(title: String, kind: NotyDocumentKind, folderID: UUID?) -> NotyDocument {
        let normalizedTitle = normalizedName(title) ?? "Untitled"
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else {
            lastOperationMessage = NotyStoreError.folderNotFound.localizedDescription
            return NotyDocument(title: normalizedTitle, kind: kind, folderID: nil)
        }

        let page = NotyPage(template: kind == .book ? .ruled : .blank)
        let now = Self.storeTimestamp()
        let document = NotyDocument(title: normalizedTitle, kind: kind, folderID: folderID, pages: [page], createdAt: now, updatedAt: now)
        documents.append(document)
        createDocumentAssetDirectory(document.id)
        lastOperationMessage = nil
        persistCurrentManifest()
        return document
    }

    func renameDocument(id: UUID, title: String) {
        guard let normalizedTitle = normalizedName(title) else {
            lastOperationMessage = NotyStoreError.invalidName.localizedDescription
            return
        }
        guard let index = documents.firstIndex(where: { $0.id == id }) else {
            lastOperationMessage = NotyStoreError.documentNotFound.localizedDescription
            return
        }
        documents[index].title = normalizedTitle
        touchDocument(at: index)
        lastOperationMessage = nil
        persistCurrentManifest()
    }

    func moveDocument(id: UUID, to folderID: UUID?) {
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else {
            lastOperationMessage = NotyStoreError.folderNotFound.localizedDescription
            return
        }
        guard let index = documents.firstIndex(where: { $0.id == id }) else {
            lastOperationMessage = NotyStoreError.documentNotFound.localizedDescription
            return
        }
        documents[index].folderID = folderID
        touchDocument(at: index)
        lastOperationMessage = nil
        persistCurrentManifest()
    }

    func deleteDocument(id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let document = documents[index]
        let deletedAt = Self.storeTimestamp()
        let previousDeletionRecords = deletionRecords

        let preparedItem: NotyTrashedDocument
        do {
            preparedItem = try prepareLocalTrashPackage(for: document, deletedAt: deletedAt)
        } catch {
            lastOperationMessage = "Noty could not move this document to Trash, so it was not deleted: \(error.localizedDescription)"
            return
        }

        documents.remove(at: index)
        deletionRecords.removeAll { $0.id == id }
        deletionRecords.append(NotyDeletionRecord(id: id, deletedAt: deletedAt))

        guard persistCurrentManifest() else {
            documents.insert(document, at: min(index, documents.count))
            deletionRecords = previousDeletionRecords
            try? fileManager.removeItem(
                at: trashDirectoryURL.appendingPathComponent(preparedItem.recoveryDirectoryName, isDirectory: true)
            )
            return
        }

        let activeAssets = assetDirectoryURL(documentID: id)
        if fileManager.fileExists(atPath: activeAssets.path) {
            do {
                try fileManager.removeItem(at: activeAssets)
            } catch {
                lastOperationMessage = "The document is in Trash, but Noty could not remove its old active asset copy: \(error.localizedDescription)"
            }
        }
        trashItems.removeAll { $0.id == id }
        trashItems.insert(preparedItem, at: 0)
    }

    func restoreTrashedDocument(id: UUID) {
        guard let itemIndex = trashItems.firstIndex(where: { $0.id == id }) else { return }
        let item = trashItems[itemIndex]
        var document = item.document
        if let folderID = document.folderID, !folders.contains(where: { $0.id == folderID }) {
            document.folderID = nil
        }
        document.updatedAt = Self.storeTimestamp(max(Date.now, document.updatedAt.addingTimeInterval(0.001)))

        let packageURL = trashDirectoryURL.appendingPathComponent(item.recoveryDirectoryName, isDirectory: true)
        let trashedAssetsURL = packageURL.appendingPathComponent("Assets", isDirectory: true)
        let restoredAssetsURL = assetDirectoryURL(documentID: id)

        do {
            if fileManager.fileExists(atPath: restoredAssetsURL.path) {
                try fileManager.removeItem(at: restoredAssetsURL)
            }
            if fileManager.fileExists(atPath: trashedAssetsURL.path) {
                try fileManager.createDirectory(at: restoredAssetsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: trashedAssetsURL, to: restoredAssetsURL)
            } else {
                try fileManager.createDirectory(at: restoredAssetsURL, withIntermediateDirectories: true)
            }

            documents.append(document)
            deletionRecords.removeAll { $0.id == id }
            trashItems.remove(at: itemIndex)

            guard persistCurrentManifest() else {
                documents.removeAll { $0.id == id }
                deletionRecords.append(NotyDeletionRecord(id: id, deletedAt: item.deletedAt))
                trashItems.insert(item, at: min(itemIndex, trashItems.count))
                if fileManager.fileExists(atPath: restoredAssetsURL.path) {
                    try? fileManager.moveItem(at: restoredAssetsURL, to: trashedAssetsURL)
                }
                return
            }

            try? fileManager.removeItem(at: packageURL)
            lastOperationMessage = "“\(document.title)” was restored from Trash."
        } catch {
            lastOperationMessage = "The document could not be restored: \(error.localizedDescription)"
        }
    }

    func permanentlyDeleteTrashedDocument(id: UUID) {
        guard let itemIndex = trashItems.firstIndex(where: { $0.id == id }) else { return }
        let item = trashItems.remove(at: itemIndex)
        let packageURL = trashDirectoryURL.appendingPathComponent(item.recoveryDirectoryName, isDirectory: true)
        do {
            if fileManager.fileExists(atPath: packageURL.path) {
                try fileManager.removeItem(at: packageURL)
            }
            try? fileManager.removeItem(at: userImportsDirectoryURL(documentID: id))
            lastOperationMessage = "The document was permanently deleted."
        } catch {
            trashItems.insert(item, at: min(itemIndex, trashItems.count))
            lastOperationMessage = "The document could not be permanently deleted: \(error.localizedDescription)"
        }
    }

    func emptyTrash() {
        let ids = trashItems.map(\.id)
        for id in ids {
            permanentlyDeleteTrashedDocument(id: id)
        }
    }

    func addPage(documentID: UUID, after pageID: UUID?, template: NotyPageTemplate) {
        guard let documentIndex = documents.firstIndex(where: { $0.id == documentID }) else {
            lastOperationMessage = NotyStoreError.documentNotFound.localizedDescription
            return
        }
        let page = NotyPage(template: template)
        if let pageID, let pageIndex = documents[documentIndex].pages.firstIndex(where: { $0.id == pageID }) {
            documents[documentIndex].pages.insert(page, at: pageIndex + 1)
        } else {
            documents[documentIndex].pages.append(page)
        }
        touchDocument(at: documentIndex)
        createDrawingDirectory(documentID: documentID)
        lastOperationMessage = nil
        persistCurrentManifest()
    }

    func movePage(documentID: UUID, from source: IndexSet, to destination: Int) {
        guard let documentIndex = documents.firstIndex(where: { $0.id == documentID }) else {
            lastOperationMessage = NotyStoreError.documentNotFound.localizedDescription
            return
        }
        var pages = documents[documentIndex].pages
        let validOffsets = source.filter { pages.indices.contains($0) }.sorted()
        guard !validOffsets.isEmpty else { return }

        let movingPages = validOffsets.map { pages[$0] }
        for index in validOffsets.reversed() {
            pages.remove(at: index)
        }
        let adjustedDestination = max(0, min(destination - validOffsets.filter { $0 < destination }.count, pages.count))
        pages.insert(contentsOf: movingPages, at: adjustedDestination)
        documents[documentIndex].pages = pages
        touchDocument(at: documentIndex)
        persistCurrentManifest()
    }

    func deletePage(documentID: UUID, pageID: UUID) {
        guard let documentIndex = documents.firstIndex(where: { $0.id == documentID }) else {
            lastOperationMessage = NotyStoreError.documentNotFound.localizedDescription
            return
        }
        guard let pageIndex = documents[documentIndex].pages.firstIndex(where: { $0.id == pageID }) else {
            lastOperationMessage = NotyStoreError.pageNotFound.localizedDescription
            return
        }
        documents[documentIndex].pages.remove(at: pageIndex)
        touchDocument(at: documentIndex)
        lastOperationMessage = nil
        if persistCurrentManifest() {
            try? fileManager.removeItem(at: drawingURL(documentID: documentID, pageID: pageID))
            try? fileManager.removeItem(at: handwritingTextURL(documentID: documentID, pageID: pageID))
            try? fileManager.removeItem(at: pageImagesDirectoryURL(documentID: documentID, pageID: pageID))
        }
    }

    @discardableResult
    func duplicatePage(documentID: UUID, pageID: UUID) -> NotyPage? {
        guard let documentIndex = documents.firstIndex(where: { $0.id == documentID }),
              let pageIndex = documents[documentIndex].pages.firstIndex(where: { $0.id == pageID }) else {
            lastOperationMessage = NotyStoreError.pageNotFound.localizedDescription
            return nil
        }

        let sourcePage = documents[documentIndex].pages[pageIndex]
        let duplicatedPage = NotyPage(
            id: UUID(),
            template: sourcePage.template,
            sourcePageIndex: sourcePage.sourcePageIndex,
            textBoxes: sourcePage.textBoxes.map { textBox in
                var copy = textBox
                copy.id = UUID()
                return copy
            },
            images: sourcePage.images.map { image in
                var copy = image
                copy.id = UUID()
                return copy
            },
            isBookmarked: false,
            bookmarkTitle: nil
        )
        let copiedDrawingURL = drawingURL(documentID: documentID, pageID: duplicatedPage.id)
        let copiedHandwritingURL = handwritingTextURL(documentID: documentID, pageID: duplicatedPage.id)
        let sourceImagesURL = pageImagesDirectoryURL(documentID: documentID, pageID: pageID)
        let copiedImagesURL = pageImagesDirectoryURL(documentID: documentID, pageID: duplicatedPage.id)
        do {
            let sourceDrawingURL = drawingURL(documentID: documentID, pageID: pageID)
            if fileManager.fileExists(atPath: sourceDrawingURL.path) {
                try fileManager.createDirectory(at: copiedDrawingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceDrawingURL, to: copiedDrawingURL)
            }
            let sourceHandwritingURL = handwritingTextURL(documentID: documentID, pageID: pageID)
            if fileManager.fileExists(atPath: sourceHandwritingURL.path) {
                try fileManager.createDirectory(at: copiedHandwritingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceHandwritingURL, to: copiedHandwritingURL)
            }
            if fileManager.fileExists(atPath: sourceImagesURL.path) {
                try fileManager.createDirectory(at: copiedImagesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceImagesURL, to: copiedImagesURL)
            }
        } catch {
            try? fileManager.removeItem(at: copiedDrawingURL)
            try? fileManager.removeItem(at: copiedHandwritingURL)
            try? fileManager.removeItem(at: copiedImagesURL)
            lastOperationMessage = "The page could not be duplicated: \(error.localizedDescription)"
            return nil
        }

        let previousDocument = documents[documentIndex]
        documents[documentIndex].pages.insert(duplicatedPage, at: pageIndex + 1)
        touchDocument(at: documentIndex)
        lastOperationMessage = nil
        guard persistCurrentManifest() else {
            documents[documentIndex] = previousDocument
            try? fileManager.removeItem(at: copiedDrawingURL)
            try? fileManager.removeItem(at: copiedHandwritingURL)
            try? fileManager.removeItem(at: copiedImagesURL)
            return nil
        }
        if let copiedDrawingData = try? Data(contentsOf: copiedDrawingURL) {
            scheduleHandwritingRecognition(drawingData: copiedDrawingData, documentID: documentID, pageID: duplicatedPage.id)
        }
        return duplicatedPage
    }

    func updatePageTemplate(documentID: UUID, pageID: UUID, template: NotyPageTemplate) {
        guard let documentIndex = documents.firstIndex(where: { $0.id == documentID }) else {
            lastOperationMessage = NotyStoreError.documentNotFound.localizedDescription
            return
        }
        guard let pageIndex = documents[documentIndex].pages.firstIndex(where: { $0.id == pageID }) else {
            lastOperationMessage = NotyStoreError.pageNotFound.localizedDescription
            return
        }
        documents[documentIndex].pages[pageIndex].template = template
        touchDocument(at: documentIndex)
        lastOperationMessage = nil
        persistCurrentManifest()
    }

    func updateTextBoxes(documentID: UUID, pageID: UUID, textBoxes: [NotyTextBox]) {
        guard let documentIndex = documents.firstIndex(where: { $0.id == documentID }) else {
            lastOperationMessage = NotyStoreError.documentNotFound.localizedDescription
            return
        }
        guard let pageIndex = documents[documentIndex].pages.firstIndex(where: { $0.id == pageID }) else {
            lastOperationMessage = NotyStoreError.pageNotFound.localizedDescription
            return
        }
        documents[documentIndex].pages[pageIndex].textBoxes = textBoxes
        touchDocument(at: documentIndex)
        lastOperationMessage = nil
        persistCurrentManifest()
    }

    func updatePageBookmark(documentID: UUID, pageID: UUID, isBookmarked: Bool) {
        guard let documentIndex = documents.firstIndex(where: { $0.id == documentID }),
              let pageIndex = documents[documentIndex].pages.firstIndex(where: { $0.id == pageID }) else {
            lastOperationMessage = NotyStoreError.pageNotFound.localizedDescription
            return
        }
        documents[documentIndex].pages[pageIndex].isBookmarked = isBookmarked
        touchDocument(at: documentIndex)
        lastOperationMessage = nil
        persistCurrentManifest()
    }

    @discardableResult
    func addPageImage(data: Data, documentID: UUID, pageID: UUID) throws -> NotyPageImage {
        guard let documentIndex = documents.firstIndex(where: { $0.id == documentID }),
              let pageIndex = documents[documentIndex].pages.firstIndex(where: { $0.id == pageID }) else {
            throw NotyStoreError.pageNotFound
        }
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw NotyStoreError.invalidImage
        }

        let normalizedData: Data
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let normalizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let pngData = normalizedImage.pngData() else {
            throw NotyStoreError.invalidImage
        }
        normalizedData = pngData

        let fileName = "\(UUID().uuidString).png"
        let directory = pageImagesDirectoryURL(documentID: documentID, pageID: pageID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(fileName)
        try normalizedData.write(to: fileURL, options: .atomic)

        let maxWidth = 320.0
        let maxHeight = 360.0
        let aspect = Double(image.size.width / image.size.height)
        var width = maxWidth
        var height = width / max(aspect, 0.01)
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        let pageImage = NotyPageImage(
            fileName: fileName,
            x: max(24, (612 - width) / 2),
            y: max(24, (792 - height) / 2),
            width: width,
            height: height
        )

        documents[documentIndex].pages[pageIndex].images.append(pageImage)
        touchDocument(at: documentIndex)
        lastOperationMessage = nil
        guard persistCurrentManifest() else {
            documents[documentIndex].pages[pageIndex].images.removeAll { $0.id == pageImage.id }
            try? fileManager.removeItem(at: fileURL)
            throw CocoaError(.fileWriteUnknown)
        }
        return pageImage
    }

    func updatePageImages(documentID: UUID, pageID: UUID, images: [NotyPageImage]) {
        guard let documentIndex = documents.firstIndex(where: { $0.id == documentID }),
              let pageIndex = documents[documentIndex].pages.firstIndex(where: { $0.id == pageID }) else {
            lastOperationMessage = NotyStoreError.pageNotFound.localizedDescription
            return
        }
        let previousImages = documents[documentIndex].pages[pageIndex].images
        documents[documentIndex].pages[pageIndex].images = images
        touchDocument(at: documentIndex)
        lastOperationMessage = nil
        if persistCurrentManifest() {
            let retainedNames = Set(images.map(\.fileName))
            for removed in previousImages where !retainedNames.contains(removed.fileName) {
                try? fileManager.removeItem(
                    at: pageImagesDirectoryURL(documentID: documentID, pageID: pageID)
                        .appendingPathComponent(removed.fileName)
                )
            }
        }
    }

    func pageImage(documentID: UUID, pageID: UUID, image: NotyPageImage) -> UIImage? {
        UIImage(contentsOfFile: pageImagesDirectoryURL(documentID: documentID, pageID: pageID)
            .appendingPathComponent(image.fileName).path)
    }

    func saveDrawing(_ drawing: PKDrawing, documentID: UUID, pageID: UUID) {
        guard let documentIndex = documents.firstIndex(where: { $0.id == documentID }),
              documents[documentIndex].pages.contains(where: { $0.id == pageID }) else {
            lastOperationMessage = NotyStoreError.pageNotFound.localizedDescription
            return
        }
        do {
            let destination = drawingURL(documentID: documentID, pageID: pageID)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let drawingData = drawing.dataRepresentation()
            try drawingData.write(to: destination, options: .atomic)
            touchDocument(at: documentIndex)
            lastOperationMessage = nil
            if persistCurrentManifest() {
                scheduleHandwritingRecognition(drawingData: drawingData, documentID: documentID, pageID: pageID)
            }
        } catch {
            lastPersistenceError = "The drawing could not be saved: \(error.localizedDescription)"
            lastOperationMessage = lastPersistenceError
        }
    }

    func drawing(documentID: UUID, pageID: UUID) -> PKDrawing {
        let url = drawingURL(documentID: documentID, pageID: pageID)
        guard let data = try? Data(contentsOf: url), let drawing = try? PKDrawing(data: data) else {
            return PKDrawing()
        }
        return drawing
    }

    func recognizedHandwriting(documentID: UUID, pageID: UUID) -> String {
        (try? String(contentsOf: handwritingTextURL(documentID: documentID, pageID: pageID), encoding: .utf8)) ?? ""
    }

    func search(query: String) -> [NotySearchResult] {
        let queryTokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !queryTokens.isEmpty else { return [] }

        let orderedDocuments = documents.sorted { left, right in
            if left.updatedAt == right.updatedAt {
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
            return left.updatedAt > right.updatedAt
        }
        var results: [NotySearchResult] = []
        for document in orderedDocuments {
            let folderName = document.folderID.flatMap { folderID in folders.first(where: { $0.id == folderID })?.name }
            let metadata = [document.title, folderName.map { "Folder: \($0)" }].compactMap { $0 }
            if let matchingMetadata = metadata.first(where: { Self.containsEverySearchToken(queryTokens, in: $0) }) {
                results.append(NotySearchResult(
                    documentID: document.id,
                    pageID: nil,
                    documentTitle: document.title,
                    snippet: Self.searchSnippet(in: matchingMetadata, queryTokens: queryTokens)
                ))
            }

            let sourceDocument = sourcePDF(documentID: document.id)
            for page in document.pages {
                var searchableText = page.textBoxes.map(\.text)
                let handwriting = recognizedHandwriting(documentID: document.id, pageID: page.id)
                if !handwriting.isEmpty { searchableText.append(handwriting) }
                if let sourcePageIndex = page.sourcePageIndex,
                   let sourceText = sourceDocument?.page(at: sourcePageIndex)?.string,
                   !sourceText.isEmpty {
                    searchableText.append(sourceText)
                }
                let pageText = searchableText.joined(separator: "\n")
                guard Self.containsEverySearchToken(queryTokens, in: pageText) else { continue }
                results.append(NotySearchResult(
                    documentID: document.id,
                    pageID: page.id,
                    documentTitle: document.title,
                    snippet: Self.searchSnippet(in: pageText, queryTokens: queryTokens)
                ))
            }
        }
        return results
    }

    func sourcePDF(documentID: UUID) -> PDFDocument? {
        let url = sourcePDFURL(documentID: documentID)
        return PDFDocument(url: url)
    }

    func originalFile(documentID: UUID) -> URL? {
        let sharedImportURL = userImportsDirectoryURL(documentID: documentID)
        if let visibleOriginal = firstRegularFile(in: sharedImportURL) {
            return visibleOriginal
        }
        let originalsURL = assetDirectoryURL(documentID: documentID).appendingPathComponent("originals", isDirectory: true)
        return firstRegularFile(in: originalsURL)
    }

    private func firstRegularFile(in directoryURL: URL) -> URL? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first(where: { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true })
    }

    func importDocument(from url: URL, folderID: UUID?, converter: OfficeConverting? = nil) async throws -> NotyDocument {
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else {
            throw NotyStoreError.folderNotFound
        }

        let fileExtension = url.pathExtension.lowercased()
        guard ["pdf", "doc", "docx"].contains(fileExtension) else {
            throw NotyStoreError.unsupportedImportType(fileExtension.isEmpty ? "unknown" : fileExtension)
        }

        let documentID = UUID()
        let stagingURL = storageDirectoryURL.appendingPathComponent(".import-\(documentID.uuidString)", isDirectory: true)
        let originalName = safeFileName(url.lastPathComponent.isEmpty ? "Original.\(fileExtension)" : url.lastPathComponent)
        let stagedOriginalURL = stagingURL.appendingPathComponent("originals", isDirectory: true).appendingPathComponent(originalName)
        let stagedPDFURL = stagingURL.appendingPathComponent("source.pdf")
        let accessWasStarted = url.startAccessingSecurityScopedResource()
        defer {
            if accessWasStarted { url.stopAccessingSecurityScopedResource() }
        }

        do {
            try fileManager.createDirectory(at: stagedOriginalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.copyProviderFile(from: url, to: stagedOriginalURL)

            let title = Self.importTitle(from: url)
            var kind: NotyDocumentKind = .pdf
            var pages: [NotyPage] = []
            var importMessage: String?

            if fileExtension == "pdf" {
                try fileManager.copyItem(at: stagedOriginalURL, to: stagedPDFURL)
                guard let pdf = PDFDocument(url: stagedPDFURL), pdf.pageCount > 0 else {
                    throw NotyStoreError.invalidPDF
                }
                pages = (0..<pdf.pageCount).map { NotyPage(template: .blank, sourcePageIndex: $0) }
            } else {
                do {
                    if fileExtension == "docx" {
                        do {
                            _ = try await LocalOfficeConverter.convertDOCXRich(at: stagedOriginalURL, to: stagedPDFURL)
                        } catch {
                            #if DEBUG
                            NSLog("Noty DOCX rich conversion failed; using text fallback: %@", error.localizedDescription)
                            #endif
                            let plainResult = try LocalOfficeConverter.convertDOCXTextFallback(at: stagedOriginalURL, to: stagedPDFURL)
                            importMessage = "Converted \(originalName) on this iPad. Text, tables, and page layout were simplified; images and precise Word formatting may differ. Original retained."
                            if plainResult.extractedText.isEmpty {
                                importMessage = "Converted \(originalName) as text. Original retained."
                            }
                        }
                    } else {
                        throw NotyStoreError.invalidOfficeDocument(
                            "Legacy .doc conversion is not available on this iPad. The original Word file has been kept. Export it as PDF in Word or Pages to preserve its layout."
                        )
                    }
                    guard let pdf = PDFDocument(url: stagedPDFURL), pdf.pageCount > 0 else {
                        throw NotyStoreError.invalidOfficeDocument(
                            "The Word file did not produce a readable PDF. The original Word file has been kept."
                        )
                    }
                    pages = (0..<pdf.pageCount).map { NotyPage(template: .blank, sourcePageIndex: $0) }
                    if importMessage == nil {
                        importMessage = "Converted \(originalName) on this iPad. The original Word file is retained alongside the PDF."
                    }
                } catch {
                    if fileExtension == "doc", let converter {
                        do {
                            let convertedURL = try await converter.convertToPDF(fileURL: stagedOriginalURL)
                            try fileManager.copyItem(at: convertedURL, to: stagedPDFURL)
                            guard let pdf = PDFDocument(url: stagedPDFURL), pdf.pageCount > 0 else {
                                throw NotyStoreError.invalidPDF
                            }
                            pages = (0..<pdf.pageCount).map { NotyPage(template: .blank, sourcePageIndex: $0) }
                            importMessage = "Converted \(originalName). The original Word file is retained alongside the PDF."
                        } catch let conversionError {
                            kind = .note
                            pages = Self.officeFallbackPages(fileName: originalName, error: conversionError)
                            importMessage = Self.officeFallbackMessage(fileName: originalName, error: conversionError)
                        }
                    } else if fileExtension == "docx" {
                        kind = .note
                        pages = Self.officeFallbackPages(fileName: originalName, error: error)
                        importMessage = Self.officeFallbackMessage(fileName: originalName, error: error)
                    } else {
                        kind = .note
                        pages = Self.officeFallbackPages(fileName: originalName, error: error)
                        importMessage = Self.officeFallbackMessage(fileName: originalName, error: error)
                    }
                }
            }

            let document = NotyDocument(
                id: documentID,
                title: title,
                kind: kind,
                folderID: folderID,
                pages: pages,
                createdAt: Self.storeTimestamp(),
                updatedAt: Self.storeTimestamp()
            )
            let finalAssetURL = assetDirectoryURL(documentID: documentID)
            try fileManager.createDirectory(at: finalAssetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: stagingURL, to: finalAssetURL)
            var originalCopyWarning: String?
            do {
                let packagedOriginal = finalAssetURL.appendingPathComponent("originals", isDirectory: true).appendingPathComponent(originalName)
                try copyOriginalToUserDocuments(from: packagedOriginal, documentID: documentID)
            } catch {
                originalCopyWarning = "The document was imported, but its original could not be copied to the Files-visible Noty Imports folder: \(error.localizedDescription)"
            }
            documents.append(document)
            deletionRecords.removeAll { $0.id == documentID }
            lastOperationMessage = originalCopyWarning ?? importMessage
            lastPersistenceError = nil
            persistCurrentManifest()
            return document
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    func configureICloudMirror(folderURL: URL) throws {
        let accessWasStarted = folderURL.startAccessingSecurityScopedResource()
        defer {
            if accessWasStarted { folderURL.stopAccessingSecurityScopedResource() }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            syncStatus = "The selected iCloud Drive location is not available. Select a folder again."
            throw NotyStoreError.iCloudFolderUnavailable
        }

        do {
            let bookmark = try persistentFolderBookmark(for: folderURL)
            try bookmark.write(to: mirrorBookmarkURL, options: .atomic)
            iCloudMirrorFolderURL = folderURL
            syncStatus = "Backup folder selected. Checking for a saved Noty library…"
            lastOperationMessage = nil
            scheduleICloudSyncDebounced()
        } catch {
            syncStatus = "The selected folder could not be saved: \(error.localizedDescription)"
            throw error
        }
    }

    func syncICloudMirror() async {
        guard !isSyncingICloudMirror else { return }
        mirrorDebounceTask?.cancel()
        mirrorDebounceTask = nil
        guard let folderURL = iCloudMirrorFolderURL else {
            syncStatus = "Select an iCloud Drive folder to enable backup and recovery."
            return
        }
        isSyncingICloudMirror = true
        syncStatus = "Checking iCloud Drive backup…"
        lastOperationMessage = nil
        defer { isSyncingICloudMirror = false }

        do {
            await Task.yield()
            let revisionAtStart = localRevision
            let result = try Self.performICloudSync(
                localDirectory: storageDirectoryURL,
                selectedFolderURL: folderURL,
                initialManifest: currentManifest()
            )
            guard localRevision == revisionAtStart else {
                result.rollbackInstalledAssets()
                scheduleICloudSyncDebounced()
                syncStatus = "A newer local change was saved during backup. Noty will save it next."
                return
            }
            folders = result.manifest.folders
            documents = result.manifest.documents
            deletionRecords = result.manifest.deletions
            folderDeletionRecords = result.manifest.folderDeletions
            if result.localManifestChanged {
                guard persistCurrentManifest(scheduleCloudSync: false, countsAsLocalEdit: false) else {
                    result.rollbackInstalledAssets()
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            result.finalizeInstalledAssets()
            for documentID in result.restoredDocumentIDs {
                if let source = originalFile(documentID: documentID) {
                    do {
                        try copyOriginalToUserDocuments(from: source, documentID: documentID)
                    } catch {
                        lastOperationMessage = "The library was recovered, but one original file could not be copied to the Files-visible Noty Imports folder: \(error.localizedDescription)"
                    }
                }
            }
            syncStatus = "Saved to the selected iCloud Drive folder at \(Self.syncTimeString(result.syncedAt)); iPadOS manages upload."
            if let note = result.note {
                lastOperationMessage = note
            }
        } catch {
            syncStatus = "iCloud Drive sync failed: \(error.localizedDescription)"
            lastOperationMessage = "Your local Noty library is still saved on this iPad."
        }
    }

    // MARK: Shared persistence hooks

    func currentManifest() -> NotyStoreManifest {
        NotyStoreManifest(
            folders: folders,
            documents: documents,
            deletions: deletionRecords,
            folderDeletions: folderDeletionRecords
        )
    }

    @discardableResult
    func persistCurrentManifest(scheduleCloudSync: Bool = true, countsAsLocalEdit: Bool = true) -> Bool {
        do {
            try persist(currentManifest())
            lastPersistenceError = nil
            if countsAsLocalEdit {
                localRevision &+= 1
            }
            if scheduleCloudSync {
                scheduleICloudSyncDebounced()
            }
            return true
        } catch {
            lastPersistenceError = "Your library changed in memory but could not be written to this iPad: \(error.localizedDescription)"
            lastOperationMessage = lastPersistenceError
            return false
        }
    }

    func assetDirectoryURL(documentID: UUID) -> URL {
        storageDirectoryURL.appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
    }

    func sourcePDFURL(documentID: UUID) -> URL {
        assetDirectoryURL(documentID: documentID).appendingPathComponent("source.pdf")
    }

    func drawingURL(documentID: UUID, pageID: UUID) -> URL {
        assetDirectoryURL(documentID: documentID).appendingPathComponent("Drawings", isDirectory: true)
            .appendingPathComponent("\(pageID.uuidString).drawing")
    }

    func handwritingTextURL(documentID: UUID, pageID: UUID) -> URL {
        assetDirectoryURL(documentID: documentID).appendingPathComponent("Handwriting", isDirectory: true)
            .appendingPathComponent("\(pageID.uuidString).txt")
    }

    func pageImagesDirectoryURL(documentID: UUID, pageID: UUID) -> URL {
        assetDirectoryURL(documentID: documentID)
            .appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent(pageID.uuidString, isDirectory: true)
    }

    func userImportsDirectoryURL(documentID: UUID) -> URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? storageDirectoryURL.appendingPathComponent("Visible Documents", isDirectory: true)
        return documentsURL.appendingPathComponent("Noty Imports", isDirectory: true)
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
    }

    // MARK: Local persistence

    private var manifestURL: URL { storageDirectoryURL.appendingPathComponent("manifest.json") }
    private var manifestBackupURL: URL { storageDirectoryURL.appendingPathComponent("manifest.previous.json") }
    private var mirrorBookmarkURL: URL { storageDirectoryURL.appendingPathComponent("icloud-folder.bookmark") }
    private var trashDirectoryURL: URL { storageDirectoryURL.appendingPathComponent("Trash", isDirectory: true) }

    private func loadLocalManifest() {
        for url in [manifestURL, manifestBackupURL] where fileManager.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let manifest = try Self.decodeManifest(data)
                folders = manifest.folders
                documents = manifest.documents
                deletionRecords = manifest.deletions
                folderDeletionRecords = manifest.folderDeletions
                if url == manifestBackupURL {
                    lastPersistenceError = "The main library file was damaged. Noty recovered its previous saved copy."
                }
                return
            } catch {
                lastPersistenceError = "A saved library file could not be read: \(error.localizedDescription)"
            }
        }
    }

    private func loadLocalTrash() {
        guard let packages = try? fileManager.contentsOfDirectory(
            at: trashDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            trashItems = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var recovered: [NotyTrashedDocument] = []
        for package in packages {
            let metadataURL = package.appendingPathComponent("item.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  var item = try? decoder.decode(NotyTrashedDocument.self, from: data) else {
                continue
            }
            item.recoveryDirectoryName = package.lastPathComponent
            recovered.append(item)
        }
        trashItems = recovered.sorted { $0.deletedAt > $1.deletedAt }
    }

    private func persist(_ manifest: NotyStoreManifest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        if fileManager.fileExists(atPath: manifestURL.path) {
            let previous = try Data(contentsOf: manifestURL)
            try previous.write(to: manifestBackupURL, options: .atomic)
        }
        try data.write(to: manifestURL, options: .atomic)
    }

    private func restoreMirrorBookmark() {
        guard let data = try? Data(contentsOf: mirrorBookmarkURL) else { return }
        do {
            let resolved = try resolvePersistentFolderBookmark(data)
            iCloudMirrorFolderURL = resolved.url

            if resolved.isStale {
                let beganAccess = resolved.url.startAccessingSecurityScopedResource()
                defer {
                    if beganAccess { resolved.url.stopAccessingSecurityScopedResource() }
                }
                let refreshedBookmark = try persistentFolderBookmark(for: resolved.url)
                try refreshedBookmark.write(to: mirrorBookmarkURL, options: .atomic)
                syncStatus = "iCloud Drive backup folder access refreshed. Sync to check for recovery data."
            } else {
                syncStatus = "iCloud Drive backup folder ready. Sync to check for recovery data."
            }
        } catch {
            iCloudMirrorFolderURL = nil
            syncStatus = "iCloud Drive access expired. Select the backup folder again in Files."
        }
    }

    /// On iOS, directory-picker access is persisted using a minimal bookmark.
    /// Resolving that bookmark restores a security-scoped directory URL.
    private func persistentFolderBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func resolvePersistentFolderBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    private func touchDocument(at index: Int) {
        let nextUpdate = max(Self.storeTimestamp(), documents[index].updatedAt.addingTimeInterval(0.001))
        documents[index].updatedAt = Self.storeTimestamp(nextUpdate)
    }

    private static func storeTimestamp(_ date: Date = .now) -> Date {
        let milliseconds = floor(date.timeIntervalSince1970 * 1_000)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private func scheduleHandwritingRecognition(drawingData: Data, documentID: UUID, pageID: UUID) {
        let key = NotyHandwritingPageKey(documentID: documentID, pageID: pageID)
        handwritingRecognitionJobs[key]?.task.cancel()
        let jobID = UUID()
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
            } catch {
                guard let self else { return }
                self.clearHandwritingRecognitionJob(key, matching: jobID)
                return
            }
            guard !Task.isCancelled else {
                self?.clearHandwritingRecognitionJob(key, matching: jobID)
                return
            }
            let recognition = await Task.detached(priority: .utility) {
                Result { try NotyHandwritingRecognizer.recognize(drawingData: drawingData) }
            }.value
            guard let self else { return }
            guard !Task.isCancelled else {
                self.clearHandwritingRecognitionJob(key, matching: jobID)
                return
            }
            switch recognition {
            case .success(let text):
                self.finishHandwritingRecognition(
                    text,
                    drawingData: drawingData,
                    documentID: documentID,
                    pageID: pageID,
                    key: key,
                    jobID: jobID
                )
            case .failure(let error):
                self.clearHandwritingRecognitionJob(key, matching: jobID)
                NSLog("Noty handwriting recognition failed: %@", error.localizedDescription)
            }
        }
        handwritingRecognitionJobs[key] = NotyHandwritingRecognitionJob(id: jobID, task: task)
    }

    private func finishHandwritingRecognition(
        _ text: String,
        drawingData: Data,
        documentID: UUID,
        pageID: UUID,
        key: NotyHandwritingPageKey,
        jobID: UUID
    ) {
        guard handwritingRecognitionJobs[key]?.id == jobID else { return }
        handwritingRecognitionJobs[key] = nil
        guard let documentIndex = documents.firstIndex(where: { $0.id == documentID }),
              documents[documentIndex].pages.contains(where: { $0.id == pageID }),
              let savedDrawingData = try? Data(contentsOf: drawingURL(documentID: documentID, pageID: pageID)),
              savedDrawingData == drawingData else {
            return
        }

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sidecarURL = handwritingTextURL(documentID: documentID, pageID: pageID)
        let previousSidecarData = try? Data(contentsOf: sidecarURL)
        let previousText = previousSidecarData.flatMap { String(data: $0, encoding: .utf8) }
        guard previousText != normalizedText else { return }

        do {
            if normalizedText.isEmpty {
                if fileManager.fileExists(atPath: sidecarURL.path) {
                    try fileManager.removeItem(at: sidecarURL)
                } else {
                    return
                }
            } else {
                try fileManager.createDirectory(at: sidecarURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(normalizedText.utf8).write(to: sidecarURL, options: .atomic)
            }

            let previousDocument = documents[documentIndex]
            touchDocument(at: documentIndex)
            if !persistCurrentManifest() {
                documents[documentIndex] = previousDocument
                if let previousSidecarData {
                    try? previousSidecarData.write(to: sidecarURL, options: .atomic)
                } else {
                    try? fileManager.removeItem(at: sidecarURL)
                }
            }
        } catch {
            NSLog("Noty handwriting OCR sidecar could not be saved: %@", error.localizedDescription)
        }
    }

    private func clearHandwritingRecognitionJob(_ key: NotyHandwritingPageKey, matching jobID: UUID) {
        guard handwritingRecognitionJobs[key]?.id == jobID else { return }
        handwritingRecognitionJobs[key] = nil
    }

    private static func containsEverySearchToken(_ tokens: [String], in text: String) -> Bool {
        let searchableText = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return tokens.allSatisfy { token in
            searchableText.contains(token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }
    }

    private static func searchSnippet(in text: String, queryTokens: [String]) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmedText as NSString
        guard source.length > 120 else { return trimmedText }
        let firstMatch = queryTokens.first.flatMap {
            source.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
        }
        let start = max(0, (firstMatch?.location ?? 0) - 48)
        let end = min(source.length, start + 120)
        let snippet = source.substring(with: NSRange(location: start, length: end - start))
        return "\(start > 0 ? "…" : "")\(snippet)\(end < source.length ? "…" : "")"
    }

    private static func decodeManifest(_ data: Data) throws -> NotyStoreManifest {
        let currentDecoder = JSONDecoder()
        currentDecoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try currentDecoder.decode(NotyStoreManifest.self, from: data)
        } catch {
            let legacyDecoder = JSONDecoder()
            legacyDecoder.dateDecodingStrategy = .iso8601
            return try legacyDecoder.decode(NotyStoreManifest.self, from: data)
        }
    }

    private func normalizedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
    }

    private func createDocumentAssetDirectory(_ documentID: UUID) {
        do {
            try fileManager.createDirectory(at: assetDirectoryURL(documentID: documentID), withIntermediateDirectories: true)
        } catch {
            lastPersistenceError = "Noty could not prepare document storage: \(error.localizedDescription)"
        }
    }

    private func createDrawingDirectory(documentID: UUID) {
        do {
            try fileManager.createDirectory(
                at: assetDirectoryURL(documentID: documentID).appendingPathComponent("Drawings", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            lastPersistenceError = "Noty could not prepare drawing storage: \(error.localizedDescription)"
        }
    }

    private func prepareLocalTrashPackage(
        for document: NotyDocument,
        deletedAt: Date
    ) throws -> NotyTrashedDocument {
        let source = assetDirectoryURL(documentID: document.id)
        let directoryName = "\(document.id.uuidString)-\(Int(deletedAt.timeIntervalSince1970))"
        let packageURL = trashDirectoryURL.appendingPathComponent(directoryName, isDirectory: true)
        let trashedAssetsURL = packageURL.appendingPathComponent("Assets", isDirectory: true)

        if fileManager.fileExists(atPath: packageURL.path) {
            try fileManager.removeItem(at: packageURL)
        }
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        do {
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: trashedAssetsURL)
            }

            let item = NotyTrashedDocument(
                document: document,
                deletedAt: deletedAt,
                recoveryDirectoryName: directoryName
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(item).write(
                to: packageURL.appendingPathComponent("item.json"),
                options: .atomic
            )
            return item
        } catch {
            try? fileManager.removeItem(at: packageURL)
            throw error
        }
    }

    private func copyOriginalToUserDocuments(from sourceURL: URL, documentID: UUID) throws {
        let destinationDirectory = userImportsDirectoryURL(documentID: documentID)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    func scheduleICloudSyncDebounced() {
        guard iCloudMirrorFolderURL != nil else { return }
        mirrorDebounceTask?.cancel()
        mirrorDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_200_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.mirrorDebounceTask = nil
            await self.syncICloudMirror()
        }
    }

    private static func importTitle(from url: URL) -> String {
        let title = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Imported document" : String(title.prefix(200))
    }

    private func safeFileName(_ proposedName: String) -> String {
        let name = URL(fileURLWithPath: proposedName).lastPathComponent
        return name.isEmpty || name == "." ? "Original file" : name
    }

    private static func officeFallbackPages(fileName: String, error: Error) -> [NotyPage] {
        let explanation = officeFallbackMessage(fileName: fileName, error: error)
        return [NotyPage(textBoxes: [NotyTextBox(text: explanation, x: 36, y: 36, width: 540, height: 600, fontSize: 16)])]
    }

    private static func officeFallbackMessage(fileName: String, error: Error) -> String {
        "The original Word document “\(fileName)” is saved with this note. Noty could not convert it on this iPad. Export it as PDF from Word or Pages and import that PDF to preserve the original page layout. Details: \(error.localizedDescription)"
    }

    private static func syncTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private static func copyProviderFile(from sourceURL: URL, to destinationURL: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var copyError: Error?
        coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            do {
                try FileManager.default.copyItem(at: coordinatedURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw CocoaError(.fileReadUnknown)
        }
    }
}

private struct NotyHandwritingPageKey: Hashable {
    let documentID: UUID
    let pageID: UUID
}

private struct NotyHandwritingRecognitionJob {
    let id: UUID
    let task: Task<Void, Never>
}

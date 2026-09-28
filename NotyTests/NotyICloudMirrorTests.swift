import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import Noty

final class NotyICloudMirrorTests: XCTestCase {
    @MainActor
    func testLibrarySearchFindsFolderNamePDFTextAndTypedAnnotation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotySearchQA-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NotyStore(storageDirectoryURL: root)
        store.createFolder(name: "Mathematics", parentID: nil)
        let folderID = try XCTUnwrap(store.folders.first?.id)
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "noty-qa", withExtension: "pdf", subdirectory: "Fixtures"
        ) ?? Bundle(for: Self.self).url(forResource: "noty-qa", withExtension: "pdf"))
        let document = try await store.importDocument(from: fixtureURL, folderID: folderID)
        defer { try? FileManager.default.removeItem(at: store.userImportsDirectoryURL(documentID: document.id)) }
        let pageID = try XCTUnwrap(document.pages.first?.id)
        store.updateTextBoxes(documentID: document.id, pageID: pageID, textBoxes: [
            NotyTextBox(text: "Quadratic formula annotation")
        ])

        XCTAssertTrue(store.search(query: "Mathematics").contains { $0.documentID == document.id })
        XCTAssertTrue(store.search(query: "Noty conversion check").contains { $0.pageID == pageID })
        XCTAssertTrue(store.search(query: "Quadratic formula").contains { $0.pageID == pageID })
    }

    @MainActor
    func testUnchangedMirrorSyncDoesNotCreateAnotherSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotyMirrorNoOpQA-\(UUID().uuidString)", isDirectory: true)
        let libraryURL = root.appendingPathComponent("library", isDirectory: true)
        let selectedCloudFolder = root.appendingPathComponent("selected-cloud-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedCloudFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NotyStore(storageDirectoryURL: libraryURL)
        _ = store.createDocument(title: "Rapid edits", kind: .note, folderID: nil)
        try store.configureICloudMirror(folderURL: selectedCloudFolder)
        await store.syncICloudMirror()
        XCTAssertFalse(store.syncStatus.contains("failed"), store.syncStatus)

        let snapshotsURL = selectedCloudFolder.appendingPathComponent("Noty Backup/Snapshots", isDirectory: true)
        let firstGenerationCount = try FileManager.default.contentsOfDirectory(atPath: snapshotsURL.path).count
        XCTAssertEqual(firstGenerationCount, 1)

        await store.syncICloudMirror()
        XCTAssertFalse(store.syncStatus.contains("failed"), store.syncStatus)
        let secondGenerationCount = try FileManager.default.contentsOfDirectory(atPath: snapshotsURL.path).count
        XCTAssertEqual(secondGenerationCount, firstGenerationCount, "An unchanged library should reuse its current backup generation.")
    }

    @MainActor
    func testMirrorRestoresImportedPagesAnnotationsAndFoldersAfterLocalLibraryLoss() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotyMirrorQA-\(UUID().uuidString)", isDirectory: true)
        let originalLibrary = root.appendingPathComponent("original", isDirectory: true)
        let replacementLibrary = root.appendingPathComponent("replacement", isDirectory: true)
        let selectedCloudFolder = root.appendingPathComponent("selected-cloud-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedCloudFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NotyStore(storageDirectoryURL: originalLibrary)
        store.createFolder(name: "School", parentID: nil)
        let folderID = try XCTUnwrap(store.folders.first?.id)
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "noty-qa", withExtension: "pdf", subdirectory: "Fixtures")
            ?? Bundle(for: Self.self).url(forResource: "noty-qa", withExtension: "pdf"))
        let imported = try await store.importDocument(from: fixtureURL, folderID: folderID)
        defer { try? FileManager.default.removeItem(at: store.userImportsDirectoryURL(documentID: imported.id)) }
        let pageID = try XCTUnwrap(imported.pages.first?.id)
        store.updateTextBoxes(
            documentID: imported.id,
            pageID: pageID,
            textBoxes: [NotyTextBox(text: "Cloud recovery annotation", x: 80, y: 100, width: 300, height: 80, fontSize: 19)]
        )

        let strokePoints = [
            PKStrokePoint(location: CGPoint(x: 80, y: 400), timeOffset: 0, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 160, y: 420), timeOffset: 0.1, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        ]
        let drawing = PKDrawing(strokes: [
            PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: strokePoints, creationDate: .now), transform: .identity, mask: nil)
        ])
        store.saveDrawing(drawing, documentID: imported.id, pageID: pageID)
        try store.configureICloudMirror(folderURL: selectedCloudFolder)
        await store.syncICloudMirror()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: selectedCloudFolder.appendingPathComponent("Noty Backup/Current.json").path
        ))
        XCTAssertFalse(store.syncStatus.contains("failed"), store.syncStatus)

        let restoredStore = NotyStore(storageDirectoryURL: replacementLibrary)
        try restoredStore.configureICloudMirror(folderURL: selectedCloudFolder)
        await restoredStore.syncICloudMirror()

        let restored = try XCTUnwrap(restoredStore.documents.first(where: { $0.id == imported.id }))
        XCTAssertEqual(restored.folderID, folderID)
        XCTAssertEqual(restoredStore.folders.first?.name, "School")
        XCTAssertEqual(restored.pages.first?.textBoxes.first?.text, "Cloud recovery annotation")
        let recoveredDrawing = restoredStore.drawing(documentID: restored.id, pageID: pageID)
        XCTAssertEqual(recoveredDrawing.strokes.count, drawing.strokes.count)
        XCTAssertEqual(recoveredDrawing.bounds.origin.x, drawing.bounds.origin.x, accuracy: 0.5)
        XCTAssertEqual(recoveredDrawing.bounds.origin.y, drawing.bounds.origin.y, accuracy: 0.5)
        XCTAssertEqual(recoveredDrawing.bounds.width, drawing.bounds.width, accuracy: 0.5)
        XCTAssertEqual(recoveredDrawing.bounds.height, drawing.bounds.height, accuracy: 0.5)
        XCTAssertTrue(restoredStore.sourcePDF(documentID: restored.id)?.page(at: 0)?.string?.contains("Noty conversion check") == true)
        XCTAssertNil(restoredStore.lastPersistenceError)
        XCTAssertFalse(restoredStore.syncStatus.contains("failed"), restoredStore.syncStatus)

        // A deliberate deletion must not be undone by a later fresh install.
        restoredStore.deleteDocument(id: restored.id)
        await restoredStore.syncICloudMirror()
        XCTAssertFalse(restoredStore.syncStatus.contains("failed"), restoredStore.syncStatus)

        let finalLibrary = root.appendingPathComponent("after-deletion", isDirectory: true)
        let finalStore = NotyStore(storageDirectoryURL: finalLibrary)
        try finalStore.configureICloudMirror(folderURL: selectedCloudFolder)
        await finalStore.syncICloudMirror()
        XCTAssertFalse(finalStore.documents.contains(where: { $0.id == imported.id }))
        XCTAssertFalse(finalStore.syncStatus.contains("failed"), finalStore.syncStatus)
    }

    @MainActor
    func testICloudFolderBookmarkRestoresAfterStoreRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotyMirrorBookmarkQA-\(UUID().uuidString)", isDirectory: true)
        let libraryURL = root.appendingPathComponent("library", isDirectory: true)
        let selectedCloudFolder = root.appendingPathComponent("selected-cloud-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedCloudFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NotyStore(storageDirectoryURL: libraryURL)
        _ = store.createDocument(title: "Persisted backup", kind: .note, folderID: nil)
        try store.configureICloudMirror(folderURL: selectedCloudFolder)
        await store.syncICloudMirror()
        XCTAssertFalse(store.syncStatus.localizedCaseInsensitiveContains("failed"), store.syncStatus)

        let reopenedStore = NotyStore(storageDirectoryURL: libraryURL)
        let reopenedFolder = try XCTUnwrap(reopenedStore.iCloudMirrorFolderURL)
        XCTAssertEqual(
            reopenedFolder.standardizedFileURL.path,
            selectedCloudFolder.standardizedFileURL.path
        )

        await reopenedStore.syncICloudMirror()
        XCTAssertFalse(reopenedStore.syncStatus.localizedCaseInsensitiveContains("failed"), reopenedStore.syncStatus)
        XCTAssertEqual(reopenedStore.documents.first?.title, "Persisted backup")
    }

}

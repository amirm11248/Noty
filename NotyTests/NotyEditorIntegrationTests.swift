import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import Noty

final class NotyEditorIntegrationTests: XCTestCase {
    @MainActor
    func testPDFImportReorderTextAndInkSurviveStoreReload() async throws {
        let (store, directory) = try makeStore()
        var importedFilesURL: URL?
        defer {
            if let importedFilesURL { try? FileManager.default.removeItem(at: importedFilesURL) }
            try? FileManager.default.removeItem(at: directory)
        }

        let imported = try await store.importDocument(from: fixture(named: "noty-qa", extension: "pdf"), folderID: nil)
        importedFilesURL = store.userImportsDirectoryURL(documentID: imported.id)
        XCTAssertEqual(imported.kind, .pdf)
        XCTAssertEqual(imported.pages.count, 1)

        let sourcePageID = imported.pages[0].id
        store.addPage(documentID: imported.id, after: sourcePageID, template: .ruled)
        let ruledPageID = try XCTUnwrap(store.documents.first(where: { $0.id == imported.id })?.pages.last?.id)
        store.addPage(documentID: imported.id, after: ruledPageID, template: .dots)
        let dottedPageID = try XCTUnwrap(store.documents.first(where: { $0.id == imported.id })?.pages.last?.id)

        let textBox = NotyTextBox(
            text: "Persisted editor text",
            x: 72,
            y: 116,
            width: 320,
            height: 84,
            fontSize: 20
        )
        store.updateTextBoxes(documentID: imported.id, pageID: sourcePageID, textBoxes: [textBox])
        let drawing = pencilDrawing()
        store.saveDrawing(drawing, documentID: imported.id, pageID: sourcePageID)

        // The destination follows List-style move semantics: moving page zero to
        // the end of the three-page document uses destination index three.
        store.movePage(documentID: imported.id, from: IndexSet(integer: 0), to: 3)
        let expectedPageIDs = [ruledPageID, dottedPageID, sourcePageID]
        XCTAssertEqual(store.documents.first(where: { $0.id == imported.id })?.pages.map(\.id), expectedPageIDs)

        let reloadedStore = NotyStore(storageDirectoryURL: directory)
        let reloadedDocument = try XCTUnwrap(reloadedStore.documents.first(where: { $0.id == imported.id }))
        XCTAssertEqual(reloadedDocument.pages.map(\.id), expectedPageIDs)
        XCTAssertEqual(reloadedDocument.pages.last?.sourcePageIndex, 0)
        XCTAssertEqual(reloadedDocument.pages.last?.textBoxes, [textBox])
        let reloadedDrawing = reloadedStore.drawing(documentID: imported.id, pageID: sourcePageID)
        XCTAssertEqual(reloadedDrawing.strokes.count, drawing.strokes.count)
        // PencilKit's encoded drawing bytes are not a canonical equality contract;
        // compare the recovered ink and sampled stroke geometry instead.
        let originalStroke = try XCTUnwrap(drawing.strokes.first)
        let reloadedStroke = try XCTUnwrap(reloadedDrawing.strokes.first)
        XCTAssertEqual(reloadedStroke.path.count, originalStroke.path.count)
        XCTAssertEqual(reloadedStroke.ink.inkType, originalStroke.ink.inkType)
        var originalRed: CGFloat = 0
        var originalGreen: CGFloat = 0
        var originalBlue: CGFloat = 0
        var reloadedRed: CGFloat = 0
        var reloadedGreen: CGFloat = 0
        var reloadedBlue: CGFloat = 0
        XCTAssertTrue(originalStroke.ink.color.getRed(&originalRed, green: &originalGreen, blue: &originalBlue, alpha: nil))
        XCTAssertTrue(reloadedStroke.ink.color.getRed(&reloadedRed, green: &reloadedGreen, blue: &reloadedBlue, alpha: nil))
        XCTAssertEqual(reloadedRed, originalRed, accuracy: 0.02)
        XCTAssertEqual(reloadedGreen, originalGreen, accuracy: 0.02)
        XCTAssertEqual(reloadedBlue, originalBlue, accuracy: 0.02)
        for index in 0..<min(originalStroke.path.count, reloadedStroke.path.count) {
            let originalPoint = originalStroke.path[index]
            let reloadedPoint = reloadedStroke.path[index]
            XCTAssertEqual(reloadedPoint.location.x, originalPoint.location.x, accuracy: 0.1)
            XCTAssertEqual(reloadedPoint.location.y, originalPoint.location.y, accuracy: 0.1)
            XCTAssertEqual(reloadedPoint.size.width, originalPoint.size.width, accuracy: 0.1)
            XCTAssertEqual(reloadedPoint.size.height, originalPoint.size.height, accuracy: 0.1)
            XCTAssertEqual(reloadedPoint.force, originalPoint.force, accuracy: 0.01)
            XCTAssertEqual(reloadedPoint.opacity, originalPoint.opacity, accuracy: 0.01)
        }
        XCTAssertEqual(reloadedDrawing.bounds.minX, drawing.bounds.minX, accuracy: 0.1)
        XCTAssertEqual(reloadedDrawing.bounds.minY, drawing.bounds.minY, accuracy: 0.1)
        XCTAssertEqual(reloadedDrawing.bounds.width, drawing.bounds.width, accuracy: 0.1)
        XCTAssertEqual(reloadedDrawing.bounds.height, drawing.bounds.height, accuracy: 0.1)
        XCTAssertEqual(reloadedStore.sourcePDF(documentID: imported.id)?.pageCount, 1)
        XCTAssertNil(reloadedStore.lastPersistenceError)
    }

    @MainActor
    func testDuplicatePDFPagePreservesSourceTextBoxesAndDrawingAfterReload() async throws {
        let (store, directory) = try makeStore()
        var importedFilesURL: URL?
        defer {
            if let importedFilesURL { try? FileManager.default.removeItem(at: importedFilesURL) }
            try? FileManager.default.removeItem(at: directory)
        }

        let imported = try await store.importDocument(from: fixture(named: "noty-qa", extension: "pdf"), folderID: nil)
        importedFilesURL = store.userImportsDirectoryURL(documentID: imported.id)
        let sourcePage = try XCTUnwrap(imported.pages.first)
        let textBox = NotyTextBox(text: "Keep this annotation", x: 96, y: 144, width: 280, height: 72, fontSize: 19)
        store.updateTextBoxes(documentID: imported.id, pageID: sourcePage.id, textBoxes: [textBox])
        let drawing = pencilDrawing()
        store.saveDrawing(drawing, documentID: imported.id, pageID: sourcePage.id)

        let duplicate = try XCTUnwrap(store.duplicatePage(documentID: imported.id, pageID: sourcePage.id))
        XCTAssertNotEqual(duplicate.id, sourcePage.id)
        XCTAssertEqual(duplicate.sourcePageIndex, sourcePage.sourcePageIndex)
        XCTAssertEqual(duplicate.template, sourcePage.template)
        XCTAssertEqual(duplicate.textBoxes.map(\.text), [textBox.text])
        XCTAssertNotEqual(duplicate.textBoxes.first?.id, textBox.id)

        let duplicateDrawing = store.drawing(documentID: imported.id, pageID: duplicate.id)
        XCTAssertEqual(duplicateDrawing.strokes.count, drawing.strokes.count)
        XCTAssertEqual(duplicateDrawing.bounds.minX, drawing.bounds.minX, accuracy: 0.1)
        XCTAssertEqual(duplicateDrawing.bounds.minY, drawing.bounds.minY, accuracy: 0.1)
        XCTAssertEqual(duplicateDrawing.bounds.width, drawing.bounds.width, accuracy: 0.1)
        XCTAssertEqual(duplicateDrawing.bounds.height, drawing.bounds.height, accuracy: 0.1)

        let reloadedStore = NotyStore(storageDirectoryURL: directory)
        let reloadedDocument = try XCTUnwrap(reloadedStore.documents.first(where: { $0.id == imported.id }))
        let reloadedDuplicate = try XCTUnwrap(reloadedDocument.pages.first(where: { $0.id == duplicate.id }))
        XCTAssertEqual(reloadedDuplicate.sourcePageIndex, sourcePage.sourcePageIndex)
        XCTAssertEqual(reloadedDuplicate.textBoxes.map(\.text), [textBox.text])
        XCTAssertNotEqual(reloadedDuplicate.textBoxes.first?.id, textBox.id)

        let reloadedDrawing = reloadedStore.drawing(documentID: imported.id, pageID: duplicate.id)
        XCTAssertEqual(reloadedDrawing.strokes.count, drawing.strokes.count)
        XCTAssertEqual(reloadedDrawing.bounds.minX, drawing.bounds.minX, accuracy: 0.1)
        XCTAssertEqual(reloadedDrawing.bounds.minY, drawing.bounds.minY, accuracy: 0.1)
        XCTAssertEqual(reloadedDrawing.bounds.width, drawing.bounds.width, accuracy: 0.1)
        XCTAssertEqual(reloadedDrawing.bounds.height, drawing.bounds.height, accuracy: 0.1)
        XCTAssertEqual(reloadedStore.sourcePDF(documentID: imported.id)?.pageCount, 1)
    }

    @MainActor
    func testPDFAndImageExportsContainPageContentAndUseStableSyncURL() async throws {
        let (store, directory) = try makeStore()
        var importedFilesURL: URL?
        defer {
            if let importedFilesURL { try? FileManager.default.removeItem(at: importedFilesURL) }
            try? FileManager.default.removeItem(at: directory)
        }

        let imported = try await store.importDocument(from: fixture(named: "noty-qa", extension: "pdf"), folderID: nil)
        importedFilesURL = store.userImportsDirectoryURL(documentID: imported.id)
        let sourcePageID = try XCTUnwrap(imported.pages.first?.id)
        store.updateTextBoxes(
            documentID: imported.id,
            pageID: sourcePageID,
            textBoxes: [NotyTextBox(text: "EXPORT_SENTINEL", x: 72, y: 610, width: 300, height: 64, fontSize: 22)]
        )
        store.saveDrawing(pencilDrawing(), documentID: imported.id, pageID: sourcePageID)
        store.addPage(documentID: imported.id, after: sourcePageID, template: .ruled)

        let exportedURL = try NotyExportService.exportPDF(documentID: imported.id, store: store)
        let exportedPDF = try XCTUnwrap(PDFDocument(url: exportedURL))
        XCTAssertEqual(exportedPDF.pageCount, 2)
        let exportedPage = try XCTUnwrap(exportedPDF.page(at: 0))
        XCTAssertTrue(exportedPage.string?.contains("Noty conversion check") == true)
        let extractedText = try XCTUnwrap(exportedPage.string)
        let normalizedExtractedText = String(extractedText.filter(\.isLetter))
        XCTAssertTrue(normalizedExtractedText.contains("EXPORTSENTINEL"))

        let imageURL = try NotyExportService.exportPageImage(documentID: imported.id, pageID: sourcePageID, store: store)
        let image = try XCTUnwrap(UIImage(contentsOfFile: imageURL.path))
        let bitmap = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(bitmap.width, 1836)
        XCTAssertEqual(bitmap.height, 2376)
        XCTAssertGreaterThan(nonWhitePixelCount(in: bitmap), 1_000)

        let syncURL = try NotyExportService.exportPDFForSync(documentID: imported.id, store: store)
        let firstSyncData = try Data(contentsOf: syncURL)
        store.updateTextBoxes(
            documentID: imported.id,
            pageID: sourcePageID,
            textBoxes: [NotyTextBox(text: "UPDATED_SYNC_SENTINEL", x: 72, y: 610, width: 300, height: 64, fontSize: 22)]
        )
        let rewrittenSyncURL = try NotyExportService.exportPDFForSync(documentID: imported.id, store: store)
        let rewrittenSyncData = try Data(contentsOf: rewrittenSyncURL)
        XCTAssertEqual(syncURL, rewrittenSyncURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: syncURL.path))
        XCTAssertNotEqual(firstSyncData, rewrittenSyncData)
        XCTAssertNotEqual(exportedURL, syncURL)
    }

    @MainActor
    func testDOCXFixtureImportsAsPDFAndRetainsOriginalFile() async throws {
        let (store, directory) = try makeStore()
        var importedFilesURL: URL?
        defer {
            if let importedFilesURL { try? FileManager.default.removeItem(at: importedFilesURL) }
            try? FileManager.default.removeItem(at: directory)
        }

        let fixtureURL = try fixture(named: "noty-qa", extension: "docx")
        let imported = try await store.importDocument(from: fixtureURL, folderID: nil)
        importedFilesURL = store.userImportsDirectoryURL(documentID: imported.id)

        XCTAssertEqual(imported.kind, .pdf)
        XCTAssertGreaterThan(imported.pages.count, 0)
        let convertedPDF = try XCTUnwrap(store.sourcePDF(documentID: imported.id))
        XCTAssertGreaterThan(convertedPDF.pageCount, 0)
        XCTAssertTrue(convertedPDF.page(at: 0)?.string?.contains("Noty conversion check") == true)
        let conversionMessage = store.lastOperationMessage ?? ""
        XCTAssertFalse(conversionMessage.localizedCaseInsensitiveContains("simplified"), conversionMessage)
        XCTAssertFalse(conversionMessage.localizedCaseInsensitiveContains("fallback"), conversionMessage)

        let retainedOriginal = try XCTUnwrap(store.originalFile(documentID: imported.id))
        XCTAssertEqual(retainedOriginal.pathExtension.lowercased(), "docx")
        XCTAssertEqual(try Data(contentsOf: retainedOriginal), try Data(contentsOf: fixtureURL))
    }

    @MainActor
    private func makeStore() throws -> (NotyStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotyIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (NotyStore(storageDirectoryURL: directory), directory)
    }

    private func fixture(named name: String, extension fileExtension: String) throws -> URL {
        let bundle = Bundle(for: NotyEditorIntegrationTests.self)
        let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: fileExtension)
        return try XCTUnwrap(url, "Missing test fixture \(name).\(fileExtension); add NotyTests/Fixtures to the test target resources.")
    }

    private func pencilDrawing() -> PKDrawing {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 72, y: 694),
                timeOffset: 0,
                size: CGSize(width: 5, height: 5),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 118, y: 678),
                timeOffset: 0.05,
                size: CGSize(width: 5, height: 5),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 164, y: 694),
                timeOffset: 0.1,
                size: CGSize(width: 5, height: 5),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1))
        let stroke = PKStroke(ink: PKInk(.pen, color: .systemRed), path: path, transform: .identity, mask: nil)
        return PKDrawing(strokes: [stroke])
    }

    private func nonWhitePixelCount(in image: CGImage) -> Int {
        guard let providerData = image.dataProvider?.data else { return 0 }
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return 0 }
        let bytes = providerData as Data

        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * bytesPerPixel
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                if red < 242 || green < 242 || blue < 242 {
                    count += 1
                }
            }
        }
        return count
    }
}

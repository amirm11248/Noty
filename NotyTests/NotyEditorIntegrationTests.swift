import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import Noty

final class NotyEditorIntegrationTests: XCTestCase {
    @MainActor
    func testImportedCustomAndRotatedPDFSizesSurviveDuplicationReloadAndExport() async throws {
        let (store, directory) = try makeStore()
        var importedFilesURL: URL?
        var exportedURL: URL?
        defer {
            if let importedFilesURL { try? FileManager.default.removeItem(at: importedFilesURL) }
            if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
            try? FileManager.default.removeItem(at: directory)
        }
        let originalSize = CGSize(width: 864, height: 486)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: originalSize))
        let original = try XCTUnwrap(PDFDocument(data: renderer.pdfData { context in
            context.beginPage()
            ("Landscape lecture slide" as NSString).draw(at: CGPoint(x: 40, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 400, height: 700), pageInfo: [:])
            ("Rotated lecture slide" as NSString).draw(at: CGPoint(x: 40, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }))
        original.page(at: 1)?.rotation = 90
        let inputURL = directory.appendingPathComponent("Lecture.pdf")
        XCTAssertTrue(original.write(to: inputURL))
        let imported = try await store.importDocument(from: inputURL, folderID: nil)
        importedFilesURL = store.userImportsDirectoryURL(documentID: imported.id)
        XCTAssertEqual(imported.pages[0].canvasSize, originalSize)
        XCTAssertEqual(imported.pages[1].canvasSize, CGSize(width: 700, height: 400))
        let duplicate = try XCTUnwrap(store.duplicatePage(documentID: imported.id, pageID: imported.pages[0].id))
        XCTAssertEqual(duplicate.canvasSize, originalSize)
        let added = try XCTUnwrap(store.addPage(documentID: imported.id, after: duplicate.id, template: .grid))
        XCTAssertEqual(added.canvasSize, originalSize, "New pages should inherit the current page's actual dimensions.")
        let reloaded = NotyStore(storageDirectoryURL: directory)
        let document = try XCTUnwrap(reloaded.documents.first(where: { $0.id == imported.id }))
        exportedURL = try NotyExportService.exportPDF(documentID: document.id, store: reloaded)
        let exported = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(exportedURL)))
        XCTAssertEqual(exported.pageCount, document.pages.count)
        for (index, page) in document.pages.enumerated() {
            XCTAssertEqual(try XCTUnwrap(exported.page(at: index)).bounds(for: .mediaBox).size, page.canvasSize)
        }
        XCTAssertTrue(exported.page(at: 0)?.string?.contains("Landscape lecture slide") == true)
        XCTAssertTrue(exported.page(at: 3)?.string?.contains("Rotated lecture slide") == true)
        reloaded.updatePageFormat(documentID: document.id, pageID: added.id, sizePreset: .a4)
        let resized = try XCTUnwrap(reloaded.documents.first?.pages.first(where: { $0.id == added.id }))
        XCTAssertNil(resized.customWidth)
        XCTAssertEqual(resized.canvasSize, CGSize(width: NotyPageSizePreset.a4.portraitSize.height, height: NotyPageSizePreset.a4.portraitSize.width))
    }

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
    func testMixedLassoUsesVisibleInkAndRotatedPhotoGeometryAndFilters() throws {
        var page = NotyPage(template: .blank)
        let text = NotyTextBox(text: "Exam notes", x: 20, y: 100, width: 160, height: 50)
        let photo = NotyPageImage(fileName: "diagram.png", x: 80, y: 170, width: 120, height: 60, rotationDegrees: 90)
        page.textBoxes = [text]; page.images = [photo]
        var ink = try XCTUnwrap(pencilDrawing().strokes.first)
        ink.transform = CGAffineTransform(translationX: -52, y: -650)
        var outside = ink; outside.transform = ink.transform.concatenating(CGAffineTransform(translationX: 300, y: 300))
        let content = NotyPageContent(page: page, drawing: PKDrawing(strokes: [ink, outside]))
        let loop = [CGPoint(x: 5, y: 5), CGPoint(x: 220, y: 5), CGPoint(x: 220, y: 280), CGPoint(x: 5, y: 280)]
        let selected = try XCTUnwrap(NotyPageSelection.select(points: loop, shape: .freehand, filter: NotySelectionFilter(), content: content))
        XCTAssertEqual(selected.strokeIndices, IndexSet(integer: 0))
        XCTAssertEqual(selected.textIDs, [text.id]); XCTAssertEqual(selected.imageIDs, [photo.id])
        XCTAssertEqual(selected.count, 3)
        let inkOnly = try XCTUnwrap(NotyPageSelection.select(points: loop, shape: .freehand, filter: NotySelectionFilter(handwriting: true, text: false, photos: false), content: content))
        XCTAssertEqual(inkOnly.count, 1)
        XCTAssertNil(NotyPageSelection.select(points: [CGPoint(x: 80, y: 170), CGPoint(x: 92, y: 182)], shape: .rectangle, filter: NotySelectionFilter(handwriting: false, text: false, photos: true), content: content), "A photo's unrotated empty corner must not be selected.")
        XCTAssertNotNil(NotyPageSelection.select(points: [CGPoint(x: 120, y: 142), CGPoint(x: 155, y: 162)], shape: .rectangle, filter: NotySelectionFilter(handwriting: false, text: false, photos: true), content: content))

        let path = PKStrokePath(controlPoints: [CGPoint(x: 10, y: 10), CGPoint(x: 190, y: 10)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 6, height: 6), opacity: 1, force: 0.7, azimuth: 1, altitude: 1)
        }, creationDate: Date())
        let mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 50, height: 30))
        mask.append(UIBezierPath(rect: CGRect(x: 150, y: 0, width: 50, height: 30)))
        let erased = PKStroke(ink: PKInk(.pen, color: .black), path: path, transform: .identity, mask: mask)
        let masked = NotyPageContent(page: NotyPage(template: .blank), drawing: PKDrawing(strokes: [erased]))
        XCTAssertNil(NotyPageSelection.select(points: [CGPoint(x: 75, y: 0), CGPoint(x: 125, y: 20)], shape: .rectangle, filter: NotySelectionFilter(), content: masked), "Erased gaps must not select a stroke.")
        XCTAssertNotNil(NotyPageSelection.select(points: [CGPoint(x: 5, y: 0), CGPoint(x: 40, y: 20)], shape: .rectangle, filter: NotySelectionFilter(), content: masked))
    }

    @MainActor
    func testMixedSelectionMoveResizeAndDeleteUndoTogetherWithoutLosingAssets() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = store.createDocument(title: "Lasso", kind: .note, folderID: nil)
        let pageID = try XCTUnwrap(document.pages.first?.id)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }.pngData()!
        var photo = try store.addPageImage(data: data, documentID: document.id, pageID: pageID)
        photo.x = 80; photo.y = 170; photo.width = 120; photo.height = 60; photo.rotationDegrees = 30
        store.updatePageImages(documentID: document.id, pageID: pageID, images: [photo])
        let text = NotyTextBox(text: "αβ Study", x: 20, y: 100, width: 160, height: 50, fontSize: 20, isBold: true)
        store.updateTextBoxes(documentID: document.id, pageID: pageID, textBoxes: [text])
        var stroke = pencilDrawing().strokes[0]
        stroke.transform = CGAffineTransform(translationX: -52, y: -650)
        store.saveDrawing(PKDrawing(strokes: [stroke]), documentID: document.id, pageID: pageID)
        let page = try XCTUnwrap(store.documents.first?.pages.first)
        let original = NotyPageContent(page: page, drawing: store.drawing(documentID: document.id, pageID: pageID))
        let selection = try XCTUnwrap(NotyPageSelection.select(points: [CGPoint(x: 0, y: 0), CGPoint(x: 240, y: 300)], shape: .rectangle, filter: NotySelectionFilter(), content: original))
        let moved = selection.transforming(original, by: selection.translated(by: CGSize(width: 40, height: 30), within: page.canvasSize))
        XCTAssertEqual(moved.textBoxes[0].x, text.x + 40)
        XCTAssertEqual(moved.images[0].y, photo.y + 30)
        XCTAssertEqual(moved.images[0].rotationDegrees, 30)
        XCTAssertEqual(moved.drawing.strokes[0].path[0].force, stroke.path[0].force)
        XCTAssertEqual(moved.drawing.strokes[0].randomSeed, stroke.randomSeed)
        XCTAssertEqual(moved.drawing.strokes[0].transform.tx, stroke.transform.tx + 40, accuracy: 0.01)
        let resized = selection.transforming(original, by: selection.scaled(by: 1.5, within: page.canvasSize))
        XCTAssertEqual(resized.textBoxes[0].fontSize, 30)
        XCTAssertEqual(resized.textBoxes[0].paddingScale, 1.5)
        XCTAssertEqual(resized.images[0].width, 180)
        let manager = UndoManager(); manager.groupsByEvent = false
        let history = NotyPageObjectHistory()
        var applied = original.drawing
        manager.beginUndoGrouping()
        history.updateContent(store: store, undoManager: manager, documentID: document.id, pageID: pageID, content: moved, actionName: "Move selection") { applied = $0 }
        manager.endUndoGrouping()
        manager.beginUndoGrouping()
        history.updateContent(store: store, undoManager: manager, documentID: document.id, pageID: pageID, content: selection.deleting(from: moved), actionName: "Delete selection") { applied = $0 }
        manager.endUndoGrouping()
        XCTAssertTrue(store.documents[0].pages[0].textBoxes.isEmpty)
        XCTAssertTrue(applied.strokes.isEmpty)
        let photoURL = store.pageImagesDirectoryURL(documentID: document.id, pageID: pageID).appendingPathComponent(photo.fileName)
        XCTAssertEqual(try Data(contentsOf: photoURL), data)
        manager.undo()
        XCTAssertEqual(store.documents[0].pages[0].textBoxes, moved.textBoxes)
        XCTAssertEqual(store.documents[0].pages[0].images, moved.images)
        XCTAssertEqual(applied.strokes.count, 1)
        manager.undo()
        XCTAssertEqual(store.documents[0].pages[0].textBoxes, original.textBoxes)
        XCTAssertEqual(store.documents[0].pages[0].images, original.images)
        XCTAssertEqual(applied.strokes[0].transform.tx, stroke.transform.tx, accuracy: 0.01)
        XCTAssertFalse(manager.canUndo, "Each group action should create exactly one undo step.")
        manager.redo()
        XCTAssertEqual(store.documents[0].pages[0].textBoxes, moved.textBoxes)
        let reopened = NotyStore(storageDirectoryURL: root)
        XCTAssertEqual(reopened.documents[0].pages[0].images, moved.images)
        XCTAssertEqual(reopened.drawing(documentID: document.id, pageID: pageID).strokes.count, 1)
    }

    @MainActor
    func testSelectionClipboardFitsDifferentPaperPreservesCropAndRollsBackInvalidPhotos() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = store.createDocument(title: "Copy", kind: .note, folderID: nil)
        let pageID = try XCTUnwrap(document.pages.first?.id)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemPink.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.pngData()!
        var photo = try store.addPageImage(data: data, documentID: document.id, pageID: pageID)
        photo.x = 100; photo.y = 100; photo.width = 120; photo.height = 80; photo.rotationDegrees = 90
        photo.cropX = 0.1; photo.cropY = 0.2; photo.cropWidth = 0.7; photo.cropHeight = 0.6
        store.updatePageImages(documentID: document.id, pageID: pageID, images: [photo])
        let text = NotyTextBox(text: "Typed selection 学習", x: 30, y: 40, width: 180, height: 50, fontSize: 24, isUnderlined: true)
        store.updateTextBoxes(documentID: document.id, pageID: pageID, textBoxes: [text])
        let page = try XCTUnwrap(store.documents.first?.pages.first)
        var copiedStroke = pencilDrawing().strokes[0]
        copiedStroke.transform = CGAffineTransform(translationX: -32, y: -630)
        let content = NotyPageContent(page: page, drawing: PKDrawing(strokes: [copiedStroke]))
        let selection = try XCTUnwrap(NotyPageSelection.select(points: [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 300)], shape: .rectangle, filter: NotySelectionFilter(), content: content))
        let payload = try NotySelectionClipboard.payload(selection: selection, content: content, store: store, documentID: document.id, pageID: pageID)
        let roundTrip = try JSONDecoder().decode(NotySelectionPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(roundTrip.photos[0].data, data, "Copy preserves the original bytes, rather than baking in a crop.")
        let target = store.createDocument(title: "Paste", kind: .note, folderID: nil)
        let targetPage = try XCTUnwrap(target.pages.first)
        let empty = NotyPageContent(page: targetPage, drawing: PKDrawing())
        let pasted = try NotySelectionClipboard.inserting(roundTrip, into: empty, at: CGPoint(x: 100, y: 100), paper: CGSize(width: 180, height: 180), store: store, documentID: target.id, pageID: targetPage.id)
        XCTAssertLessThanOrEqual(pasted.selection.bounds.maxX, 180)
        XCTAssertLessThanOrEqual(pasted.selection.bounds.maxY, 180)
        XCTAssertEqual(pasted.content.drawing.strokes.count, 1)
        XCTAssertEqual(pasted.content.drawing.strokes[0].randomSeed, copiedStroke.randomSeed)
        XCTAssertEqual(pasted.content.drawing.strokes[0].path[0].force, copiedStroke.path[0].force)
        XCTAssertNotEqual(pasted.content.textBoxes[0].id, text.id)
        XCTAssertEqual(pasted.content.textBoxes[0].text, text.text)
        XCTAssertTrue(pasted.content.textBoxes[0].isUnderlined)
        let copied = pasted.content.images[0]
        XCTAssertNotEqual(copied.id, photo.id); XCTAssertNotEqual(copied.fileName, photo.fileName)
        XCTAssertEqual(copied.rotationDegrees, 90); XCTAssertEqual(copied.cropX, photo.cropX); XCTAssertEqual(copied.cropHeight, photo.cropHeight)
        let directory = store.pageImagesDirectoryURL(documentID: target.id, pageID: targetPage.id)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(copied.fileName)), data)
        let duplicate = try NotySelectionClipboard.inserting(roundTrip, into: content, at: CGPoint(x: 240, y: 300), paper: page.canvasSize, store: store, documentID: document.id, pageID: pageID)
        let recoveredDrawing = try PKDrawing(data: duplicate.content.drawing.dataRepresentation())
        XCTAssertEqual(recoveredDrawing.strokes.count, 2, "Duplicated ink must retain both independent strokes after encoding.")
        XCTAssertEqual(recoveredDrawing.strokes[0].transform.tx, copiedStroke.transform.tx, accuracy: 0.01)
        XCTAssertNotEqual(recoveredDrawing.strokes[1].transform.tx, copiedStroke.transform.tx)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var invalid = roundTrip
        invalid.photos.append(NotySelectionPayload.Photo(object: photo, data: Data("Not an image".utf8)))
        XCTAssertThrowsError(try NotySelectionClipboard.inserting(invalid, into: empty, at: .zero, paper: targetPage.canvasSize, store: store, documentID: target.id, pageID: targetPage.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before, "A rejected paste must remove staged files.")
        XCTAssertTrue(store.documents.first(where: { $0.id == target.id })!.pages[0].images.isEmpty)
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

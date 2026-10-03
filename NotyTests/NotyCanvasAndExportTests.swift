import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import Noty

final class NotyCanvasAndExportTests: XCTestCase {
    func testContinuousLayoutTracksMixedPagesAtDifferentZoomLevels() {
        let pages = [NotyPage(sizePreset: .a4), NotyPage(sizePreset: .letter, orientation: .landscape), NotyPage(sizePreset: .square)]
        for zoom: CGFloat in [0.65, 1, 2.5] {
            let layout = NotyPageFlowLayout(pages: pages, viewport: CGSize(width: 1000, height: 800), zoom: zoom)
            XCTAssertEqual(layout.items.count, 3)
            for index in layout.items.indices {
                let item = layout.items[index]
                XCTAssertEqual(layout.pageID(at: (item.minY + item.maxY) / 2), item.id)
                if index > 0 { XCTAssertEqual(item.minY - layout.items[index - 1].maxY, NotyPageFlowLayout.spacing, accuracy: 0.01) }
            }
            XCTAssertEqual(layout.pageID(at: -500), pages.first?.id)
            XCTAssertEqual(layout.pageID(at: layout.contentHeight + 500), pages.last?.id)
            XCTAssertGreaterThan(layout.contentHeight, 800)
        }
    }

    func testBoardExpandsTowardEveryEdgeWithoutAFixedLimit() {
        let canvas = CGSize(width: 4096, height: 4096)
        XCTAssertFalse(NotyCanvasExpansion.needed(visible: CGRect(x: 1600, y: 1600, width: 800, height: 600), canvas: canvas).isValid)
        let edges = [CGRect(x: 0, y: 1600, width: 800, height: 600), CGRect(x: 1600, y: 0, width: 800, height: 600),
                     CGRect(x: 3300, y: 1600, width: 800, height: 600), CGRect(x: 1600, y: 3500, width: 800, height: 600)]
        for visible in edges { XCTAssertTrue(NotyCanvasExpansion.needed(visible: visible, canvas: canvas).isValid) }
        var size = canvas
        for _ in 0..<50 { size = NotyCanvasExpansion(right: 2048, bottom: 2048).expanding(size) }
        XCTAssertEqual(size.width, 106496)
        XCTAssertFalse(NotyCanvasExpansion(left: -1).isValid)
        XCTAssertFalse(NotyCanvasExpansion(top: .infinity).isValid)
    }

    @MainActor
    func testWhiteboardGrowthPreservesInkObjectsAndViewportAfterReopening() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        let document = store.createDocument(title: "Ideas", kind: .whiteboard, folderID: nil)
        store.ensureNotebookCover(documentID: document.id)
        let page = try XCTUnwrap(store.documents.first?.pages.first)
        XCTAssertEqual(store.documents.first?.pages.count, 1)
        XCTAssertFalse(page.isCover)
        XCTAssertEqual(page.canvasSize, CGSize(width: 4096, height: 4096))
        store.updateTextBoxes(documentID: document.id, pageID: page.id, textBoxes: [NotyTextBox(text: "Concept", x: 1900, y: 1800)])
        let ink = PKDrawing(strokes: [stroke(from: CGPoint(x: 1800, y: 1900), to: CGPoint(x: 2000, y: 1900))])
        store.saveDrawing(ink, documentID: document.id, pageID: page.id)
        store.updateWhiteboardViewport(documentID: document.id, pageID: page.id, center: CGPoint(x: 2050, y: 2000))
        let expansion = NotyCanvasExpansion(left: 2048, top: 2048, right: 2048)
        XCTAssertTrue(store.expandWhiteboard(documentID: document.id, pageID: page.id, expansion: expansion))
        let updated = try XCTUnwrap(store.documents.first?.pages.first)
        XCTAssertEqual(updated.canvasSize, CGSize(width: 8192, height: 6144))
        XCTAssertEqual(updated.textBoxes.first?.x, 3948)
        XCTAssertEqual(updated.textBoxes.first?.y, 3848)
        XCTAssertEqual(updated.viewportCenterX, 4098)
        XCTAssertEqual(updated.viewportCenterY, 4048)
        let movedInk = store.drawing(documentID: document.id, pageID: page.id)
        XCTAssertEqual(movedInk.bounds.minX - ink.bounds.minX, 2048, accuracy: 0.01)
        XCTAssertEqual(movedInk.bounds.minY - ink.bounds.minY, 2048, accuracy: 0.01)
        let reopened = NotyStore(storageDirectoryURL: root)
        XCTAssertEqual(reopened.documents.first?.kind, .whiteboard)
        XCTAssertEqual(reopened.documents.first?.pages.first, updated)
    }

    @MainActor
    func testSelectedPDFUsesOnlyChosenPagesInNotebookOrder() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        let document = store.createDocument(title: "Selection", kind: .note, folderID: nil)
        let first = try XCTUnwrap(document.pages.first)
        let second = try XCTUnwrap(store.addPage(documentID: document.id, after: first.id, template: .grid, format: NotyPage(sizePreset: .a5)))
        let third = try XCTUnwrap(store.addPage(documentID: document.id, after: second.id, template: .blank, format: NotyPage(sizePreset: .square)))
        for (page, text) in [(first, "Alpha"), (second, "Beta"), (third, "Gamma")] {
            store.updateTextBoxes(documentID: document.id, pageID: page.id, textBoxes: [NotyTextBox(text: text, width: 200)])
        }
        store.movePage(documentID: document.id, from: IndexSet(integer: 2), to: 0)
        let url = try NotyExportService.exportPDF(documentID: document.id, store: store, selectedPageIDs: [first.id, third.id])
        defer { try? FileManager.default.removeItem(at: url) }
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Gamma") == true)
        XCTAssertTrue(pdf.page(at: 1)?.string?.contains("Alpha") == true)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, third.canvasSize)
        XCTAssertFalse(pdf.string?.contains("Beta") == true)
        XCTAssertThrowsError(try NotyExportService.exportPDF(documentID: document.id, store: store, selectedPageIDs: []))
        XCTAssertThrowsError(try NotyExportService.exportPDF(documentID: document.id, store: store, selectedPageIDs: [UUID()]))
    }

    @MainActor
    func testWhiteboardExportCropsToContentInsteadOfEmptyExpandedSpace() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        let document = store.createDocument(title: "Board export", kind: .whiteboard, folderID: nil)
        let page = try XCTUnwrap(document.pages.first)
        XCTAssertEqual(NotyExportService.renderBounds(page, documentID: document.id, store: store).size, CGSize(width: 612, height: 792))
        XCTAssertTrue(store.expandWhiteboard(documentID: document.id, pageID: page.id, expansion: NotyCanvasExpansion(right: 8192, bottom: 8192)))
        store.updateTextBoxes(documentID: document.id, pageID: page.id, textBoxes: [NotyTextBox(text: "Remote idea", x: 5000, y: 6000, width: 300, height: 120)])
        let updated = try XCTUnwrap(store.documents.first?.pages.first)
        let crop = NotyExportService.renderBounds(updated, documentID: document.id, store: store)
        XCTAssertEqual(crop, CGRect(x: 4952, y: 5952, width: 396, height: 216))
        let url = try NotyExportService.exportPDF(documentID: document.id, store: store)
        defer { try? FileManager.default.removeItem(at: url) }
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, crop.size)
        XCTAssertTrue(pdf.string?.contains("Remote idea") == true)
    }

    @MainActor
    func testObjectUndoAndRedoRemainAlignedAfterWhiteboardGrowth() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        let document = store.createDocument(title: "Undo board", kind: .whiteboard, folderID: nil)
        let page = try XCTUnwrap(document.pages.first)
        let history = NotyPageObjectHistory(), undo = UndoManager()
        undo.groupsByEvent = false
        let original = NotyTextBox(text: "Before", x: 2000, y: 1900)
        store.updateTextBoxes(documentID: document.id, pageID: page.id, textBoxes: [original])
        var changed = original; changed.text = "After"; changed.x = 2200
        undo.beginUndoGrouping()
        history.updateTextBoxes(store: store, undoManager: undo, documentID: document.id, pageID: page.id, textBoxes: [changed])
        undo.endUndoGrouping()
        XCTAssertTrue(store.expandWhiteboard(documentID: document.id, pageID: page.id, expansion: NotyCanvasExpansion(left: 2048)))
        undo.undo()
        XCTAssertEqual(store.documents.first?.pages.first?.textBoxes.first?.text, "Before")
        XCTAssertEqual(store.documents.first?.pages.first?.textBoxes.first?.x, 4048)
        XCTAssertTrue(store.expandWhiteboard(documentID: document.id, pageID: page.id, expansion: NotyCanvasExpansion(top: 2048)))
        undo.redo()
        XCTAssertEqual(store.documents.first?.pages.first?.textBoxes.first?.text, "After")
        XCTAssertEqual(store.documents.first?.pages.first?.textBoxes.first?.x, 4248)
        XCTAssertEqual(store.documents.first?.pages.first?.textBoxes.first?.y, 3948)
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("NotyCanvas-\(UUID())") }
    private func stroke(from: CGPoint, to: CGPoint) -> PKStroke {
        let points = [from, to].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.02, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))
    }
}

extension NotyCanvasAndExportTests {
    @MainActor
    func testBrowserInkRoundTripsAndIsConsumedExactlyOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        let document = store.createDocument(title: "Web ink", folderID: nil)
        var manifest = store.currentManifest()
        manifest.documents[0].pages[0].webStrokes = [NotyWebStroke(id: UUID(), color: "202020", width: 3, points: [NotyWebPoint(x: 10, y: 20), NotyWebPoint(x: 90, y: 80)])]
        XCTAssertTrue(store.applyCloudManifest(manifest))
        let pageID = try XCTUnwrap(store.documents.first?.pages.first?.id)
        let drawing = store.drawing(documentID: document.id, pageID: pageID)
        XCTAssertEqual(drawing.strokes.count, 1)
        store.saveDrawing(drawing, documentID: document.id, pageID: pageID)
        XCTAssertNil(store.documents[0].pages[0].webStrokes)
        XCTAssertEqual(store.drawing(documentID: document.id, pageID: pageID).strokes.count, 1)
        try store.refreshCloudInkPreviews(documentID: document.id)
        let preview = store.assetDirectoryURL(documentID: document.id).appendingPathComponent("InkPreviews/\(pageID.uuidString).png")
        XCTAssertNotNil(UIImage(contentsOfFile: preview.path))
    }
}

import PDFKit
import UIKit
import XCTest
@testable import Noty

final class NotyImportantFeaturesTests: XCTestCase {
    @MainActor
    func testBookmarkRichTextAndImagePersistAcrossRelaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotyImportantFeatures-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NotyStore(storageDirectoryURL: root)
        let document = store.createDocument(title: "Feature note", kind: .note, folderID: nil)
        let pageID = try XCTUnwrap(document.pages.first?.id)

        let styledText = NotyTextBox(
            text: "Styled text",
            x: 50,
            y: 70,
            width: 300,
            height: 100,
            fontSize: 22,
            fontName: "Georgia",
            isBold: true,
            isItalic: true,
            isUnderlined: true,
            colorHex: "2383E2",
            alignment: .center
        )
        store.updateTextBoxes(documentID: document.id, pageID: pageID, textBoxes: [styledText])
        store.updatePageBookmark(documentID: document.id, pageID: pageID, isBookmarked: true)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(x: 20, y: 20, width: 80, height: 40))
        }
        let data = try XCTUnwrap(image.pngData())
        let pageImage = try store.addPageImage(data: data, documentID: document.id, pageID: pageID)
        XCTAssertNotNil(store.pageImage(documentID: document.id, pageID: pageID, image: pageImage))

        let reopened = NotyStore(storageDirectoryURL: root)
        let reopenedDocument = try XCTUnwrap(reopened.documents.first(where: { $0.id == document.id }))
        let reopenedPage = try XCTUnwrap(reopenedDocument.pages.first)
        let reopenedText = try XCTUnwrap(reopenedPage.textBoxes.first)

        XCTAssertTrue(reopenedPage.isBookmarked)
        XCTAssertEqual(reopenedText.fontName, "Georgia")
        XCTAssertTrue(reopenedText.isBold)
        XCTAssertTrue(reopenedText.isItalic)
        XCTAssertTrue(reopenedText.isUnderlined)
        XCTAssertEqual(reopenedText.colorHex, "2383E2")
        XCTAssertEqual(reopenedText.alignment, .center)
        let reopenedImage = try XCTUnwrap(reopenedPage.images.first)
        XCTAssertNotNil(reopened.pageImage(documentID: document.id, pageID: pageID, image: reopenedImage))

        let pdfURL = try NotyExportService.exportPDF(documentID: document.id, store: reopened)
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertEqual(pdf.pageCount, 1)
    }

    @MainActor
    func testTrashRestoresDocumentAndAssets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotyTrashRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NotyStore(storageDirectoryURL: root)
        let document = store.createDocument(title: "Recover me", kind: .book, folderID: nil)
        let pageID = try XCTUnwrap(document.pages.first?.id)
        store.updateTextBoxes(
            documentID: document.id,
            pageID: pageID,
            textBoxes: [NotyTextBox(text: "TRASH_SENTINEL")]
        )

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40))
        let data = try XCTUnwrap(renderer.image { context in
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }.pngData())
        _ = try store.addPageImage(data: data, documentID: document.id, pageID: pageID)

        store.deleteDocument(id: document.id)
        XCTAssertFalse(store.documents.contains(where: { $0.id == document.id }))
        XCTAssertEqual(store.trashItems.first?.document.title, "Recover me")

        let reopened = NotyStore(storageDirectoryURL: root)
        XCTAssertEqual(reopened.trashItems.first?.id, document.id)
        reopened.restoreTrashedDocument(id: document.id)

        let restored = try XCTUnwrap(reopened.documents.first(where: { $0.id == document.id }))
        XCTAssertEqual(restored.pages.first?.textBoxes.first?.text, "TRASH_SENTINEL")
        let restoredImage = try XCTUnwrap(restored.pages.first?.images.first)
        XCTAssertNotNil(reopened.pageImage(documentID: document.id, pageID: pageID, image: restoredImage))
        XCTAssertTrue(reopened.trashItems.isEmpty)
    }

    func testLegacyPageAndTextJSONDecodeWithSafeDefaults() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "template": "blank",
          "textBoxes": [{
            "id": "22222222-2222-2222-2222-222222222222",
            "text": "Old note",
            "x": 24,
            "y": 24,
            "width": 200,
            "height": 80,
            "fontSize": 16
          }]
        }
        """
        let page = try JSONDecoder().decode(NotyPage.self, from: Data(json.utf8))
        XCTAssertFalse(page.isBookmarked)
        XCTAssertTrue(page.images.isEmpty)
        let text = try XCTUnwrap(page.textBoxes.first)
        XCTAssertFalse(text.isBold)
        XCTAssertFalse(text.isItalic)
        XCTAssertFalse(text.isUnderlined)
        XCTAssertEqual(text.colorHex, "37352F")
        XCTAssertEqual(text.alignment, .leading)
    }
}

import PDFKit
import ImageIO
import UniformTypeIdentifiers
import UIKit
import SwiftUI
import XCTest
@testable import Noty

final class NotyImportantFeaturesTests: XCTestCase {
    @MainActor
    func testTextEditorFocusUnicodeAndUnderline() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        var typed = ""
        let box = NotyTextBox(text: "", fontSize: 22, isUnderlined: true)
        let host = UIHostingController(rootView: PageTextEditor(text: Binding(get: { typed }, set: { typed = $0 }), box: box, scale: 1).frame(width: 300, height: 120))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func editor(in view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            for child in view.subviews { if let result = editor(in: child) { return result } }
            return nil
        }
        let input = try XCTUnwrap(editor(in: host.view))
        XCTAssertTrue(input.isFirstResponder, "Adding a text box should focus its native text input.")
        XCTAssertEqual(input.backgroundColor, .clear, "Editing must keep the notebook paper visible in either appearance.")
        input.insertText("Biology · αβ · 学習 🧠")
        XCTAssertEqual(typed, "Biology · αβ · 学習 🧠")
        XCTAssertEqual(input.typingAttributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual((input.typingAttributes[.font] as? UIFont)?.pointSize, 22)
    }

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
    func testPaperFormatPersistsAndPDFUsesPageDimensions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotyPaperFormat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NotyStore(storageDirectoryURL: root)
        let document = store.createDocument(title: "Paper test", kind: .note, folderID: nil)
        let pageID = try XCTUnwrap(document.pages.first?.id)
        store.updateTextBoxes(
            documentID: document.id,
            pageID: pageID,
            textBoxes: [NotyTextBox(text: "Keep me in bounds", x: 40, y: 50, width: 220, height: 90)]
        )
        store.updatePageFormat(
            documentID: document.id,
            pageID: pageID,
            template: .smallGrid,
            paperColorHex: "FFF3B0",
            sizePreset: .a4,
            orientation: .landscape
        )

        let reopened = NotyStore(storageDirectoryURL: root)
        let page = try XCTUnwrap(reopened.documents.first(where: { $0.id == document.id })?.pages.first)
        XCTAssertEqual(page.template, .smallGrid)
        XCTAssertEqual(page.paperColorHex, "FFF3B0")
        XCTAssertEqual(page.sizePreset, .a4)
        XCTAssertEqual(page.orientation, .landscape)
        XCTAssertEqual(page.canvasSize.width, 842, accuracy: 0.01)
        XCTAssertEqual(page.canvasSize.height, 595, accuracy: 0.01)
        let box = try XCTUnwrap(page.textBoxes.first)
        XCTAssertGreaterThanOrEqual(box.x, 0)
        XCTAssertGreaterThanOrEqual(box.y, 0)
        XCTAssertLessThanOrEqual(box.x + box.width, Double(page.canvasSize.width) + 0.01)
        XCTAssertLessThanOrEqual(box.y + box.height, Double(page.canvasSize.height) + 0.01)

        let pdfURL = try NotyExportService.exportPDF(documentID: document.id, store: reopened)
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL))
        let bounds = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 842, accuracy: 1)
        XCTAssertEqual(bounds.height, 595, accuracy: 1)
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
        XCTAssertEqual(page.template, .blank)
        XCTAssertEqual(page.paperColorHex, "FFFFFF")
        XCTAssertEqual(page.sizePreset, .letter)
        XCTAssertEqual(page.orientation, .portrait)
        XCTAssertEqual(page.canvasSize.width, 612, accuracy: 0.01)
        XCTAssertEqual(page.canvasSize.height, 792, accuracy: 0.01)
        let text = try XCTUnwrap(page.textBoxes.first)
        XCTAssertFalse(text.isBold)
        XCTAssertFalse(text.isItalic)
        XCTAssertFalse(text.isUnderlined)
        XCTAssertEqual(text.colorHex, "37352F")
        XCTAssertEqual(text.alignment, .leading)
    }
    @MainActor
    func testNotebookDesignAndStudyCardsSurviveRelaunchAndDuplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotyDesign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        let firstPage = NotyPage(template: .weeklyPlanner, paperColorHex: "FFFDF5", sizePreset: .a5, orientation: .landscape)
        let cover = NotyNotebookCover(style: .linen, colorHex: "497B76")
        let book = store.createDocument(title: "Biology", kind: .book, folderID: nil, firstPage: firstPage, cover: cover)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 64)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 64))
        }
        try store.updateCover(documentID: book.id, cover: cover, imageData: XCTUnwrap(image.pngData()))
        store.updateStudyCards(documentID: book.id, cards: [NotyStudyCard(question: "What is mitosis?", answer: "Cell division")])
        let next = try XCTUnwrap(store.addPage(documentID: book.id, after: firstPage.id, template: firstPage.template))
        XCTAssertEqual(next.paperColorHex, "FFFDF5")
        XCTAssertEqual(next.sizePreset, .a5)
        XCTAssertEqual(next.orientation, .landscape)
        let custom = NotyPage(template: .music, paperColorHex: "EAF4FF", sizePreset: .a4)
        let music = try XCTUnwrap(store.addPage(documentID: book.id, after: next.id, template: custom.template, format: custom))
        XCTAssertEqual(music.template, .music)
        XCTAssertEqual(music.sizePreset, .a4)
        XCTAssertEqual(music.paperColorHex, "EAF4FF")
        let duplicate = try store.duplicateDocument(id: book.id)
        let reopened = NotyStore(storageDirectoryURL: root)
        let saved = try XCTUnwrap(reopened.documents.first { $0.id == book.id })
        let copied = try XCTUnwrap(reopened.documents.first { $0.id == duplicate.id })
        XCTAssertEqual(saved.cover?.style, .linen)
        XCTAssertNotNil(reopened.coverImage(for: saved))
        XCTAssertNotNil(reopened.coverImage(for: copied))
        XCTAssertEqual(copied.studyCards?.first?.answer, "Cell division")
        XCTAssertEqual(saved.pages.count, 4)
        XCTAssertTrue(saved.pages[0].isCover)
        let pdf = try XCTUnwrap(PDFDocument(url: NotyExportService.exportPDF(documentID: book.id, store: reopened)))
        XCTAssertEqual(pdf.pageCount, 4)
        XCTAssertTrue(pdf.page(at: 1)?.string?.contains("WEEK OF") == true)
    }

    func testLegacyDocumentDecodesWithoutCoverOrCards() throws {
        let document = NotyDocument(title: "Legacy")
        let encoded = try JSONEncoder().encode(document)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "cover"); json.removeValue(forKey: "studyCards")
        let decoded = try JSONDecoder().decode(NotyDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.cover)
        XCTAssertNil(decoded.studyCards)
        XCTAssertEqual(decoded.title, "Legacy")
    }

    @MainActor
    func testPhotoCropIsPersistentAndPreservesOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotyCrop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        let book = store.createDocument(title: "Crop", kind: .book, folderID: nil)
        let page = try XCTUnwrap(book.pages.first)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }
        var photo = try store.addPageImage(data: XCTUnwrap(original.pngData()), documentID: book.id, pageID: page.id)
        photo.cropX = 0.5; photo.cropY = 0; photo.cropWidth = 0.5; photo.cropHeight = 1
        store.updatePageImages(documentID: book.id, pageID: page.id, images: [photo])
        let reopened = NotyStore(storageDirectoryURL: root)
        let saved = try XCTUnwrap(reopened.documents.first?.pages.first?.images.first)
        let cropped = try XCTUnwrap(reopened.pageImage(documentID: book.id, pageID: page.id, image: saved))
        XCTAssertEqual(cropped.size.width / cropped.size.height, 1, accuracy: 0.01)
        let retained = try XCTUnwrap(reopened.originalPageImage(documentID: book.id, pageID: page.id, image: saved))
        XCTAssertEqual(retained.size.width / retained.size.height, 2, accuracy: 0.01)
        let exported = try NotyExportService.exportPageImage(documentID: book.id, pageID: page.id, store: reopened)
        XCTAssertNotNil(UIImage(contentsOfFile: exported.path))
    }

    @MainActor
    func testCoverMigrationKeepsWritingPagesAndCoverFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotyCoverMigration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        let original = store.createDocument(title: "Older notebook", kind: .book, folderID: nil, firstPage: NotyPage(template: .cornell, paperColorHex: "FFFDF5", sizePreset: .a5))
        let writing = try XCTUnwrap(original.pages.first)
        store.updateTextBoxes(documentID: original.id, pageID: writing.id, textBoxes: [NotyTextBox(text: "Keep my notes")])
        store.ensureNotebookCover(documentID: original.id)
        store.ensureNotebookCover(documentID: original.id)
        let migrated = try XCTUnwrap(store.documents.first)
        XCTAssertEqual(migrated.pages.count, 2)
        let cover = migrated.pages[0]
        XCTAssertTrue(cover.isCover)
        XCTAssertEqual(cover.sizePreset, .a5)
        XCTAssertEqual(migrated.pages[1].id, writing.id)
        XCTAssertEqual(migrated.pages[1].textBoxes.first?.text, "Keep my notes")
        store.deletePage(documentID: original.id, pageID: cover.id)
        XCTAssertNil(store.duplicatePage(documentID: original.id, pageID: cover.id))
        store.movePage(documentID: original.id, from: IndexSet(integer: 0), to: 2)
        store.movePage(documentID: original.id, from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(store.documents[0].pages[0].id, cover.id)
        let new = try XCTUnwrap(store.addPage(documentID: original.id, after: cover.id, template: .cornell))
        XCTAssertEqual(new.paperColorHex, "FFFDF5")
        XCTAssertEqual(new.sizePreset, .a5)
        XCTAssertFalse(new.isCover)
        let reopened = NotyStore(storageDirectoryURL: root)
        XCTAssertTrue(reopened.documents[0].pages[0].isCover)
        let pdf = try XCTUnwrap(PDFDocument(url: NotyExportService.exportPDF(documentID: original.id, store: reopened)))
        XCTAssertEqual(pdf.pageCount, 3)
        XCTAssertTrue(pdf.page(at: 2)?.string?.contains("Keep my notes") == true)
    }

    @MainActor
    func testFolderDesignPersistsAndLegacyFoldersRemainReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotyFolders-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        store.createFolder(name: "Science", parentID: nil, design: NotyNotebookCover(style: .linen, colorHex: "497B76"), symbol: "atom")
        let id = try XCTUnwrap(store.folders.first?.id)
        store.updateFolderDesign(id: id, design: NotyNotebookCover(style: .geometric, colorHex: "5267A9"), symbol: "graduationcap")
        let reopened = NotyStore(storageDirectoryURL: root)
        XCTAssertEqual(reopened.folders[0].design?.style, .geometric)
        XCTAssertEqual(reopened.folders[0].design?.colorHex, "5267A9")
        XCTAssertEqual(reopened.folders[0].symbol, "graduationcap")
        let legacy = try JSONDecoder().decode(NotyFolder.self, from: Data("{\"id\":\"11111111-1111-1111-1111-111111111111\",\"name\":\"Old folder\"}".utf8))
        XCTAssertNil(legacy.design)
        XCTAssertEqual(legacy.name, "Old folder")
    }

    @MainActor
    func testTextAndPhotoEditsCanUndoAndRedoWithoutLosingPhotoData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotyUndo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        let book = store.createDocument(title: "Undo", kind: .book, folderID: nil)
        let page = try XCTUnwrap(book.pages.first)
        let undo = UndoManager(); undo.groupsByEvent = false
        let history = NotyPageObjectHistory()
        undo.beginUndoGrouping()
        history.updateTextBoxes(store: store, undoManager: undo, documentID: book.id, pageID: page.id, textBoxes: [NotyTextBox(text: "A paragraph")])
        undo.endUndoGrouping()
        undo.undo()
        XCTAssertTrue(store.documents[0].pages[0].textBoxes.isEmpty)
        undo.redo()
        XCTAssertEqual(store.documents[0].pages[0].textBoxes.first?.text, "A paragraph")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40)).image { ctx in UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40)) }
        undo.beginUndoGrouping()
        let photo = try history.addImage(store: store, undoManager: undo, data: XCTUnwrap(image.pngData()), documentID: book.id, pageID: page.id)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        history.updateImages(store: store, undoManager: undo, documentID: book.id, pageID: page.id, images: [])
        undo.endUndoGrouping()
        undo.undo()
        XCTAssertEqual(store.documents[0].pages[0].images.first?.id, photo.id)
        XCTAssertNotNil(store.pageImage(documentID: book.id, pageID: page.id, image: photo))
        undo.redo()
        XCTAssertTrue(store.documents[0].pages[0].images.isEmpty)
        undo.removeAllActions()
        store.removeUnusedPhotoAssets(documentID: book.id)
        XCTAssertNil(store.originalPageImage(documentID: book.id, pageID: page.id, image: photo))
    }

    @MainActor
    func testRotatedPhotoKeepsOriginalDataAndDisplaysUpright() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotyPhotoOrientation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        let book = store.createDocument(title: "Photos", kind: .book, folderID: nil)
        let page = try XCTUnwrap(book.pages.first)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let raw = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { ctx in UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100)) }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(raw.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let originalData = data as Data
        let photo = try store.addPageImage(data: originalData, documentID: book.id, pageID: page.id)
        XCTAssertEqual(photo.width / photo.height, 0.5, accuracy: 0.01)
        let rendered = try XCTUnwrap(store.pageImage(documentID: book.id, pageID: page.id, image: photo))
        XCTAssertEqual(rendered.imageOrientation, .up)
        XCTAssertEqual(rendered.size.width / rendered.size.height, 0.5, accuracy: 0.01)
        let original = try XCTUnwrap(store.originalPageImage(documentID: book.id, pageID: page.id, image: photo))
        XCTAssertEqual(original.size.width / original.size.height, 0.5, accuracy: 0.01)
        let file = store.pageImagesDirectoryURL(documentID: book.id, pageID: page.id).appendingPathComponent(photo.fileName)
        XCTAssertEqual(try Data(contentsOf: file), originalData)
    }

}

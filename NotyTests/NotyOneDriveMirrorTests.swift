import PDFKit
import XCTest
@testable import Noty

final class NotyOneDriveMirrorTests: XCTestCase {
    @MainActor
    func testFilesProviderMirrorKeepsAnAnnotatedPDFAfterDocumentDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotyOneDriveQA-\(UUID().uuidString)", isDirectory: true)
        let libraryURL = root.appendingPathComponent("library", isDirectory: true)
        let selectedFolderURL = root.appendingPathComponent("selected-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedFolderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = OneDriveService()
        defer { service.disconnect() }
        let store = NotyStore(storageDirectoryURL: libraryURL)
        let document = store.createDocument(title: "Class notes", kind: .book, folderID: nil)
        let pageID = try XCTUnwrap(document.pages.first?.id)
        store.updateTextBoxes(
            documentID: document.id,
            pageID: pageID,
            textBoxes: [NotyTextBox(text: "CLOUD_PDF_SENTINEL", x: 72, y: 120)]
        )

        try service.configureMirrorFolder(folderURL: selectedFolderURL)
        await service.syncAllPDFs(store: store)
        XCTAssertNil(service.lastError, service.syncStatus)

        let pdfURLs = try FileManager.default.contentsOfDirectory(
            at: selectedFolderURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "pdf" }
        let exportedURL = try XCTUnwrap(pdfURLs.onlyElement)
        let exportedPDF = try XCTUnwrap(PDFDocument(url: exportedURL))
        XCTAssertEqual(exportedPDF.pageCount, 1)
        let extractedText = try XCTUnwrap(exportedPDF.page(at: 0)?.string)
        XCTAssertTrue(String(extractedText.filter(\.isLetter)).contains("CLOUDPDFSENTINEL"))

        store.deleteDocument(id: document.id)
        await service.syncAllPDFs(store: store)
        XCTAssertNil(service.lastError, service.syncStatus)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))
        XCTAssertTrue(service.syncStatus.contains("remain"), service.syncStatus)
    }
}

private extension Collection {
    var onlyElement: Element? { count == 1 ? first : nil }
}

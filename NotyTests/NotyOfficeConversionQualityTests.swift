import CoreGraphics
import PDFKit
import XCTest
@testable import Noty

final class NotyOfficeConversionQualityTests: XCTestCase {
    @MainActor
    func testDOCXKeepsTableTextAndEmbeddedGraphicInRichPDF() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotyDOCXQualityQA-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "noty-rich",
            withExtension: "docx",
            subdirectory: "Fixtures"
        ) ?? Bundle(for: Self.self).url(forResource: "noty-rich", withExtension: "docx"))
        let store = NotyStore(storageDirectoryURL: root)
        let document = try await store.importDocument(from: fixture, folderID: nil)
        defer { try? FileManager.default.removeItem(at: store.userImportsDirectoryURL(documentID: document.id)) }
        let pdf = try XCTUnwrap(store.sourcePDF(documentID: document.id))
        XCTAssertGreaterThan(pdf.pageCount, 0)
        let paper = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(paper.width, 612, accuracy: 1, "Word's Letter page should export at its physical paper size.")
        XCTAssertEqual(paper.height, 792, accuracy: 1)
        let allText = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: " ")
        XCTAssertTrue(allText.contains("Noty rich conversion fixture"), allText)
        XCTAssertTrue(allText.contains("Biology"), allText)
        XCTAssertTrue(allText.contains("Cell structure"), allText)
        XCTAssertFalse(store.lastOperationMessage?.localizedCaseInsensitiveContains("simplified") == true)

        let bluePixels = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
            .reduce(0) { $0 + countBluePixels(on: $1) }
        XCTAssertGreaterThan(bluePixels, 1_000, "The embedded colored graphic should survive DOCX conversion.")
    }

    private func countBluePixels(on page: PDFPage) -> Int {
        let width = 612
        let height = 792
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return 0 }
        context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: context)
        return stride(from: 0, to: rgba.count, by: 4).reduce(0) { count, offset in
            let red = Int(rgba[offset])
            let green = Int(rgba[offset + 1])
            let blue = Int(rgba[offset + 2])
            return count + (blue > 150 && blue > red * 3 / 2 && blue > green * 11 / 10 ? 1 : 0)
        }
    }
}

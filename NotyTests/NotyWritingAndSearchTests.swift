import PencilKit
import UIKit
import XCTest
@testable import Noty

final class NotyWritingAndSearchTests: XCTestCase {
    func testShakyLineAndRotatedRectangleBecomePreciseShapes() throws {
        let line = (0...40).map { i in CGPoint(x: 40 + CGFloat(i) * 4, y: 80 + sin(CGFloat(i)) * 2) }
        let straight = try XCTUnwrap(NotyShapeRecognition.recognize(line))
        XCTAssertEqual(straight.kind, .line)
        XCTAssertEqual(straight.points.count, 2)

        let rectangle = polygon([CGPoint(x: 40, y: 40), CGPoint(x: 220, y: 40), CGPoint(x: 220, y: 160), CGPoint(x: 40, y: 160), CGPoint(x: 40, y: 40)])
            .map { point in CGPoint(x: point.x * cos(0.35) - point.y * sin(0.35), y: point.x * sin(0.35) + point.y * cos(0.35)) }
        let fitted = try XCTUnwrap(NotyShapeRecognition.recognize(rectangle))
        XCTAssertEqual(fitted.kind, .rectangle)
        XCTAssertEqual(fitted.points.first, fitted.points.last)
        let a = fitted.points[0], b = fitted.points[1], c = fitted.points[2]
        XCTAssertEqual((a.x - b.x) * (c.x - b.x) + (a.y - b.y) * (c.y - b.y), 0, accuracy: 0.01)
        let stroke = fitted.stroke(ink: PKInk(.pen, color: .blue), width: 3)
        XCTAssertEqual(stroke.ink.color, .blue)
        XCTAssertEqual(stroke.path[0].size.width, 3)
    }

    func testEllipseTriangleAndOrdinaryWritingAreDistinguished() throws {
        let oval = (0...90).map { i -> CGPoint in
            let theta = CGFloat(i) / 90 * .pi * 2
            return CGPoint(x: 180 + 110 * cos(theta) + sin(theta * 5), y: 160 + 70 * sin(theta))
        }
        XCTAssertEqual(try XCTUnwrap(NotyShapeRecognition.recognize(oval)).kind, .ellipse)
        let triangle = polygon([CGPoint(x: 150, y: 30), CGPoint(x: 260, y: 210), CGPoint(x: 40, y: 210), CGPoint(x: 150, y: 30)])
        XCTAssertEqual(try XCTUnwrap(NotyShapeRecognition.recognize(triangle)).kind, .triangle)
        let scribble = (0...80).map { i in CGPoint(x: 40 + CGFloat(i) * 3, y: 130 + 45 * sin(CGFloat(i) * 0.3)) }
        XCTAssertNil(NotyShapeRecognition.recognize(scribble))
        XCTAssertNil(NotyShapeRecognition.recognize(Array(oval.prefix(45))))
        XCTAssertNil(NotyShapeRecognition.recognize([CGPoint(x: 4, y: 4), CGPoint(x: 8, y: 9)]))
    }

    @MainActor
    func testSearchFindsEveryMatchingPageAndInvalidatesErasedHandwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotySearch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        let document = store.createDocument(title: "Biology", kind: .note, folderID: nil)
        let first = try XCTUnwrap(document.pages.first?.id)
        store.addPage(documentID: document.id, after: first, template: .blank)
        let second = try XCTUnwrap(store.documents.first?.pages.last?.id)
        store.updateTextBoxes(documentID: document.id, pageID: first, textBoxes: [NotyTextBox(text: "Café cells and membranes")])
        store.updateTextBoxes(documentID: document.id, pageID: second, textBoxes: [NotyTextBox(text: "Cells divide by mitosis")])
        XCTAssertEqual(Set(store.search(query: "CELLS").compactMap(\.pageID)), [first, second])
        XCTAssertEqual(store.search(query: "cafe membranes").first?.pageID, first)

        let sidecar = store.handwritingTextURL(documentID: document.id, pageID: second)
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Handwritten chloroplast".utf8).write(to: sidecar)
        XCTAssertEqual(store.search(query: "chloroplast").first?.pageID, second)
        store.saveDrawing(PKDrawing(strokes: [stroke([CGPoint(x: 40, y: 40), CGPoint(x: 200, y: 100)])]), documentID: document.id, pageID: second)
        XCTAssertTrue(store.search(query: "chloroplast").isEmpty, "Old OCR must stop matching immediately when ink changes.")
        store.saveDrawing(PKDrawing(), documentID: document.id, pageID: second)
        XCTAssertEqual(store.recognizedHandwriting(documentID: document.id, pageID: second), "")
    }

    @MainActor
    func testInterruptedOCRIsRecoveredAfterRestartAndEmptyResultsAreCached() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotyOCRRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = NotyStore(storageDirectoryURL: root)
        let document = initial.createDocument(title: "Restored ink", kind: .note, folderID: nil)
        let page = try XCTUnwrap(document.pages.first?.id)
        let inkURL = initial.drawingURL(documentID: document.id, pageID: page)
        try FileManager.default.createDirectory(at: inkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let drawing = PKDrawing(strokes: [stroke([CGPoint(x: 30, y: 30), CGPoint(x: 160, y: 30)])])
        try drawing.dataRepresentation().write(to: inkURL)
        let reloaded = NotyStore(storageDirectoryURL: root)
        reloaded.ensureHandwritingSearchIndex()
        XCTAssertTrue(reloaded.isIndexingHandwriting)
        let deadline = Date().addingTimeInterval(12)
        while reloaded.isIndexingHandwriting && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(reloaded.isIndexingHandwriting)
        XCTAssertNil(reloaded.handwritingIndexError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.handwritingTextURL(documentID: document.id, pageID: page).path))
        reloaded.ensureHandwritingSearchIndex()
        XCTAssertFalse(reloaded.isIndexingHandwriting, "Even an empty OCR result should be indexed only once for unchanged ink.")
    }

    func testVisionRecognizesHandDrawnBlockLetters() throws {
        let letters: [[CGPoint]] = [
            [CGPoint(x: 30, y: 130), CGPoint(x: 30, y: 30), CGPoint(x: 80, y: 130), CGPoint(x: 80, y: 30)],
            (0...60).map { i in CGPoint(x: 125 + 28 * cos(CGFloat(i) / 60 * .pi * 2), y: 80 + 50 * sin(CGFloat(i) / 60 * .pi * 2)) },
            [CGPoint(x: 168, y: 30), CGPoint(x: 228, y: 30)],
            [CGPoint(x: 198, y: 30), CGPoint(x: 198, y: 130)],
            [CGPoint(x: 293, y: 30), CGPoint(x: 248, y: 30), CGPoint(x: 248, y: 130), CGPoint(x: 293, y: 130)],
            [CGPoint(x: 248, y: 78), CGPoint(x: 286, y: 78)]
        ]
        let drawing = PKDrawing(strokes: letters.map { stroke(polygon($0), color: .white) })
        let text = try NotyHandwritingRecognizer.recognize(drawingData: drawing.dataRepresentation())
        XCTAssertTrue(text.localizedCaseInsensitiveContains("NOTE"), "Expected the drawn word NOTE, got: \(text)")
    }

    func testInkRenderingKeepsTheSelectedColorInDarkAppearance() throws {
        let drawing = PKDrawing(strokes: [stroke(polygon([CGPoint(x: 10, y: 30), CGPoint(x: 100, y: 30)]))])
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 60)
        var light = UIImage(), dark = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { light = drawing.notyImage(from: bounds, scale: 1) }
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent { dark = drawing.notyImage(from: bounds, scale: 1) }
        let lightPixels = try XCTUnwrap(light.cgImage?.dataProvider?.data)
        let darkPixels = try XCTUnwrap(dark.cgImage?.dataProvider?.data)
        XCTAssertEqual(lightPixels as Data, darkPixels as Data, "Black ink on paper must remain black when the app uses dark appearance.")
    }

    func testToolbarDragChoosesOnlyTheNearestEdge() {
        let size = CGSize(width: 1000, height: 700)
        XCTAssertEqual(NotebookToolbarDock.nearest(to: CGPoint(x: 500, y: 50), in: size), .top)
        XCTAssertEqual(NotebookToolbarDock.nearest(to: CGPoint(x: 500, y: 660), in: size), .bottom)
        XCTAssertEqual(NotebookToolbarDock.nearest(to: CGPoint(x: 20, y: 350), in: size), .left)
        XCTAssertEqual(NotebookToolbarDock.nearest(to: CGPoint(x: 980, y: 350), in: size), .right)
        XCTAssertEqual(NotebookToolbarDock.nearest(to: CGPoint(x: -80, y: 350), in: size), .left)
        XCTAssertEqual(NotebookToolbarDock.nearest(to: CGPoint(x: 500, y: 350), in: size), .top)
    }

    private func polygon(_ vertices: [CGPoint]) -> [CGPoint] {
        guard let first = vertices.first else { return [] }
        var result = [first]
        for (a, b) in zip(vertices, vertices.dropFirst()) {
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 3))
            for index in 1...steps {
                let t = CGFloat(index) / CGFloat(steps)
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return result
    }

    private func stroke(_ points: [CGPoint], color: UIColor = .black) -> PKStroke {
        PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date()))
    }
}

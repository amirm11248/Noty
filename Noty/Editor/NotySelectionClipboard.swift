import ImageIO
import PencilKit
import UniformTypeIdentifiers
import UIKit

struct NotySelectionPayload: Codable {
    struct Photo: Codable { var object: NotyPageImage; var data: Data }
    var version = 1
    var width: Double
    var height: Double
    var drawing: Data
    var textBoxes: [NotyTextBox]
    var photos: [Photo]
}

enum NotySelectionError: LocalizedError {
    case unavailable, invalid
    var errorDescription: String? {
        switch self {
        case .unavailable: "This selection could not be copied. Please try again."
        case .invalid: "The copied selection could not be pasted."
        }
    }
}

@MainActor
enum NotySelectionClipboard {
    static let pasteboardType = "com.malik.noty.page-selection"

    static func payload(selection: NotyPageSelection, content: NotyPageContent, store: NotyStore, documentID: UUID, pageID: UUID) throws -> NotySelectionPayload {
        let selected = selection.extracting(from: content)
        let photos = try selected.images.map { image in
            guard URL(fileURLWithPath: image.fileName).lastPathComponent == image.fileName else { throw NotySelectionError.unavailable }
            let url = store.pageImagesDirectoryURL(documentID: documentID, pageID: pageID).appendingPathComponent(image.fileName)
            return NotySelectionPayload.Photo(object: image, data: try Data(contentsOf: url))
        }
        return NotySelectionPayload(width: max(selection.bounds.width, 1), height: max(selection.bounds.height, 1), drawing: selected.drawing.dataRepresentation(), textBoxes: selected.textBoxes, photos: photos)
    }

    static func copy(selection: NotyPageSelection, content: NotyPageContent, store: NotyStore, documentID: UUID, pageID: UUID) throws {
        let payload = try payload(selection: selection, content: content, store: store, documentID: documentID, pageID: pageID)
        var item: [String: Any] = [pasteboardType: try JSONEncoder().encode(payload)]
        let text = payload.textBoxes.map(\.text).joined(separator: "\n")
        if !text.isEmpty { item[UTType.utf8PlainText.identifier] = text }
        let selected = selection.extracting(from: content)
        let size = CGSize(width: payload.width, height: payload.height)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = min(2, 2_048 / max(size.width, size.height))
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for object in selected.images {
                if let photo = store.pageImage(documentID: documentID, pageID: pageID, image: object) {
                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: object.x + object.width / 2, y: object.y + object.height / 2)
                    context.cgContext.rotate(by: object.rotationDegrees * .pi / 180)
                    photo.draw(in: CGRect(x: -object.width / 2, y: -object.height / 2, width: object.width, height: object.height))
                    context.cgContext.restoreGState()
                }
            }
            selected.drawing.notyImage(from: CGRect(origin: .zero, size: size), scale: format.scale).draw(in: CGRect(origin: .zero, size: size))
            for box in selected.textBoxes { NotyExportService.drawTextBox(box, canvasSize: size, in: context.cgContext) }
        }
        if let png = image.pngData() { item[UTType.png.identifier] = png }
        UIPasteboard.general.setItems([item])
    }

    static func read() throws -> NotySelectionPayload? {
        guard let data = UIPasteboard.general.data(forPasteboardType: pasteboardType) else { return nil }
        guard data.count <= 128 * 1_024 * 1_024 else { throw NotySelectionError.invalid }
        return try JSONDecoder().decode(NotySelectionPayload.self, from: data)
    }

    /// Stage photo assets before applying one undoable content change. A failed paste
    /// removes only files written by this operation and leaves the page untouched.
    static func inserting(_ payload: NotySelectionPayload, into original: NotyPageContent, at proposedOrigin: CGPoint, paper: CGSize, store: NotyStore, documentID: UUID, pageID: UUID) throws -> (content: NotyPageContent, selection: NotyPageSelection) {
        guard store.documents.contains(where: { $0.id == documentID && $0.pages.contains(where: { $0.id == pageID }) }),
              payload.version == 1, payload.width.isFinite, payload.height.isFinite,
              payload.width > 0, payload.height > 0, payload.width <= 100_000, payload.height <= 100_000,
              let drawing = try? PKDrawing(data: payload.drawing),
              payload.textBoxes.allSatisfy({ valid($0.x, $0.y, $0.width, $0.height) && $0.fontSize.isFinite && $0.fontSize > 0 }),
              payload.photos.allSatisfy({ valid($0.object.x, $0.object.y, $0.object.width, $0.object.height) && $0.object.rotationDegrees.isFinite }) else { throw NotySelectionError.invalid }
        guard !drawing.strokes.isEmpty || !payload.textBoxes.isEmpty || !payload.photos.isEmpty else { throw NotySelectionError.invalid }
        let scale = min(1, max(paper.width - 32, 1) / payload.width, max(paper.height - 32, 1) / payload.height)
        let width = payload.width * scale, height = payload.height * scale
        let origin = CGPoint(x: min(max(proposedOrigin.x, 0), max(paper.width - width, 0)), y: min(max(proposedOrigin.y, 0), max(paper.height - height, 0)))
        let directory = store.pageImagesDirectoryURL(documentID: documentID, pageID: pageID)
        var staged: [URL] = []
        do {
            var inserted = original
            inserted.drawing = PKDrawing(strokes: drawing.strokes.map { stroke in
                PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
            })
            inserted.textBoxes = payload.textBoxes.map { box in var copy = box; copy.id = UUID(); return copy }
            inserted.images = try payload.photos.map { photo in
                guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil), CGImageSourceGetCount(source) > 0,
                      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else { throw NotySelectionError.invalid }
                let ext = CGImageSourceGetType(source).flatMap { UTType($0 as String)?.preferredFilenameExtension } ?? "png"
                var image = photo.object
                image.id = UUID(); image.fileName = "\(UUID().uuidString).\(ext)"
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(image.fileName)
                try photo.data.write(to: url, options: .atomic)
                staged.append(url)
                return image
            }
            let all = NotyPageSelection(strokeIndices: IndexSet(integersIn: 0..<drawing.strokes.count), textIDs: Set(inserted.textBoxes.map(\.id)), imageIDs: Set(inserted.images.map(\.id)), bounds: CGRect(x: 0, y: 0, width: payload.width, height: payload.height))
            inserted = all.transforming(inserted, by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: origin.x, y: origin.y)))
            let result = NotyPageSelection(strokeIndices: IndexSet(integersIn: original.drawing.strokes.count..<(original.drawing.strokes.count + inserted.drawing.strokes.count)), textIDs: all.textIDs, imageIDs: all.imageIDs, bounds: CGRect(origin: origin, size: CGSize(width: width, height: height)))
            var combined = original
            combined.drawing = PKDrawing(strokes: original.drawing.strokes + inserted.drawing.strokes)
            combined.textBoxes += inserted.textBoxes
            combined.images += inserted.images
            return (combined, result)
        } catch {
            for url in staged { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func valid(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 && width <= 100_000 && height <= 100_000
    }
}

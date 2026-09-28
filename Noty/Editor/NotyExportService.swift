import CoreText
import PDFKit
import PencilKit
import SwiftUI
import UIKit

@MainActor
enum NotyExportService {
    private static let canvasSize = CGSize(width: 612, height: 792)

    /// Creates a uniquely named, user-facing PDF in Documents so it remains available
    /// after the share sheet closes and can be saved or uploaded later.
    static func exportPDF(documentID: UUID, store: NotyStore) throws -> URL {
        guard let document = store.documents.first(where: { $0.id == documentID }) else {
            throw NotyExportError.documentUnavailable
        }
        guard !document.pages.isEmpty else { throw NotyExportError.noPages }
        let directory = try exportDirectory()
        let fileURL = directory.appendingPathComponent("\(safeName(document.title))-\(UUID().uuidString.prefix(8)).pdf")
        try makePDF(document: document, store: store).write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Renders a stable per-document PDF for the cloud mirror. The path remains the
    /// same across edits; each new rendering atomically replaces the previous one.
    static func exportPDFForSync(documentID: UUID, store: NotyStore) throws -> URL {
        guard let document = store.documents.first(where: { $0.id == documentID }) else {
            throw NotyExportError.documentUnavailable
        }
        guard !document.pages.isEmpty else { throw NotyExportError.noPages }
        let directory = try syncDirectory()
        let fileURL = directory.appendingPathComponent("\(document.id.uuidString).pdf")
        try makePDF(document: document, store: store).write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Exports one fully composed page as a high-resolution PNG.
    static func exportPageImage(documentID: UUID, pageID: UUID, store: NotyStore) throws -> URL {
        guard let document = store.documents.first(where: { $0.id == documentID }) else {
            throw NotyExportError.documentUnavailable
        }
        guard let page = document.pages.first(where: { $0.id == pageID }) else {
            throw NotyExportError.pageUnavailable
        }
        let directory = try exportDirectory()
        let fileURL = directory.appendingPathComponent("\(safeName(document.title))-page-\(UUID().uuidString.prefix(8)).png")
        let image = renderPage(page, documentID: documentID, store: store, sourcePDF: store.sourcePDF(documentID: documentID), scale: 3)
        guard let data = image.pngData() else { throw NotyExportError.imageEncodingFailed }
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func makePDF(document: NotyDocument, store: NotyStore) throws -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: canvasSize))
        let sourcePDF = store.sourcePDF(documentID: document.id)
        return renderer.pdfData { context in
            for page in document.pages {
                context.beginPage()
                drawPage(page, documentID: document.id, store: store, sourcePDF: sourcePDF, in: context.cgContext)
            }
        }
    }

    private static func renderPage(
        _ page: NotyPage,
        documentID: UUID,
        store: NotyStore,
        sourcePDF: PDFDocument?,
        scale: CGFloat
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { context in
            drawPage(page, documentID: documentID, store: store, sourcePDF: sourcePDF, in: context.cgContext)
        }
    }

    private static func drawPage(
        _ page: NotyPage,
        documentID: UUID,
        store: NotyStore,
        sourcePDF: PDFDocument?,
        in cgContext: CGContext
    ) {
        let bounds = CGRect(origin: .zero, size: canvasSize)
        UIColor.white.setFill()
        cgContext.fill(bounds)

        if let sourcePageIndex = page.sourcePageIndex,
           let sourcePage = sourcePDF?.page(at: sourcePageIndex) {
            drawOriginalPDFPage(sourcePage, into: bounds, context: cgContext)
        } else {
            drawTemplate(page.template, in: cgContext)
        }

        for pageImage in page.images {
            if let image = store.pageImage(documentID: documentID, pageID: page.id, image: pageImage) {
                drawPageImage(pageImage, image: image, in: cgContext)
            }
        }

        let drawing = store.drawing(documentID: documentID, pageID: page.id)
        if !drawing.strokes.isEmpty {
            // High-resolution transparent raster keeps PencilKit pressure, blend and
            // eraser results intact while the source PDF remains vector-backed.
            let image = drawing.image(from: bounds, scale: 4)
            image.draw(in: bounds)
        }

        for textBox in page.textBoxes {
            drawTextBox(textBox, in: cgContext)
        }
    }

    private static func drawOriginalPDFPage(_ page: PDFPage, into target: CGRect, context: CGContext) {
        let source = page.bounds(for: .mediaBox)
        guard source.width > 0, source.height > 0 else { return }
        // PDFPage bounds remain in unrotated page space. PDFKit's display transform
        // gives the visible bounds used by thumbnail(of:for:), including /Rotate.
        let displayBounds = source.applying(page.transform(for: .mediaBox))
        guard displayBounds.width > 0, displayBounds.height > 0 else { return }
        let scale = min(target.width / displayBounds.width, target.height / displayBounds.height)
        let width = displayBounds.width * scale
        let height = displayBounds.height * scale
        let fitted = CGRect(
            x: target.midX - width / 2,
            y: target.midY - height / 2,
            width: width,
            height: height
        )

        context.saveGState()
        context.clip(to: target)
        // PDFKit draws page content, visible annotations, and page rotation together.
        // Fit those displayed bounds into the same canvas region used by the editor.
        context.translateBy(x: fitted.minX, y: fitted.minY + fitted.height)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -displayBounds.minX, y: -displayBounds.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
    }

    private static func drawTemplate(_ template: NotyPageTemplate, in context: CGContext) {
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let lineColor = UIColor(red: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.12).cgColor
        context.saveGState()
        context.setStrokeColor(lineColor)
        context.setFillColor(lineColor)
        switch template {
        case .blank:
            break
        case .ruled:
            context.setLineWidth(0.7)
            for y in stride(from: 34.0, through: bounds.height, by: 28.0) {
                context.move(to: CGPoint(x: 28, y: y))
                context.addLine(to: CGPoint(x: bounds.width - 24, y: y))
            }
            context.strokePath()
            context.setAlpha(0.65)
            context.move(to: CGPoint(x: 56, y: 0))
            context.addLine(to: CGPoint(x: 56, y: bounds.height))
            context.strokePath()
        case .grid:
            context.setLineWidth(0.55)
            context.setAlpha(0.55)
            for x in stride(from: 18.0, through: bounds.width, by: 24.0) {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: bounds.height))
            }
            for y in stride(from: 18.0, through: bounds.height, by: 24.0) {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: bounds.width, y: y))
            }
            context.strokePath()
        case .dots:
            context.setAlpha(0.72)
            for x in stride(from: 18.0, through: bounds.width, by: 24.0) {
                for y in stride(from: 18.0, through: bounds.height, by: 24.0) {
                    context.fillEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                }
            }
        }
        context.restoreGState()
    }

    private static func drawPageImage(_ pageImage: NotyPageImage, image: UIImage, in context: CGContext) {
        let rect = CGRect(
            x: CGFloat(pageImage.x),
            y: CGFloat(pageImage.y),
            width: CGFloat(pageImage.width),
            height: CGFloat(pageImage.height)
        )
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: CGFloat(pageImage.rotationDegrees * .pi / 180))
        image.draw(in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private static func drawTextBox(_ box: NotyTextBox, in context: CGContext) {
        let rect = CGRect(x: CGFloat(box.x), y: CGFloat(box.y), width: CGFloat(box.width), height: CGFloat(box.height))
        let insetRect = rect.insetBy(dx: 9, dy: 8)
        let paper = UIColor(white: 1, alpha: 0.97)
        let border = UIColor(red: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.16)
        let boxPath = CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil)
        context.saveGState()
        context.setFillColor(paper.cgColor)
        context.addPath(boxPath)
        context.fillPath()
        context.setStrokeColor(border.cgColor)
        context.setLineWidth(0.7)
        context.addPath(boxPath)
        context.strokePath()
        context.restoreGState()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        switch box.alignment {
        case .leading: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }

        let pointSize = max(6, CGFloat(box.fontSize))
        let baseFont = box.fontName.flatMap { UIFont(name: $0, size: pointSize) }
            ?? UIFont.systemFont(ofSize: pointSize)
        var traits = baseFont.fontDescriptor.symbolicTraits
        if box.isBold { traits.insert(.traitBold) }
        if box.isItalic { traits.insert(.traitItalic) }
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) ?? baseFont.fontDescriptor
        let styledFont = UIFont(descriptor: descriptor, size: pointSize)

        var attributes: [NSAttributedString.Key: Any] = [
            .font: styledFont,
            .foregroundColor: color(hex: box.colorHex),
            .paragraphStyle: paragraph
        ]
        if box.isUnderlined {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        let attributedText = NSAttributedString(string: box.text, attributes: attributes)
        let textBounds = CGRect(
            x: insetRect.minX,
            y: canvasSize.height - insetRect.maxY,
            width: insetRect.width,
            height: insetRect.height
        )
        let textPath = CGPath(rect: textBounds, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), textPath, nil)

        // UIGraphics renderers use a top-left coordinate system; CoreText lays out
        // baselines from a bottom-left coordinate system. Flip back for layout so
        // the text remains aligned with the PencilKit and SwiftUI canvas.
        context.saveGState()
        context.translateBy(x: 0, y: canvasSize.height)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func color(hex: String) -> UIColor {
        let digits = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(digits, radix: 16) ?? 0x37352F
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func exportDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NotyExportError.outputDirectoryUnavailable
        }
        let directory = documents.appendingPathComponent("Noty Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func syncDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NotyExportError.outputDirectoryUnavailable
        }
        let directory = support.appendingPathComponent("Noty Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Noty-Document" : cleaned
    }
}

private enum NotyExportError: LocalizedError {
    case documentUnavailable
    case pageUnavailable
    case noPages
    case imageEncodingFailed
    case outputDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .documentUnavailable: "The document could not be found."
        case .pageUnavailable: "The page could not be found."
        case .noPages: "Add a page before exporting this document."
        case .imageEncodingFailed: "The page image could not be created."
        case .outputDirectoryUnavailable: "The export folder is unavailable."
        }
    }
}

import CoreText
import PDFKit
import PencilKit
import SwiftUI
import UIKit

@MainActor
enum NotyExportService {
    private static let defaultCanvasSize = CGSize(width: 612, height: 792)

    /// Creates a uniquely named, user-facing PDF in Documents so it remains available
    /// after the share sheet closes and can be saved or uploaded later.
    static func exportPDF(documentID: UUID, store: NotyStore, selectedPageIDs: Set<UUID>? = nil) throws -> URL {
        guard let document = store.documents.first(where: { $0.id == documentID }) else {
            throw NotyExportError.documentUnavailable
        }
        let pages = document.pages.filter { selectedPageIDs?.contains($0.id) ?? true }
        guard !pages.isEmpty else { throw NotyExportError.noPages }
        let directory = try exportDirectory()
        let fileURL = directory.appendingPathComponent("\(safeName(document.title))-\(UUID().uuidString.prefix(8)).pdf")
        try makePDF(document: document, store: store, pages: pages).write(to: fileURL, options: .atomic)
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

    private static func makePDF(document: NotyDocument, store: NotyStore, pages: [NotyPage]? = nil) throws -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: defaultCanvasSize))
        let sourcePDF = store.sourcePDF(documentID: document.id)
        return renderer.pdfData { context in
            for page in pages ?? document.pages {
                let bounds = renderBounds(page, documentID: document.id, store: store)
                context.beginPage(withBounds: CGRect(origin: .zero, size: bounds.size), pageInfo: [:])
                context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                drawPage(page, documentID: document.id, store: store, sourcePDF: sourcePDF, in: context.cgContext, bounds: bounds)
            }
        }
    }

    static func renderBounds(_ page: NotyPage, documentID: UUID, store: NotyStore) -> CGRect {
        guard store.documents.first(where: { $0.id == documentID })?.kind == .whiteboard else { return CGRect(origin: .zero, size: page.canvasSize) }
        let drawing = store.drawing(documentID: documentID, pageID: page.id)
        var bounds = drawing.strokes.isEmpty ? CGRect.null : drawing.bounds
        for box in page.textBoxes { bounds = bounds.union(CGRect(x: box.x, y: box.y, width: box.width, height: box.height)) }
        for image in page.images {
            let angle = image.rotationDegrees * .pi / 180
            let width = abs(image.width * cos(angle)) + abs(image.height * sin(angle))
            let height = abs(image.width * sin(angle)) + abs(image.height * cos(angle))
            bounds = bounds.union(CGRect(x: image.x + image.width / 2 - width / 2, y: image.y + image.height / 2 - height / 2, width: width, height: height))
        }
        return bounds.isNull || bounds.isEmpty ? CGRect(origin: .zero, size: defaultCanvasSize) : bounds.insetBy(dx: -48, dy: -48).integral
    }

    private static func drawBoardTemplate(_ page: NotyPage, bounds: CGRect, context: CGContext) {
        guard page.template != .blank else { return }
        let spacing: CGFloat = page.template == .smallGrid ? 16 : page.template == .narrowRuled ? 20 : 24
        let dark = UIColor(notyHex: page.paperColorHex).notyIsDark
        let ink = (dark ? UIColor.white : UIColor.darkGray).withAlphaComponent(0.2)
        context.setStrokeColor(ink.cgColor); context.setFillColor(ink.cgColor); context.setLineWidth(0.6)
        let firstX = floor(bounds.minX / spacing) * spacing
        let firstY = floor(bounds.minY / spacing) * spacing
        if page.template == .dots {
            for x in stride(from: firstX, through: bounds.maxX, by: spacing) {
                for y in stride(from: firstY, through: bounds.maxY, by: spacing) { context.fillEllipse(in: CGRect(x: x + spacing / 2 - 0.8, y: y + spacing / 2 - 0.8, width: 1.6, height: 1.6)) }
            }
        } else {
            for y in stride(from: firstY, through: bounds.maxY, by: spacing) { context.move(to: CGPoint(x: bounds.minX, y: y)); context.addLine(to: CGPoint(x: bounds.maxX, y: y)) }
            if page.template != .ruled && page.template != .narrowRuled {
                for x in stride(from: firstX, through: bounds.maxX, by: spacing) { context.move(to: CGPoint(x: x, y: bounds.minY)); context.addLine(to: CGPoint(x: x, y: bounds.maxY)) }
            }
            context.strokePath()
        }
    }

    private static func renderPage(
        _ page: NotyPage,
        documentID: UUID,
        store: NotyStore,
        sourcePDF: PDFDocument?,
        scale: CGFloat
    ) -> UIImage {
        let bounds = renderBounds(page, documentID: documentID, store: store)
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(scale, 4_096 / max(bounds.width, bounds.height))
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        return renderer.image { context in
            context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
            drawPage(page, documentID: documentID, store: store, sourcePDF: sourcePDF, in: context.cgContext, bounds: bounds)
        }
    }

    private static func drawPage(
        _ page: NotyPage,
        documentID: UUID,
        store: NotyStore,
        sourcePDF: PDFDocument?,
        in cgContext: CGContext,
        bounds: CGRect
    ) {
        color(hex: page.paperColorHex).setFill()
        cgContext.fill(bounds)

        if page.isCover, let document = store.documents.first(where: { $0.id == documentID }) {
            let renderer = ImageRenderer(content: NotebookCoverView(title: document.title, cover: document.displayCover, image: store.coverImage(for: document, maximumPixelSize: 4_096), pageSize: page.canvasSize).frame(width: bounds.width, height: bounds.height))
            renderer.scale = min(3, 4_096 / max(bounds.width, bounds.height))
            renderer.uiImage?.draw(in: bounds)
        } else if let sourcePageIndex = page.sourcePageIndex,
           let sourcePage = sourcePDF?.page(at: sourcePageIndex) {
            drawOriginalPDFPage(sourcePage, into: bounds, context: cgContext)
        } else if store.documents.first(where: { $0.id == documentID })?.kind == .whiteboard {
            drawBoardTemplate(page, bounds: bounds, context: cgContext)
        } else {
            drawTemplate(page.template, paperColorHex: page.paperColorHex, bounds: bounds, in: cgContext)
        }

        for pageImage in page.images {
            if let image = store.pageImage(documentID: documentID, pageID: page.id, image: pageImage, maximumPixelSize: 4_096) {
                drawPageImage(pageImage, image: image, in: cgContext)
            }
        }

        let drawing = store.drawing(documentID: documentID, pageID: page.id)
        if !drawing.strokes.isEmpty {
            // High-resolution transparent raster keeps PencilKit pressure, blend and
            // eraser results intact while the source PDF remains vector-backed.
            let image = drawing.notyImage(from: bounds, scale: min(4, 4_096 / max(bounds.width, bounds.height)))
            image.draw(in: bounds)
        }

        for textBox in page.textBoxes {
            drawTextBox(textBox, canvasSize: page.canvasSize, in: cgContext)
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

    private static func drawTemplate(
        _ template: NotyPageTemplate,
        paperColorHex: String,
        bounds: CGRect,
        in context: CGContext
    ) {
        let paper = color(hex: paperColorHex)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        paper.getRed(&red, green: &green, blue: &blue, alpha: nil)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let lineUIColor = luminance < 0.48
            ? UIColor.white.withAlphaComponent(0.24)
            : UIColor(red: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.12)
        let lineColor = lineUIColor.cgColor

        context.saveGState()
        context.setStrokeColor(lineColor)
        context.setFillColor(lineColor)
        context.setLineWidth(0.65)
        context.addPath(PaperTemplateGeometry.path(template, size: bounds.size))
        if template == .dots { context.fillPath() } else { context.strokePath() }
        for (label, point) in PaperTemplateGeometry.labels(template, size: bounds.size) {
            (label as NSString).draw(at: point, withAttributes: [.font: UIFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: luminance < 0.48 ? UIColor.white.withAlphaComponent(0.55) : UIColor.secondaryLabel])
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

    static func drawTextBox(_ box: NotyTextBox, canvasSize: CGSize, in context: CGContext) {
        let rect = CGRect(x: CGFloat(box.x), y: CGFloat(box.y), width: CGFloat(box.width), height: CGFloat(box.height))
        let insetRect = rect.insetBy(dx: 9 * box.contentInsetScale, dy: 8 * box.contentInsetScale)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        switch box.alignment {
        case .leading: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }

        let pointSize = max(1, CGFloat(box.fontSize))
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

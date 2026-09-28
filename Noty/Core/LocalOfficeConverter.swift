import CoreText
import Foundation
import PDFKit
import UIKit
import WebKit
import zlib

enum LocalOfficeConverter {
    struct ConversionResult {
        var pageCount: Int
        var extractedText: String
    }

    static func convertDOCXTextFallback(at sourceURL: URL, to destinationURL: URL) throws -> ConversionResult {
        let archive = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let xml = try ZIPArchiveReader(data: archive).data(forEntryNamed: "word/document.xml")
        let text = try WordDocumentTextParser.parse(xml: xml)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            throw NotyStoreError.invalidOfficeDocument(
                "The DOCX contains no readable body text. The original Word file has been kept."
            )
        }
        let pageCount = try writePDF(from: normalizedText, to: destinationURL)
        return ConversionResult(pageCount: pageCount, extractedText: normalizedText)
    }

    @MainActor
    static func convertDOCXRich(at sourceURL: URL, to destinationURL: URL) async throws -> ConversionResult {
        guard let docxPreviewURL = Bundle.main.url(forResource: "docx-preview.min", withExtension: "js"),
              let jszipURL = Bundle.main.url(forResource: "jszip.min", withExtension: "js") else {
            throw NotyStoreError.invalidOfficeDocument(
                "The offline Word renderer is not available in this app build."
            )
        }

        let sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let docxScript = try String(contentsOf: docxPreviewURL, encoding: .utf8)
        let jszipScript = try String(contentsOf: jszipURL, encoding: .utf8)
        let pdfData = try await DOCXPreviewPDFSession().render(
            docxData: sourceData,
            docxScript: docxScript,
            jszipScript: jszipScript,
            workingDirectoryURL: sourceURL.deletingLastPathComponent()
        )
        guard let pdf = PDFDocument(data: pdfData), pdf.pageCount > 0 else {
            throw NotyStoreError.invalidOfficeDocument(
                "The offline Word renderer did not produce a readable PDF. The original Word file has been kept."
            )
        }
        guard Self.hasVisibleContent(in: pdf) else {
            throw NotyStoreError.invalidOfficeDocument(
                "The offline Word renderer produced blank pages. Noty will try a text conversion fallback. The original Word file has been kept."
            )
        }
        try pdfData.write(to: destinationURL, options: .atomic)
        #if DEBUG
        NSLog("Noty DOCX PDF result: %ld page(s), page 1 text: %@", pdf.pageCount, pdf.page(at: 0)?.string ?? "<none>")
        if let debugDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? pdfData.write(to: debugDirectory.appendingPathComponent("Noty-DOCX-debug.pdf"), options: .atomic)
        }
        #endif
        return ConversionResult(pageCount: pdf.pageCount, extractedText: "")
    }

    private static func hasVisibleContent(in pdf: PDFDocument) -> Bool {
        let thumbnailSize = CGSize(width: 240, height: 320)
        for pageIndex in 0..<pdf.pageCount {
            guard let image = pdf.page(at: pageIndex)?.thumbnail(of: thumbnailSize, for: .mediaBox),
                  let cgImage = image.cgImage,
                  let providerData = cgImage.dataProvider?.data else {
                continue
            }
            let bytes = providerData as Data
            let bytesPerPixel = cgImage.bitsPerPixel / 8
            guard bytesPerPixel >= 3 else { continue }
            let alphaInfo = cgImage.alphaInfo
            let alphaOffset: Int?
            switch alphaInfo {
            case .first, .premultipliedFirst:
                alphaOffset = 0
            case .last, .premultipliedLast:
                alphaOffset = bytesPerPixel - 1
            default:
                alphaOffset = nil
            }
            let colorOffset = alphaOffset == 0 ? 1 : 0
            var visiblePixelCount = 0
            let pixelCount = cgImage.width * cgImage.height
            let sampleStride = max(1, pixelCount / 24_000)
            for pixelIndex in stride(from: 0, to: pixelCount, by: sampleStride) {
                let offset = pixelIndex * bytesPerPixel
                guard offset + colorOffset + 2 < bytes.count else { continue }
                if let alphaOffset, Int(bytes[offset + alphaOffset]) < 12 { continue }
                let red = Int(bytes[offset + colorOffset])
                let green = Int(bytes[offset + colorOffset + 1])
                let blue = Int(bytes[offset + colorOffset + 2])
                if red < 250 || green < 250 || blue < 250 {
                    visiblePixelCount += 1
                    if visiblePixelCount >= 8 { return true }
                }
            }
        }
        return false
    }

    static func writePDF(from string: String, to destinationURL: URL) throws -> Int {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 7
        paragraphStyle.alignment = .natural

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraphStyle
        ]
        let attributedText = NSAttributedString(string: string, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let contentRect = CGRect(x: 54, y: 54, width: 504, height: 684)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        var currentLocation = 0
        var renderedPageCount = 0

        let pdfData = renderer.pdfData { rendererContext in
            while currentLocation < attributedText.length {
                rendererContext.beginPage()
                let context = rendererContext.cgContext
                context.saveGState()
                context.translateBy(x: 0, y: pageBounds.height)
                context.scaleBy(x: 1, y: -1)

                let path = CGPath(rect: contentRect, transform: nil)
                let frame = CTFramesetterCreateFrame(
                    framesetter,
                    CFRange(location: currentLocation, length: 0),
                    path,
                    nil
                )
                CTFrameDraw(frame, context)
                let visibleRange = CTFrameGetVisibleStringRange(frame)
                context.restoreGState()

                guard visibleRange.length > 0 else { break }
                currentLocation += visibleRange.length
                renderedPageCount += 1
            }
        }

        guard renderedPageCount > 0, currentLocation >= attributedText.length else {
            throw NotyStoreError.invalidOfficeDocument(
                "The DOCX text could not be laid out as a PDF. The original Word file has been kept."
            )
        }
        try pdfData.write(to: destinationURL, options: .atomic)
        return renderedPageCount
    }
}

private struct ZIPArchiveReader {
    private let bytes: [UInt8]

    init(data: Data) {
        bytes = Array(data)
    }

    func data(forEntryNamed entryName: String) throws -> Data {
        guard let endRecord = endOfCentralDirectoryOffset() else {
            throw NotyStoreError.invalidOfficeDocument(
                "This DOCX is not a readable ZIP package. The original Word file has been kept."
            )
        }

        let entryCount = Int(readUInt16(at: endRecord + 10))
        let directorySize = Int(readUInt32(at: endRecord + 12))
        let directoryOffset = Int(readUInt32(at: endRecord + 16))
        guard entryCount < Int(UInt16.max),
              directorySize < Int(UInt32.max),
              directoryOffset < Int(UInt32.max),
              directoryOffset + directorySize <= bytes.count else {
            throw NotyStoreError.invalidOfficeDocument(
                "This DOCX uses a ZIP format that Noty cannot read. The original Word file has been kept."
            )
        }

        var cursor = directoryOffset
        let directoryEnd = directoryOffset + directorySize
        for _ in 0..<entryCount {
            guard cursor + 46 <= directoryEnd, readUInt32(at: cursor) == 0x02014B50 else { break }

            let flags = readUInt16(at: cursor + 8)
            let compressionMethod = readUInt16(at: cursor + 10)
            let compressedSize = Int(readUInt32(at: cursor + 20))
            let uncompressedSize = Int(readUInt32(at: cursor + 24))
            let nameLength = Int(readUInt16(at: cursor + 28))
            let extraLength = Int(readUInt16(at: cursor + 30))
            let commentLength = Int(readUInt16(at: cursor + 32))
            let localHeaderOffset = Int(readUInt32(at: cursor + 42))
            let nameStart = cursor + 46
            let nextRecord = nameStart + nameLength + extraLength + commentLength

            guard nextRecord <= directoryEnd,
                  nameStart + nameLength <= bytes.count,
                  let name = String(bytes: bytes[nameStart..<(nameStart + nameLength)], encoding: .utf8) else {
                throw NotyStoreError.invalidOfficeDocument(
                    "This DOCX contains a damaged ZIP directory. The original Word file has been kept."
                )
            }

            if name == entryName {
                guard flags & 0x0001 == 0 else {
                    throw NotyStoreError.invalidOfficeDocument(
                        "Password-protected DOCX files are not supported. The original Word file has been kept."
                    )
                }
                guard compressedSize >= 0, uncompressedSize >= 0,
                      uncompressedSize <= 128 * 1024 * 1024,
                      localHeaderOffset + 30 <= bytes.count,
                      readUInt32(at: localHeaderOffset) == 0x04034B50 else {
                    throw NotyStoreError.invalidOfficeDocument(
                        "The DOCX body could not be read. The original Word file has been kept."
                    )
                }

                let localNameLength = Int(readUInt16(at: localHeaderOffset + 26))
                let localExtraLength = Int(readUInt16(at: localHeaderOffset + 28))
                let bodyStart = localHeaderOffset + 30 + localNameLength + localExtraLength
                let bodyEnd = bodyStart + compressedSize
                guard bodyStart >= 0, bodyEnd <= bytes.count else {
                    throw NotyStoreError.invalidOfficeDocument(
                        "The DOCX body is incomplete. The original Word file has been kept."
                    )
                }
                let compressed = Data(bytes[bodyStart..<bodyEnd])
                switch compressionMethod {
                case 0:
                    guard compressed.count == uncompressedSize else {
                        throw NotyStoreError.invalidOfficeDocument(
                            "The DOCX body size is inconsistent. The original Word file has been kept."
                        )
                    }
                    return compressed
                case 8:
                    return try Self.inflateRawDeflate(compressed, expectedSize: uncompressedSize)
                default:
                    throw NotyStoreError.invalidOfficeDocument(
                        "This DOCX uses a compression method Noty cannot read. The original Word file has been kept."
                    )
                }
            }

            cursor = nextRecord
        }

        throw NotyStoreError.invalidOfficeDocument(
            "The DOCX body could not be found. The original Word file has been kept."
        )
    }

    private func endOfCentralDirectoryOffset() -> Int? {
        guard bytes.count >= 22 else { return nil }
        let minimumOffset = max(0, bytes.count - 65_557)
        for offset in stride(from: bytes.count - 22, through: minimumOffset, by: -1) {
            if readUInt32(at: offset) == 0x06054B50 {
                return offset
            }
        }
        return nil
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func inflateRawDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize <= 128 * 1024 * 1024 else {
            throw NotyStoreError.invalidOfficeDocument(
                "The DOCX body is too large to convert on this iPad. The original Word file has been kept."
            )
        }

        var stream = z_stream()
        let initResult = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw NotyStoreError.invalidOfficeDocument(
                "The DOCX body could not be decompressed. The original Word file has been kept."
            )
        }
        defer { inflateEnd(&stream) }

        var input = Array(data)
        var output = [UInt8](repeating: 0, count: max(expectedSize, 1))
        let result = input.withUnsafeMutableBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                stream.next_in = inputBuffer.baseAddress
                stream.avail_in = uInt(inputBuffer.count)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = uInt(outputBuffer.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, Int(stream.total_out) == expectedSize else {
            throw NotyStoreError.invalidOfficeDocument(
                "The DOCX body could not be decompressed. The original Word file has been kept."
            )
        }
        return Data(output.prefix(expectedSize))
    }
}

private final class WordDocumentTextParser: NSObject, XMLParserDelegate {
    private var output = ""
    private var capturesText = false

    static func parse(xml: Data) throws -> String {
        let parser = XMLParser(data: xml)
        let delegate = WordDocumentTextParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw NotyStoreError.invalidOfficeDocument(
                "The DOCX body contains invalid XML. The original Word file has been kept."
            )
        }
        return delegate.output
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "w:t":
            capturesText = true
        case "w:tab":
            output.append("\t")
        case "w:br", "w:cr":
            output.append("\n")
        case "w:tc":
            if !output.isEmpty, !output.hasSuffix("\t"), !output.hasSuffix("\n") {
                output.append("\t")
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturesText {
            output.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "w:t":
            capturesText = false
        case "w:p", "w:tr":
            if !output.hasSuffix("\n") {
                output.append("\n")
            }
        default:
            break
        }
    }
}

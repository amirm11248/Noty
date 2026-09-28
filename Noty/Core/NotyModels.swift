import CoreGraphics
import Foundation

enum NotyDocumentKind: String, Codable, CaseIterable {
    case note
    case pdf
    case book
}

enum NotyPageTemplate: String, Codable, CaseIterable {
    case blank
    case ruled
    case narrowRuled
    case grid
    case smallGrid
    case dots
    case cornell
}

enum NotyPageSizePreset: String, Codable, CaseIterable {
    case a4
    case a5
    case letter
    case legal
    case square
    case screen4x3
    case widescreen16x9

    var portraitSize: CGSize {
        switch self {
        case .a4: CGSize(width: 595, height: 842)
        case .a5: CGSize(width: 420, height: 595)
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1008)
        case .square: CGSize(width: 720, height: 720)
        case .screen4x3: CGSize(width: 768, height: 1024)
        case .widescreen16x9: CGSize(width: 720, height: 1280)
        }
    }
}

enum NotyPageOrientation: String, Codable, CaseIterable {
    case portrait
    case landscape
}

enum NotyTextAlignment: String, Codable, CaseIterable {
    case leading
    case center
    case trailing
}

struct NotyFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var parentID: UUID?

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

struct NotyTextBox: Identifiable, Codable, Hashable {
    var id: UUID
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var fontSize: Double
    var fontName: String?
    var isBold: Bool
    var isItalic: Bool
    var isUnderlined: Bool
    var colorHex: String
    var alignment: NotyTextAlignment

    init(
        id: UUID = UUID(),
        text: String,
        x: Double = 24,
        y: Double = 24,
        width: Double = 564,
        height: Double = 120,
        fontSize: Double = 16,
        fontName: String? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        colorHex: String = "37352F",
        alignment: NotyTextAlignment = .leading
    ) {
        self.id = id
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.fontSize = fontSize
        self.fontName = fontName
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.colorHex = colorHex
        self.alignment = alignment
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, x, y, width, height, fontSize, fontName
        case isBold, isItalic, isUnderlined, colorHex, alignment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 24
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 24
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 564
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 120
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 16
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName)
        isBold = try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        isItalic = try container.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
        isUnderlined = try container.decodeIfPresent(Bool.self, forKey: .isUnderlined) ?? false
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "37352F"
        alignment = try container.decodeIfPresent(NotyTextAlignment.self, forKey: .alignment) ?? .leading
    }
}

struct NotyPageImage: Identifiable, Codable, Hashable {
    var id: UUID
    var fileName: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rotationDegrees: Double

    init(
        id: UUID = UUID(),
        fileName: String,
        x: Double = 72,
        y: Double = 120,
        width: Double = 300,
        height: Double = 220,
        rotationDegrees: Double = 0
    ) {
        self.id = id
        self.fileName = fileName
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotationDegrees = rotationDegrees
    }
}

struct NotyPage: Identifiable, Codable, Hashable {
    var id: UUID
    var template: NotyPageTemplate
    /// Zero-based page index in the imported source PDF, when this page is PDF-backed.
    var sourcePageIndex: Int?
    var textBoxes: [NotyTextBox]
    var images: [NotyPageImage]
    var isBookmarked: Bool
    var bookmarkTitle: String?
    var paperColorHex: String
    var sizePreset: NotyPageSizePreset
    var orientation: NotyPageOrientation

    init(
        id: UUID = UUID(),
        template: NotyPageTemplate = .blank,
        sourcePageIndex: Int? = nil,
        textBoxes: [NotyTextBox] = [],
        images: [NotyPageImage] = [],
        isBookmarked: Bool = false,
        bookmarkTitle: String? = nil,
        paperColorHex: String = "FFFFFF",
        sizePreset: NotyPageSizePreset = .letter,
        orientation: NotyPageOrientation = .portrait
    ) {
        self.id = id
        self.template = template
        self.sourcePageIndex = sourcePageIndex
        self.textBoxes = textBoxes
        self.images = images
        self.isBookmarked = isBookmarked
        self.bookmarkTitle = bookmarkTitle
        self.paperColorHex = paperColorHex
        self.sizePreset = sizePreset
        self.orientation = orientation
    }

    var canvasSize: CGSize {
        let base = sizePreset.portraitSize
        if orientation == .landscape && base.width != base.height {
            return CGSize(width: base.height, height: base.width)
        }
        return base
    }

    private enum CodingKeys: String, CodingKey {
        case id, template, sourcePageIndex, textBoxes, images, isBookmarked, bookmarkTitle
        case paperColorHex, sizePreset, orientation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        template = try container.decodeIfPresent(NotyPageTemplate.self, forKey: .template) ?? .blank
        sourcePageIndex = try container.decodeIfPresent(Int.self, forKey: .sourcePageIndex)
        textBoxes = try container.decodeIfPresent([NotyTextBox].self, forKey: .textBoxes) ?? []
        images = try container.decodeIfPresent([NotyPageImage].self, forKey: .images) ?? []
        isBookmarked = try container.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        bookmarkTitle = try container.decodeIfPresent(String.self, forKey: .bookmarkTitle)
        paperColorHex = try container.decodeIfPresent(String.self, forKey: .paperColorHex) ?? "FFFFFF"
        sizePreset = try container.decodeIfPresent(NotyPageSizePreset.self, forKey: .sizePreset) ?? .letter
        orientation = try container.decodeIfPresent(NotyPageOrientation.self, forKey: .orientation) ?? .portrait
    }
}

struct NotyDocument: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var kind: NotyDocumentKind
    var folderID: UUID?
    var pages: [NotyPage]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        kind: NotyDocumentKind = .note,
        folderID: UUID? = nil,
        pages: [NotyPage] = [NotyPage()],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.folderID = folderID
        self.pages = pages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct NotyTrashedDocument: Identifiable, Codable, Hashable {
    var document: NotyDocument
    var deletedAt: Date
    var recoveryDirectoryName: String

    var id: UUID { document.id }
}

protocol OfficeConverting {
    func convertToPDF(fileURL: URL) async throws -> URL
}

enum NotyStoreError: LocalizedError {
    case invalidName
    case folderNotFound
    case documentNotFound
    case pageNotFound
    case unsupportedImportType(String)
    case invalidPDF
    case invalidOfficeDocument(String)
    case invalidImage
    case iCloudFolderUnavailable
    case invalidMirrorSnapshot(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a name before saving."
        case .folderNotFound:
            return "The selected folder no longer exists."
        case .documentNotFound:
            return "The selected document could not be found."
        case .pageNotFound:
            return "The selected page could not be found."
        case .unsupportedImportType(let ext):
            return "Noty cannot import .\(ext) files. Choose a PDF, DOC, or DOCX file."
        case .invalidPDF:
            return "The PDF could not be opened. The original file has been kept in the import package."
        case .invalidOfficeDocument(let message):
            return message
        case .invalidImage:
            return "The selected image could not be opened."
        case .iCloudFolderUnavailable:
            return "iCloud Drive could not access the selected backup folder. Select the folder again in Files."
        case .invalidMirrorSnapshot(let message):
            return "The Noty backup could not be read: \(message)"
        }
    }
}

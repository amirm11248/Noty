import CoreGraphics
import Foundation

enum NotyDocumentKind: String, Codable, CaseIterable {
    case note
    case pdf
    case book
    case whiteboard
}

enum NotyPageTemplate: String, Codable, CaseIterable {
    case blank
    case ruled
    case narrowRuled
    case grid
    case smallGrid
    case dots
    case cornell
    case weeklyPlanner
    case dailyPlanner
    case music
    case checklist
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
    var design: NotyNotebookCover?
    var symbol: String?
    var imageData: Data?
    var updatedAt: Date?

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil, design: NotyNotebookCover? = nil, symbol: String? = nil, imageData: Data? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.design = design
        self.symbol = symbol
        self.imageData = imageData
        self.updatedAt = updatedAt
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
    var paddingScale: Double?
    var contentInsetScale: Double { max(paddingScale ?? 1, 0.01) }

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
        self.paddingScale = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, x, y, width, height, fontSize, fontName
        case isBold, isItalic, isUnderlined, colorHex, alignment, paddingScale
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
        paddingScale = try container.decodeIfPresent(Double.self, forKey: .paddingScale)
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
    var cropX: Double?
    var cropY: Double?
    var cropWidth: Double?
    var cropHeight: Double?

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
    /// HTML used by the web editor. iOS preserves it even when it does not render it.
    var webHTML: String?
    var isBookmarked: Bool
    var bookmarkTitle: String?
    var paperColorHex: String
    var sizePreset: NotyPageSizePreset
    var orientation: NotyPageOrientation
    var isCover: Bool
    var customWidth: Double?
    var customHeight: Double?
    var viewportCenterX: Double?
    var viewportCenterY: Double?
    var canvasOffsetX: Double?
    var canvasOffsetY: Double?

    init(
        id: UUID = UUID(),
        template: NotyPageTemplate = .blank,
        sourcePageIndex: Int? = nil,
        textBoxes: [NotyTextBox] = [],
        images: [NotyPageImage] = [],
        webHTML: String? = nil,
        isBookmarked: Bool = false,
        bookmarkTitle: String? = nil,
        paperColorHex: String = "FFFFFF",
        sizePreset: NotyPageSizePreset = .letter,
        orientation: NotyPageOrientation = .portrait,
        isCover: Bool = false,
        customWidth: Double? = nil,
        customHeight: Double? = nil
    ) {
        self.id = id
        self.template = template
        self.sourcePageIndex = sourcePageIndex
        self.textBoxes = textBoxes
        self.images = images
        self.webHTML = webHTML
        self.isBookmarked = isBookmarked
        self.bookmarkTitle = bookmarkTitle
        self.paperColorHex = paperColorHex
        self.sizePreset = sizePreset
        self.orientation = orientation
        self.isCover = isCover
        self.customWidth = customWidth
        self.customHeight = customHeight
    }

    var canvasOffset: CGPoint { CGPoint(x: canvasOffsetX ?? 0, y: canvasOffsetY ?? 0) }

    var canvasSize: CGSize {
        if let customWidth, let customHeight, customWidth.isFinite, customHeight.isFinite, customWidth > 0, customHeight > 0 { return CGSize(width: customWidth, height: customHeight) }
        let base = sizePreset.portraitSize
        if orientation == .landscape && base.width != base.height {
            return CGSize(width: base.height, height: base.width)
        }
        return base
    }

    private enum CodingKeys: String, CodingKey {
        case id, template, sourcePageIndex, textBoxes, images, webHTML, isBookmarked, bookmarkTitle
        case paperColorHex, sizePreset, orientation, isCover, customWidth, customHeight, viewportCenterX, viewportCenterY, canvasOffsetX, canvasOffsetY
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        template = try container.decodeIfPresent(NotyPageTemplate.self, forKey: .template) ?? .blank
        sourcePageIndex = try container.decodeIfPresent(Int.self, forKey: .sourcePageIndex)
        textBoxes = try container.decodeIfPresent([NotyTextBox].self, forKey: .textBoxes) ?? []
        images = try container.decodeIfPresent([NotyPageImage].self, forKey: .images) ?? []
        webHTML = try container.decodeIfPresent(String.self, forKey: .webHTML)
        isBookmarked = try container.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        bookmarkTitle = try container.decodeIfPresent(String.self, forKey: .bookmarkTitle)
        paperColorHex = try container.decodeIfPresent(String.self, forKey: .paperColorHex) ?? "FFFFFF"
        sizePreset = try container.decodeIfPresent(NotyPageSizePreset.self, forKey: .sizePreset) ?? .letter
        orientation = try container.decodeIfPresent(NotyPageOrientation.self, forKey: .orientation) ?? .portrait
        isCover = try container.decodeIfPresent(Bool.self, forKey: .isCover) ?? false
        customWidth = try container.decodeIfPresent(Double.self, forKey: .customWidth)
        customHeight = try container.decodeIfPresent(Double.self, forKey: .customHeight)
        viewportCenterX = try container.decodeIfPresent(Double.self, forKey: .viewportCenterX)
        viewportCenterY = try container.decodeIfPresent(Double.self, forKey: .viewportCenterY)
        canvasOffsetX = try container.decodeIfPresent(Double.self, forKey: .canvasOffsetX)
        canvasOffsetY = try container.decodeIfPresent(Double.self, forKey: .canvasOffsetY)
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
    var cover: NotyNotebookCover?
    var studyCards: [NotyStudyCard]?
    var audioClips: [NotyAudioClip]?

    init(
        id: UUID = UUID(),
        title: String,
        kind: NotyDocumentKind = .note,
        folderID: UUID? = nil,
        pages: [NotyPage] = [NotyPage()],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        cover: NotyNotebookCover? = nil,
        studyCards: [NotyStudyCard]? = nil,
        audioClips: [NotyAudioClip]? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.folderID = folderID
        self.pages = pages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cover = cover
        self.studyCards = studyCards
        self.audioClips = audioClips
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
            return "Noty could not access the selected sync folder. Select the same folder again in Files."
        case .invalidMirrorSnapshot(let message):
            return "The Noty sync data could not be read: \(message)"
        }
    }
}

struct NotyNotebookCover: Codable, Hashable {
    var style: NotyCoverStyle = .gradient
    var colorHex: String = "5267A9"
    var imageFileName: String?
}

enum NotyCoverStyle: String, Codable, CaseIterable, Identifiable {
    case gradient, linen, geometric, minimal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct NotyStudyCard: Identifiable, Codable, Hashable {
    var id = UUID()
    var question: String
    var answer: String
}

struct NotyAudioClip: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var fileName: String
    var duration: Double
    var createdAt: Date = .now
    var pageID: UUID?
}

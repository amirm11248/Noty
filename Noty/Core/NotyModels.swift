import Foundation

enum NotyDocumentKind: String, Codable, CaseIterable {
    case note
    case pdf
    case book
}

enum NotyPageTemplate: String, Codable, CaseIterable {
    case blank
    case ruled
    case grid
    case dots
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

    init(
        id: UUID = UUID(),
        text: String,
        x: Double = 24,
        y: Double = 24,
        width: Double = 564,
        height: Double = 120,
        fontSize: Double = 16
    ) {
        self.id = id
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.fontSize = fontSize
    }
}

struct NotyPage: Identifiable, Codable, Hashable {
    var id: UUID
    var template: NotyPageTemplate
    /// Zero-based page index in the imported source PDF, when this page is PDF-backed.
    var sourcePageIndex: Int?
    var textBoxes: [NotyTextBox]

    init(
        id: UUID = UUID(),
        template: NotyPageTemplate = .blank,
        sourcePageIndex: Int? = nil,
        textBoxes: [NotyTextBox] = []
    ) {
        self.id = id
        self.template = template
        self.sourcePageIndex = sourcePageIndex
        self.textBoxes = textBoxes
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
        case .iCloudFolderUnavailable:
            return "iCloud Drive could not access the selected backup folder. Select the folder again in Files."
        case .invalidMirrorSnapshot(let message):
            return "The Noty backup could not be read: \(message)"
        }
    }
}

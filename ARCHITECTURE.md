# Noty implementation contract

Native iPadOS 18+ SwiftUI app. The project is generated from `project.yml` with XcodeGen. Source files belong under `Noty/` and are automatically included.

## Ownership

- `Noty/Core/`: shared models, local store, import and iCloud Drive mirror.
- `Noty/Editor/`: PencilKit page editor, page actions, text boxes, PDF and image export.
- `Noty/Library/` and `Noty/Sync/OneDriveService.swift`: library UI and OneDrive Files-provider PDF mirror.
- Root agent owns `project.yml`, `Noty/NotyApp.swift`, build, run and integration review.

## Shared API

Core agent provides:

```swift
enum NotyDocumentKind: String, Codable, CaseIterable { case note, pdf, book }
enum NotyPageTemplate: String, Codable, CaseIterable { case blank, ruled, grid, dots }
struct NotyFolder: Identifiable, Codable, Hashable { var id: UUID; var name: String; var parentID: UUID? }
struct NotyTextBox: Identifiable, Codable, Hashable { var id: UUID; var text: String; var x: Double; var y: Double; var width: Double; var height: Double; var fontSize: Double }
struct NotyPage: Identifiable, Codable, Hashable { var id: UUID; var template: NotyPageTemplate; var sourcePageIndex: Int?; var textBoxes: [NotyTextBox] }
struct NotyDocument: Identifiable, Codable, Hashable { var id: UUID; var title: String; var kind: NotyDocumentKind; var folderID: UUID?; var pages: [NotyPage]; var createdAt: Date; var updatedAt: Date }
@MainActor @Observable final class NotyStore {
  var folders: [NotyFolder]
  var documents: [NotyDocument]
  var syncStatus: String
  init()
  func createFolder(name: String, parentID: UUID?)
  func renameFolder(id: UUID, name: String)
  func deleteFolder(id: UUID)
  func createDocument(title: String, kind: NotyDocumentKind, folderID: UUID?) -> NotyDocument
  func renameDocument(id: UUID, title: String)
  func moveDocument(id: UUID, to folderID: UUID?)
  func deleteDocument(id: UUID)
  func addPage(documentID: UUID, after pageID: UUID?, template: NotyPageTemplate)
  func movePage(documentID: UUID, from: IndexSet, to: Int)
  func deletePage(documentID: UUID, pageID: UUID)
  func updateTextBoxes(documentID: UUID, pageID: UUID, textBoxes: [NotyTextBox])
  func saveDrawing(_ drawing: PKDrawing, documentID: UUID, pageID: UUID)
  func drawing(documentID: UUID, pageID: UUID) -> PKDrawing
  func sourcePDF(documentID: UUID) -> PDFDocument?
  func importDocument(from url: URL, folderID: UUID?, converter: OfficeConverting?) async throws -> NotyDocument
  func configureICloudMirror(folderURL: URL) throws
  func syncICloudMirror() async
}
protocol OfficeConverting { func convertToPDF(fileURL: URL) async throws -> URL }
```

The core agent may add signatures, but should keep these stable or message the others immediately. Store maintains authoritative document data and persists every mutation. Save imported original DOCX alongside the PDF. Page coordinates use a 612 × 792 point canvas so editor and export agree.

Editor agent provides `DocumentEditorView(documentID: UUID, store: NotyStore)` and `NotyExportService` with `exportPDF(documentID:store:) throws -> URL` and `exportPageImage(documentID:pageID:store:) throws -> URL`.

Library agent provides `LibraryView(store: NotyStore, oneDrive: OneDriveService)`, with a user-selected writable OneDrive folder accessed through the Files picker. OneDriveService mirrors exported PDFs into that folder; it does not require Microsoft Graph. Library opens editor via `DocumentEditorView`.

## Functional priorities

1. Reliable local persistence, import PDF/DOCX, folder/book creation, PencilKit writing, page controls, text boxes and export.
2. Minimal Notion-inspired visual language: warm white, ink grey, quiet borders, clear typography, simple iconography; comfortable on iPad and Apple Pencil.
3. Cloud mirrors report real status and errors. iCloud Drive and OneDrive folder access is user selected in Files and persisted using iOS directory bookmarks that resolve back to security-scoped URLs. Foreground edits are mirrored promptly and `com.malik.noty.sync` is registered as a BGProcessingTask fallback for later retry opportunities. DOC/DOCX conversion stays on-device because the user's school blocks Microsoft Graph. Do not claim guaranteed background timing or provider upload timing; iPadOS schedules both.

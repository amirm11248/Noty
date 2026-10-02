import Foundation
import PencilKit

/// Shares the canvas undo stack so ink and page objects can be undone from one toolbar.
@MainActor
final class NotyPageObjectHistory {
    var onChange: (() -> Void)?

    func updateContent(store: NotyStore, undoManager: UndoManager?, documentID: UUID, pageID: UUID, content: NotyPageContent, actionName: String, applyDrawing: @escaping (PKDrawing) -> Void) {
        guard let page = store.documents.first(where: { $0.id == documentID })?.pages.first(where: { $0.id == pageID }) else { return }
        let origin = page.canvasOffset
        let previous = NotyPageContent(page: page, drawing: store.drawing(documentID: documentID, pageID: pageID))
        store.saveDrawing(content.drawing, documentID: documentID, pageID: pageID)
        if page.textBoxes != content.textBoxes { store.updateTextBoxes(documentID: documentID, pageID: pageID, textBoxes: content.textBoxes) }
        if page.images != content.images { store.updatePageImages(documentID: documentID, pageID: pageID, images: content.images, retainAssetsForUndo: true) }
        applyDrawing(content.drawing)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] history in
            history.updateContent(store: store, undoManager: undoManager, documentID: documentID, pageID: pageID, content: previous.translated(by: history.translationSince(origin, store: store, documentID: documentID, pageID: pageID)), actionName: actionName, applyDrawing: applyDrawing)
        }
        undoManager?.setActionName(actionName)
        onChange?()
    }

    func updateTextBoxes(store: NotyStore, undoManager: UndoManager?, documentID: UUID, pageID: UUID, textBoxes: [NotyTextBox]) {
        guard let previous = store.documents.first(where: { $0.id == documentID })?.pages.first(where: { $0.id == pageID })?.textBoxes,
              previous != textBoxes else { return }
        let origin = store.documents.first(where: { $0.id == documentID })?.pages.first(where: { $0.id == pageID })?.canvasOffset ?? .zero
        store.updateTextBoxes(documentID: documentID, pageID: pageID, textBoxes: textBoxes)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] history in
            history.updateTextBoxes(store: store, undoManager: undoManager, documentID: documentID, pageID: pageID, textBoxes: previous.map { $0.translated(by: history.translationSince(origin, store: store, documentID: documentID, pageID: pageID)) })
        }
        undoManager?.setActionName("Text edit")
        onChange?()
    }

    func updateImages(store: NotyStore, undoManager: UndoManager?, documentID: UUID, pageID: UUID, images: [NotyPageImage]) {
        guard let previous = store.documents.first(where: { $0.id == documentID })?.pages.first(where: { $0.id == pageID })?.images,
              previous != images else { return }
        store.updatePageImages(documentID: documentID, pageID: pageID, images: images, retainAssetsForUndo: true)
        registerImageChange(store: store, undoManager: undoManager, documentID: documentID, pageID: pageID, previous: previous)
    }

    func addImage(store: NotyStore, undoManager: UndoManager?, data: Data, documentID: UUID, pageID: UUID) throws -> NotyPageImage {
        let previous = store.documents.first(where: { $0.id == documentID })?.pages.first(where: { $0.id == pageID })?.images ?? []
        let image = try store.addPageImage(data: data, documentID: documentID, pageID: pageID)
        registerImageChange(store: store, undoManager: undoManager, documentID: documentID, pageID: pageID, previous: previous)
        return image
    }

    private func registerImageChange(store: NotyStore, undoManager: UndoManager?, documentID: UUID, pageID: UUID, previous: [NotyPageImage]) {
        let origin = store.documents.first(where: { $0.id == documentID })?.pages.first(where: { $0.id == pageID })?.canvasOffset ?? .zero
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] history in
            history.updateImages(store: store, undoManager: undoManager, documentID: documentID, pageID: pageID, images: previous.map { $0.translated(by: history.translationSince(origin, store: store, documentID: documentID, pageID: pageID)) })
        }
        undoManager?.setActionName("Photo edit")
        onChange?()
    }
    private func translationSince(_ origin: CGPoint, store: NotyStore, documentID: UUID, pageID: UUID) -> CGPoint {
        let current = store.documents.first(where: { $0.id == documentID })?.pages.first(where: { $0.id == pageID })?.canvasOffset ?? .zero
        return CGPoint(x: current.x - origin.x, y: current.y - origin.y)
    }
}

private extension NotyTextBox {
    func translated(by offset: CGPoint) -> Self { var copy = self; copy.x += Double(offset.x); copy.y += Double(offset.y); return copy }
}
private extension NotyPageImage {
    func translated(by offset: CGPoint) -> Self { var copy = self; copy.x += Double(offset.x); copy.y += Double(offset.y); return copy }
}
private extension NotyPageContent {
    func translated(by offset: CGPoint) -> Self {
        var copy = self
        copy.drawing = drawing.transformed(using: CGAffineTransform(translationX: offset.x, y: offset.y))
        copy.textBoxes = textBoxes.map { $0.translated(by: offset) }
        copy.images = images.map { $0.translated(by: offset) }
        return copy
    }
}

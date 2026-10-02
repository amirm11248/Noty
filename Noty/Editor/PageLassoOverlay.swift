import PencilKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct PageLassoOverlay: View {
    let paper: CGSize
    let scale: CGFloat
    let shape: NotyLassoShape
    let filter: NotySelectionFilter
    let store: NotyStore
    let documentID: UUID
    let pageID: UUID
    @Binding var selection: NotyPageSelection?
    let prepare: () -> NotyPageContent
    let preview: (NotyPageContent?) -> Void
    let commit: (NotyPageContent, String) -> Void

    @State private var points: [CGPoint] = []
    @State private var original: NotyPageContent?
    @State private var activeSelection: NotyPageSelection?
    @State private var origin = CGPoint.zero
    @State private var transform = CGAffineTransform.identity
    @State private var interaction: Interaction?
    @State private var errorMessage: String?
    @State private var copied = false

    private enum Interaction { case draw, move, resize }
    private var unit: CGFloat { 1 / max(scale, 0.05) }
    private var displayedBounds: CGRect? { selection.map { $0.bounds.applying(transform) } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LassoCaptureView(onInput: input)
            if !points.isEmpty {
                Path { path in
                    if shape == .rectangle, let first = points.first, let last = points.last {
                        path.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
                    } else {
                        path.addLines(points)
                        path.closeSubpath()
                    }
                }.fill(NotionTheme.accent.opacity(0.08)).allowsHitTesting(false)
                Path { path in
                    if shape == .rectangle, let first = points.first, let last = points.last {
                        path.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
                    } else { path.addLines(points); path.closeSubpath() }
                }.stroke(NotionTheme.accent, style: StrokeStyle(lineWidth: 1.5 * unit, dash: [4 * unit, 3 * unit])).allowsHitTesting(false)
            }
            if let bounds = displayedBounds, let selection {
                RoundedRectangle(cornerRadius: 4 * unit)
                    .stroke(NotionTheme.accent, style: StrokeStyle(lineWidth: 1.5 * unit, dash: [5 * unit, 3 * unit]))
                    .frame(width: bounds.width, height: bounds.height)
                    .position(x: bounds.midX, y: bounds.midY)
                    .allowsHitTesting(false)
                Circle().fill(NotionTheme.accent).overlay(Circle().stroke(.white, lineWidth: 2 * unit))
                    .frame(width: 12 * unit, height: 12 * unit)
                    .position(x: bounds.maxX, y: bounds.maxY).allowsHitTesting(false)
                if interaction == nil {
                    Menu {
                        Button("Copy", systemImage: "doc.on.doc") { copySelection(cut: false) }
                        Button("Cut", systemImage: "scissors") { copySelection(cut: true) }
                        Button("Duplicate", systemImage: "plus.square.on.square") { duplicateSelection() }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            let content = prepare()
                            commit(selection.deleting(from: content), "Delete selection")
                            self.selection = nil
                        }
                        Button("Deselect", systemImage: "xmark") { self.selection = nil }
                    } label: {
                        HStack(spacing: 5 * unit) {
                            Text(copied ? "Copied" : "\(selection.count) selected")
                            Image(systemName: "ellipsis")
                        }.font(.system(size: 12 * unit, weight: .medium))
                            .padding(.horizontal, 9 * unit).frame(height: 32 * unit)
                            .background(.regularMaterial, in: Capsule())
                            .foregroundStyle(NotionTheme.ink)
                    }.fixedSize()
                        .position(x: min(max(bounds.midX, 72 * unit), max(paper.width - 72 * unit, 72 * unit)), y: bounds.minY >= 38 * unit ? bounds.minY - 21 * unit : min(bounds.maxY + 22 * unit, paper.height - 20 * unit))
                        .accessibilityLabel("Selection actions")
                        .accessibilityHint("Drag the selection to move it or drag its bottom-right corner to resize")
                }
            }
        }
        .frame(width: paper.width, height: paper.height)
        .onDisappear { preview(nil) }
        .onChange(of: filter) { _, _ in selection = nil }
        .onChange(of: shape) { _, _ in selection = nil }
        .alert("Selection unavailable", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func input(_ phase: LassoCaptureView.Phase, _ location: CGPoint) {
        switch phase {
        case .began:
            copied = false
            origin = location; transform = .identity
            original = prepare()
            activeSelection = selection
            if let selection, hypot(location.x - selection.bounds.maxX, location.y - selection.bounds.maxY) < 22 * unit {
                interaction = .resize
            } else if let selection, selection.bounds.insetBy(dx: -4 * unit, dy: -4 * unit).contains(location) {
                interaction = .move
            } else { interaction = .draw; selection = nil; points = [location] }
        case .changed:
            guard let original, let interaction else { return }
            if interaction == .draw {
                if let last = points.last, hypot(location.x - last.x, location.y - last.y) >= unit { points.append(location) }
            } else if let activeSelection {
                if interaction == .move {
                    transform = activeSelection.translated(by: CGSize(width: location.x - origin.x, height: location.y - origin.y), within: paper)
                } else {
                    let bounds = activeSelection.bounds
                    let ratio = ((location.x - origin.x) * bounds.width + (location.y - origin.y) * bounds.height) / max(bounds.width * bounds.width + bounds.height * bounds.height, 1)
                    transform = activeSelection.scaled(by: 1 + ratio, within: paper)
                }
                preview(activeSelection.transforming(original, by: transform))
            }
        case .ended:
            guard let original, let interaction else { reset(); return }
            if interaction == .draw {
                if hypot(location.x - origin.x, location.y - origin.y) < 4 * unit, points.count < 4 {
                    let radius = 7 * unit
                    selection = NotyPageSelection.select(points: [CGPoint(x: location.x - radius, y: location.y - radius), CGPoint(x: location.x + radius, y: location.y + radius)], shape: .rectangle, filter: filter, content: original)
                } else {
                    points.append(location)
                    selection = NotyPageSelection.select(points: points, shape: shape, filter: filter, content: original)
                }
            } else if var activeSelection {
                let moved = activeSelection.transforming(original, by: transform)
                preview(nil)
                if !transform.isIdentity { commit(moved, interaction == .move ? "Move selection" : "Resize selection") }
                activeSelection.bounds = activeSelection.bounds.applying(transform)
                selection = activeSelection
            }
            reset()
        case .cancelled:
            preview(nil); reset()
        }
    }

    private func reset() { original = nil; activeSelection = nil; interaction = nil; transform = .identity; points = [] }
    private func copySelection(cut: Bool) {
        guard let selection else { return }
        let content = prepare()
        do {
            try NotySelectionClipboard.copy(selection: selection, content: content, store: store, documentID: documentID, pageID: pageID)
            if cut { commit(selection.deleting(from: content), "Cut selection"); self.selection = nil }
            else { copied = true }
        } catch { errorMessage = error.localizedDescription }
    }
    private func duplicateSelection() {
        guard let selection else { return }
        let content = prepare()
        do {
            let payload = try NotySelectionClipboard.payload(selection: selection, content: content, store: store, documentID: documentID, pageID: pageID)
            let result = try NotySelectionClipboard.inserting(payload, into: content, at: CGPoint(x: selection.bounds.minX + 20, y: selection.bounds.minY + 20), paper: paper, store: store, documentID: documentID, pageID: pageID)
            commit(result.content, "Duplicate selection")
            self.selection = result.selection
        } catch { errorMessage = error.localizedDescription }
    }
}

/// Claims a single-pointer lasso immediately, leaving two-finger pinch gestures
/// available to the surrounding page. Direct manipulation uses paper coordinates.
struct LassoCaptureView: UIViewRepresentable {
    enum Phase { case began, changed, ended, cancelled }
    let onInput: (Phase, CGPoint) -> Void
    func makeUIView(context: Context) -> InputView {
        let view = InputView()
        view.backgroundColor = .clear; view.isOpaque = false; view.isMultipleTouchEnabled = true
        view.capture.onInput = onInput
        view.addGestureRecognizer(view.capture)
        return view
    }
    func updateUIView(_ view: InputView, context: Context) { view.capture.onInput = onInput }

    final class InputView: UIView { let capture = Capture() }
    final class Capture: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var onInput: ((Phase, CGPoint) -> Void)?
        private var pointer: UITouch?
        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            delegate = self
            addTarget(self, action: #selector(changed))
        }
        convenience init() { self.init(target: nil, action: nil) }
        @objc private func changed() {
            guard let pointer else { return }
            let location = pointer.location(in: view)
            switch state {
            case .began: onInput?(.began, location)
            case .changed: onInput?(.changed, location)
            case .ended: onInput?(.ended, location)
            case .cancelled: onInput?(.cancelled, location)
            default: break
            }
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if let pointer {
                if pointer.type != .pencil { state = .cancelled }
                return
            }
            guard touches.count == 1, let touch = touches.first else { state = .failed; return }
            pointer = touch; state = .began
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            if let pointer, touches.contains(pointer) { state = .changed }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            if let pointer, touches.contains(pointer) { state = .ended }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
        override func reset() { pointer = nil }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPinchGestureRecognizer
        }
    }
}

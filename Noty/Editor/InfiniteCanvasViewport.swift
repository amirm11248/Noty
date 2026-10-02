import SwiftUI
import UIKit

/// A zoomable viewport over an expanding board. Growth translates existing content
/// and the viewport together; the user never reaches a fixed page boundary.
struct InfiniteCanvasViewport<Content: View>: UIViewRepresentable {
    let canvasSize: CGSize
    let initialCenter: CGPoint
    let paperColor: UIColor
    let panWithTwoFingers: Bool
    let onExpand: (NotyCanvasExpansion) -> Bool
    let onViewportSettled: (CGPoint) -> Void
    @ViewBuilder var content: Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = WhiteboardScrollView()
        scroll.backgroundColor = paperColor
        scroll.minimumZoomScale = 0.25; scroll.maximumZoomScale = 4
        scroll.bounces = false; scroll.bouncesZoom = false
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let host = context.coordinator.host
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(origin: .zero, size: canvasSize)
        scroll.addSubview(host.view)
        scroll.contentSize = canvasSize
        scroll.delegate = context.coordinator
        scroll.onLayout = { [weak coordinator = context.coordinator] scroll in coordinator?.positionIfNeeded(scroll) }
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.isUpdating = true
        coordinator.host.rootView = content
        scroll.backgroundColor = paperColor
        scroll.panGestureRecognizer.minimumNumberOfTouches = panWithTwoFingers ? 2 : 1
        let changedSize = coordinator.lastSize != canvasSize
        if changedSize {
            let offset = scroll.contentOffset
            let zoom = scroll.zoomScale
            coordinator.host.view.transform = .identity
            coordinator.host.view.bounds = CGRect(origin: .zero, size: canvasSize)
            coordinator.host.view.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            coordinator.host.view.center = CGPoint(x: canvasSize.width * zoom / 2, y: canvasSize.height * zoom / 2)
            scroll.contentSize = CGSize(width: canvasSize.width * zoom, height: canvasSize.height * zoom)
            if let expansion = coordinator.pendingExpansion {
                scroll.contentOffset = CGPoint(x: offset.x + expansion.left * zoom, y: offset.y + expansion.top * zoom)
                coordinator.pendingExpansion = nil
            }
            coordinator.lastSize = canvasSize
        }
        coordinator.isUpdating = false
        coordinator.positionIfNeeded(scroll)
    }

    static func dismantleUIView(_ scroll: UIScrollView, coordinator: Coordinator) {
        coordinator.settle(scroll)
        scroll.delegate = nil
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: InfiniteCanvasViewport
        let host: UIHostingController<Content>
        var lastSize: CGSize
        var pendingExpansion: NotyCanvasExpansion?
        var isUpdating = false
        var positioned = false
        init(_ parent: InfiniteCanvasViewport) {
            self.parent = parent; host = UIHostingController(rootView: parent.content); lastSize = parent.canvasSize
        }
        func positionIfNeeded(_ scroll: UIScrollView) {
            guard !positioned, scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
            positioned = true
            scroll.contentOffset = CGPoint(x: max(0, parent.initialCenter.x - scroll.bounds.width / 2), y: max(0, parent.initialCenter.y - scroll.bounds.height / 2))
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }
        func scrollViewDidScroll(_ scroll: UIScrollView) {
            guard positioned, !isUpdating, pendingExpansion == nil else { return }
            let zoom = max(scroll.zoomScale, 0.01)
            let visible = CGRect(x: scroll.contentOffset.x / zoom, y: scroll.contentOffset.y / zoom, width: scroll.bounds.width / zoom, height: scroll.bounds.height / zoom)
            let expansion = NotyCanvasExpansion.needed(visible: visible, canvas: parent.canvasSize)
            guard expansion.isValid else { return }
            pendingExpansion = expansion
            if !parent.onExpand(expansion) { pendingExpansion = nil }
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle(scrollView) } }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle(scrollView) }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { settle(scrollView) }
        func settle(_ scroll: UIScrollView) {
            guard positioned, pendingExpansion == nil else { return }
            parent.onViewportSettled(CGPoint(x: (scroll.contentOffset.x + scroll.bounds.width / 2) / scroll.zoomScale,
                                            y: (scroll.contentOffset.y + scroll.bounds.height / 2) / scroll.zoomScale))
        }
    }
}

/// Repeating tiles avoid generating a giant vector path as the board grows.
struct WhiteboardPaperSurface: UIViewRepresentable {
    let template: NotyPageTemplate
    let colorHex: String
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.isUserInteractionEnabled = false; return view }
    func updateUIView(_ view: UIView, context: Context) {
        let paper = UIColor(notyHex: colorHex)
        guard template != .blank else { view.backgroundColor = paper; return }
        let spacing: CGFloat = template == .smallGrid ? 16 : template == .narrowRuled ? 20 : 24
        let tile = UIGraphicsImageRenderer(size: CGSize(width: spacing, height: spacing)).image { renderer in
            paper.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: spacing, height: spacing))
            let ink = (paper.notyIsDark ? UIColor.white : UIColor.darkGray).withAlphaComponent(0.2)
            let cg = renderer.cgContext
            cg.setStrokeColor(ink.cgColor); cg.setLineWidth(0.6)
            if template == .dots {
                ink.setFill(); cg.fillEllipse(in: CGRect(x: spacing / 2 - 0.8, y: spacing / 2 - 0.8, width: 1.6, height: 1.6))
            } else {
                cg.move(to: CGPoint(x: 0, y: 0)); cg.addLine(to: CGPoint(x: spacing, y: 0))
                if template != .ruled && template != .narrowRuled { cg.move(to: CGPoint(x: 0, y: 0)); cg.addLine(to: CGPoint(x: 0, y: spacing)) }
                cg.strokePath()
            }
        }
        view.backgroundColor = UIColor(patternImage: tile)
    }
}

private final class WhiteboardScrollView: UIScrollView {
    var onLayout: ((UIScrollView) -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?(self) }
}

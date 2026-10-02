import CoreGraphics
import Foundation

struct NotyCanvasExpansion: Equatable {
    var left: CGFloat = 0
    var top: CGFloat = 0
    var right: CGFloat = 0
    var bottom: CGFloat = 0

    var isValid: Bool {
        let values = [left, top, right, bottom]
        return values.allSatisfy { $0.isFinite && $0 >= 0 } && values.contains { $0 > 0 }
    }
    var translation: CGAffineTransform { CGAffineTransform(translationX: left, y: top) }
    func expanding(_ size: CGSize) -> CGSize { CGSize(width: size.width + left + right, height: size.height + top + bottom) }

    static func needed(visible: CGRect, canvas: CGSize) -> Self {
        let margin: CGFloat = 384
        let step = ceil(max(2048, max(visible.width, visible.height)) / 48) * 48
        return Self(left: visible.minX < margin ? step : 0,
                    top: visible.minY < margin ? step : 0,
                    right: visible.maxX > canvas.width - margin ? step : 0,
                    bottom: visible.maxY > canvas.height - margin ? step : 0)
    }
}

/// Shared page measurements keep the current-page indicator aligned with scrolling,
/// including notebooks with different page sizes and orientations.
struct NotyPageFlowLayout {
    struct Item {
        let id: UUID
        let size: CGSize
        let minY: CGFloat
        var maxY: CGFloat { minY + size.height }
    }
    let items: [Item]
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    static let spacing: CGFloat = 28
    static let inset: CGFloat = 24

    init(pages: [NotyPage], viewport: CGSize, zoom: CGFloat) {
        let availableWidth = max(viewport.width - Self.inset * 2, 100)
        let availableHeight = max(viewport.height - Self.inset * 2, 100)
        var nextY = Self.inset
        var width = viewport.width
        items = pages.map { page in
            let aspect = page.canvasSize.width / page.canvasSize.height
            let pageWidth = min(availableWidth, availableHeight * aspect, 880) * zoom
            let size = CGSize(width: pageWidth, height: pageWidth / aspect)
            defer { nextY += size.height + Self.spacing }
            width = max(width, size.width + Self.inset * 2)
            return Item(id: page.id, size: size, minY: nextY)
        }
        contentWidth = width
        contentHeight = max(viewport.height, nextY - Self.spacing + Self.inset)
    }

    func pageID(at y: CGFloat) -> UUID? {
        items.min { abs(($0.minY + $0.maxY) / 2 - y) < abs(($1.minY + $1.maxY) / 2 - y) }?.id
    }
}

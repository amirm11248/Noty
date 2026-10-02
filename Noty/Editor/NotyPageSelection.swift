import PencilKit
import UIKit

struct NotyPageContent {
    var drawing: PKDrawing
    var textBoxes: [NotyTextBox]
    var images: [NotyPageImage]

    init(page: NotyPage, drawing: PKDrawing) {
        self.drawing = drawing
        textBoxes = page.textBoxes
        images = page.images
    }
}

enum NotyLassoShape: String, CaseIterable {
    case freehand, rectangle
    var title: String { self == .freehand ? "Freehand" : "Rectangle" }
}

struct NotySelectionFilter: Equatable {
    var handwriting = true
    var text = true
    var photos = true
}

/// Selection is transient. Ink keeps PencilKit's native path, mask and pressure data.
struct NotyPageSelection {
    var strokeIndices: IndexSet
    var textIDs: Set<UUID>
    var imageIDs: Set<UUID>
    var bounds: CGRect
    var count: Int { strokeIndices.count + textIDs.count + imageIDs.count }

    static func select(points: [CGPoint], shape: NotyLassoShape, filter: NotySelectionFilter, content: NotyPageContent) -> Self? {
        guard points.count >= 2 else { return nil }
        let polygon: [CGPoint]
        if shape == .rectangle {
            let a = points[0], b = points[points.count - 1]
            polygon = corners(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
        } else { polygon = points }
        guard polygon.count >= 3 else { return nil }
        let region = enclosing(polygon)
        guard region.width > 2, region.height > 2 else { return nil }
        var strokes = IndexSet()
        var texts = Set<UUID>(), images = Set<UUID>()
        var bounds = CGRect.null
        if filter.handwriting {
            for (index, stroke) in content.drawing.strokes.enumerated() where !stroke.path.isEmpty && stroke.renderBounds.intersects(region) {
                // Sampling visible ranges avoids selecting an erased section of a stroke.
                let ranges = stroke.mask == nil ? [CGFloat(0)...CGFloat(max(stroke.path.count - 1, 0))] : stroke.maskedPathRanges
                let magnification = max(hypot(stroke.transform.a, stroke.transform.b), 0.1)
                var hit = false
                for range in ranges {
                    var previous: CGPoint?
                    for sample in stroke.path.interpolatedPoints(in: range, by: .distance(2 / magnification)) {
                        let point = sample.location.applying(stroke.transform)
                        if contains(point, in: polygon) || previous.map({ crosses($0, point, polygon: polygon) }) == true {
                            hit = true; break
                        }
                        previous = point
                    }
                    if hit { break }
                }
                if hit { strokes.insert(index); bounds = bounds.union(stroke.renderBounds) }
            }
        }
        if filter.text {
            for box in content.textBoxes {
                let rect = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
                if intersects(polygon, corners(rect)) { texts.insert(box.id); bounds = bounds.union(rect) }
            }
        }
        if filter.photos {
            for image in content.images {
                let rect = CGRect(x: image.x, y: image.y, width: image.width, height: image.height)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let angle = image.rotationDegrees * .pi / 180
                let rotation = CGAffineTransform(translationX: -center.x, y: -center.y)
                    .concatenating(CGAffineTransform(rotationAngle: angle))
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
                let rotated = corners(rect).map { $0.applying(rotation) }
                if intersects(polygon, rotated) { images.insert(image.id); bounds = bounds.union(enclosing(rotated)) }
            }
        }
        guard !bounds.isNull else { return nil }
        return Self(strokeIndices: strokes, textIDs: texts, imageIDs: images, bounds: bounds)
    }

    func translated(by delta: CGSize, within paper: CGSize) -> CGAffineTransform {
        func clamp(_ value: CGFloat, origin: CGFloat, extent: CGFloat, limit: CGFloat) -> CGFloat {
            guard extent <= limit else { return value }
            return min(max(value, -origin), limit - origin - extent)
        }
        return CGAffineTransform(translationX: clamp(delta.width, origin: bounds.minX, extent: bounds.width, limit: paper.width),
                                 y: clamp(delta.height, origin: bounds.minY, extent: bounds.height, limit: paper.height))
    }

    func scaled(by proposed: CGFloat, within paper: CGSize) -> CGAffineTransform {
        let maximum = max(0.1, min((paper.width - bounds.minX) / max(bounds.width, 1), (paper.height - bounds.minY) / max(bounds.height, 1)))
        let factor = min(max(proposed, 0.1), min(maximum, 8))
        return CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            .concatenating(CGAffineTransform(scaleX: factor, y: factor))
            .concatenating(CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }

    func transforming(_ original: NotyPageContent, by transform: CGAffineTransform) -> NotyPageContent {
        var result = original
        let factor = hypot(transform.a, transform.b)
        result.drawing = PKDrawing(strokes: original.drawing.strokes.enumerated().map { index, stroke in
            guard strokeIndices.contains(index) else { return stroke }
            var moved = stroke
            moved.transform = stroke.transform.concatenating(transform)
            return moved
        })
        result.textBoxes = original.textBoxes.map { box in
            guard textIDs.contains(box.id) else { return box }
            var moved = box
            let rect = CGRect(x: box.x, y: box.y, width: box.width, height: box.height).applying(transform)
            moved.x = rect.minX; moved.y = rect.minY; moved.width = rect.width; moved.height = rect.height
            moved.fontSize = box.fontSize * factor
            moved.paddingScale = box.contentInsetScale * factor
            return moved
        }
        result.images = original.images.map { image in
            guard imageIDs.contains(image.id) else { return image }
            var moved = image
            let rect = CGRect(x: image.x, y: image.y, width: image.width, height: image.height).applying(transform)
            moved.x = rect.minX; moved.y = rect.minY; moved.width = rect.width; moved.height = rect.height
            return moved
        }
        return result
    }

    func deleting(from content: NotyPageContent) -> NotyPageContent {
        var result = content
        result.drawing = PKDrawing(strokes: content.drawing.strokes.enumerated().compactMap { strokeIndices.contains($0.offset) ? nil : $0.element })
        result.textBoxes.removeAll { textIDs.contains($0.id) }
        result.images.removeAll { imageIDs.contains($0.id) }
        return result
    }

    func extracting(from content: NotyPageContent) -> NotyPageContent {
        var selected = content
        selected.drawing = PKDrawing(strokes: strokeIndices.compactMap { content.drawing.strokes.indices.contains($0) ? content.drawing.strokes[$0] : nil })
        selected.textBoxes = content.textBoxes.filter { textIDs.contains($0.id) }
        selected.images = content.images.filter { imageIDs.contains($0.id) }
        let all = Self(strokeIndices: IndexSet(integersIn: 0..<selected.drawing.strokes.count), textIDs: Set(selected.textBoxes.map(\.id)), imageIDs: Set(selected.images.map(\.id)), bounds: bounds)
        return all.transforming(selected, by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    }

    private static func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
    private static func enclosing(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    private static func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
        var inside = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if distance(point, to: a, b) < 0.5 { return true }
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }
    private static func distance(_ p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, 0.001), 0), 1)
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }
    private static func crosses(_ a: CGPoint, _ b: CGPoint, polygon: [CGPoint]) -> Bool {
        for i in polygon.indices {
            let c = polygon[i], d = polygon[(i + 1) % polygon.count]
            let ab = CGVector(dx: b.x - a.x, dy: b.y - a.y), cd = CGVector(dx: d.x - c.x, dy: d.y - c.y)
            let denominator = ab.dx * cd.dy - ab.dy * cd.dx
            if abs(denominator) < 0.0001 {
                if distance(c, to: a, b) < 0.5 || distance(d, to: a, b) < 0.5 { return true }
                continue
            }
            let ac = CGVector(dx: c.x - a.x, dy: c.y - a.y)
            let t = (ac.dx * cd.dy - ac.dy * cd.dx) / denominator
            let u = (ac.dx * ab.dy - ac.dy * ab.dx) / denominator
            if (0...1).contains(t), (0...1).contains(u) { return true }
        }
        return false
    }
    private static func intersects(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        guard enclosing(a).intersects(enclosing(b)) else { return false }
        return a.contains { contains($0, in: b) } || b.contains { contains($0, in: a) } || a.indices.contains { crosses(a[$0], a[($0 + 1) % a.count], polygon: b) }
    }
}

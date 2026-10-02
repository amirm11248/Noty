import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct NotyRecognizedShape {
    enum Kind { case line, rectangle, triangle, ellipse }
    let kind: Kind
    let points: [CGPoint]

    func stroke(ink: PKInk, width: CGFloat) -> PKStroke {
        // Duplicate polygon corners so PencilKit's spline keeps sharp angles.
        var controls: [CGPoint] = []
        for index in points.indices {
            let point = points[index]
            if index > 0 {
                let previous = points[index - 1]
                let count = max(1, Int(hypot(point.x - previous.x, point.y - previous.y) / 4))
                for step in 1..<count {
                    let t = CGFloat(step) / CGFloat(count)
                    controls.append(CGPoint(x: previous.x + (point.x - previous.x) * t, y: previous.y + (point.y - previous.y) * t))
                }
            }
            controls.append(contentsOf: kind == .ellipse ? [point] : [point, point, point])
        }
        let path = PKStrokePath(controlPoints: controls.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.005,
                          size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date())
        return PKStroke(ink: ink, path: path)
    }
}

/// Conservative geometric fitting: ordinary handwriting and open curves stay untouched.
enum NotyShapeRecognition {
    static func recognize(_ input: [CGPoint]) -> NotyRecognizedShape? {
        let points = deduplicate(input)
        guard points.count >= 6, let first = points.first, let last = points.last else { return nil }
        let bounds = boundingBox(points)
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal >= 36 else { return nil }
        let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + distance($1.0, $1.1) }
        let chord = distance(first, last)
        if chord >= 36, chord / max(length, 1) > 0.92,
           points.allSatisfy({ distanceToSegment($0, first, last) < max(5, diagonal * 0.045) }) {
            return NotyRecognizedShape(kind: .line, points: [first, last])
        }
        guard bounds.width >= 22, bounds.height >= 22,
              chord < max(12, diagonal * 0.18), length < diagonal * 4.2 else { return nil }

        var ring = points
        if chord > 1 { ring.append(first) }
        let farthestIndex = ring.indices.max(by: { distance(first, ring[$0]) < distance(first, ring[$1]) }) ?? 0
        guard farthestIndex > 0, farthestIndex < ring.count - 1 else { return nil }
        let firstHalf = simplify(Array(ring[...farthestIndex]), tolerance: diagonal * 0.055)
        let secondHalf = simplify(Array(ring[farthestIndex...]), tolerance: diagonal * 0.055)
        var corners = Array(firstHalf.dropLast()) + Array(secondHalf.dropLast())
        var changed = true
        while changed && corners.count > 3 {
            changed = false
            for index in corners.indices {
                let previous = corners[(index + corners.count - 1) % corners.count]
                let next = corners[(index + 1) % corners.count]
                if distanceToSegment(corners[index], previous, next) < diagonal * 0.055 {
                    corners.remove(at: index); changed = true; break
                }
            }
        }

        if corners.count == 4 && isRectangular(corners) {
            let fitted = rectangle(corners, samples: ring)
            if meanDistance(ring, to: fitted) < diagonal * 0.035 {
                return NotyRecognizedShape(kind: .rectangle, points: fitted)
            }
        }
        if corners.count == 3 {
            let triangle = corners + [corners[0]]
            let area = abs(cross(corners[0], corners[1], corners[2])) / 2
            if area > bounds.width * bounds.height * 0.18,
               meanDistance(ring, to: triangle) < diagonal * 0.03 {
                return NotyRecognizedShape(kind: .triangle, points: triangle)
            }
        }

        let samples = resample(ring, count: 80)
        let center = CGPoint(x: samples.map(\.x).reduce(0, +) / CGFloat(samples.count), y: samples.map(\.y).reduce(0, +) / CGFloat(samples.count))
        let xx = samples.reduce(CGFloat.zero) { $0 + pow($1.x - center.x, 2) }
        let yy = samples.reduce(CGFloat.zero) { $0 + pow($1.y - center.y, 2) }
        let xy = samples.reduce(CGFloat.zero) { $0 + ($1.x - center.x) * ($1.y - center.y) }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        let local = samples.map { rotate($0, around: center, by: -angle) }
        let localBounds = boundingBox(local)
        let localCenter = CGPoint(x: localBounds.midX, y: localBounds.midY)
        let rx = localBounds.width / 2, ry = localBounds.height / 2
        guard min(rx, ry) >= 11 else { return nil }
        let radialError = local.reduce(CGFloat.zero) { sum, point in
            sum + abs(hypot((point.x - localCenter.x) / rx, (point.y - localCenter.y) / ry) - 1)
        } / CGFloat(local.count)
        guard radialError < 0.10 else { return nil }
        let ellipse = (0...80).map { index -> CGPoint in
            let theta = CGFloat(index) / 80 * .pi * 2
            return rotate(CGPoint(x: localCenter.x + rx * cos(theta), y: localCenter.y + ry * sin(theta)), around: center, by: angle)
        }
        return NotyRecognizedShape(kind: .ellipse, points: ellipse)
    }

    private static func isRectangular(_ corners: [CGPoint]) -> Bool {
        corners.indices.allSatisfy { index in
            let a = corners[(index + 3) % 4], b = corners[index], c = corners[(index + 1) % 4]
            let dot = (a.x - b.x) * (c.x - b.x) + (a.y - b.y) * (c.y - b.y)
            return abs(dot / max(distance(a, b) * distance(b, c), 1)) < 0.3
        }
    }

    private static func rectangle(_ corners: [CGPoint], samples: [CGPoint]) -> [CGPoint] {
        let longest = corners.indices.max(by: { distance(corners[$0], corners[($0 + 1) % 4]) < distance(corners[$1], corners[($1 + 1) % 4]) }) ?? 0
        let a = corners[longest], b = corners[(longest + 1) % 4]
        let angle = atan2(b.y - a.y, b.x - a.x)
        let center = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        let bounds = boundingBox(samples.map { rotate($0, around: center, by: -angle) })
        let fitted = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.minY)]
        return fitted.map { rotate($0, around: center, by: angle) }
    }

    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        let total = zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + distance($1.0, $1.1) }
        var result: [CGPoint] = [], segment = 1, covered: CGFloat = 0
        for index in 0..<count {
            let target = CGFloat(index) * total / CGFloat(count - 1)
            while segment < points.count - 1 && covered + distance(points[segment - 1], points[segment]) < target {
                covered += distance(points[segment - 1], points[segment]); segment += 1
            }
            let a = points[segment - 1], b = points[segment]
            let t = min(max((target - covered) / max(distance(a, b), 0.001), 0), 1)
            result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return result
    }

    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var maximum: CGFloat = 0, split = 0
        for index in 1..<(points.count - 1) {
            let d = distanceToSegment(points[index], first, last)
            if d > maximum { maximum = d; split = index }
        }
        if maximum > tolerance {
            return Array(simplify(Array(points[...split]), tolerance: tolerance).dropLast()) + simplify(Array(points[split...]), tolerance: tolerance)
        }
        return [first, last]
    }

    private static func deduplicate(_ input: [CGPoint]) -> [CGPoint] {
        input.reduce(into: []) { result, point in
            if point.x.isFinite && point.y.isFinite && (result.last.map { distance($0, point) > 0.5 } ?? true) { result.append(point) }
        }
    }
    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }
    private static func rotate(_ point: CGPoint, around center: CGPoint, by angle: CGFloat) -> CGPoint {
        let x = point.x - center.x, y = point.y - center.y
        return CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
    }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, 0.001), 0), 1)
        return distance(p, CGPoint(x: a.x + dx * t, y: a.y + dy * t))
    }
    private static func meanDistance(_ points: [CGPoint], to polygon: [CGPoint]) -> CGFloat {
        points.reduce(CGFloat.zero) { sum, point in
            sum + (zip(polygon, polygon.dropFirst()).map { distanceToSegment(point, $0.0, $0.1) }.min() ?? .infinity)
        } / CGFloat(points.count)
    }
}

/// Observes the same touch as PencilKit without delaying or cancelling normal ink.
final class NotyShapeHoldGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onBegin: (() -> Void)?
    var onRecognize: ((NotyRecognizedShape) -> Void)?
    private var points: [CGPoint] = []
    private var trackedTouch: UITouch?
    private var holdTask: Task<Void, Never>?
    private var holdLocation: CGPoint?

    init() {
        super.init(target: nil, action: nil)
        delegate = self
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, trackedTouch == nil, let touch = touches.first else { state = .failed; return }
        trackedTouch = touch
        points = [touch.location(in: view)]
        onBegin?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let touch = trackedTouch, touches.contains(touch) else { return }
        for sample in event.coalescedTouches(for: touch) ?? [touch] { points.append(sample.location(in: view)) }
        let location = touch.location(in: view)
        if holdLocation.map({ hypot(location.x - $0.x, location.y - $0.y) < 3 }) == true { return }
        holdLocation = location
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard !Task.isCancelled, let self, self.state == .possible, self.trackedTouch != nil,
                  let shape = NotyShapeRecognition.recognize(self.points) else { return }
            self.state = .began
            self.onRecognize?(shape)
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        holdTask?.cancel()
        state = state == .began ? .ended : .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        holdTask?.cancel(); state = .cancelled
    }
    override func reset() {
        holdTask?.cancel(); holdTask = nil; trackedTouch = nil; points = []; holdLocation = nil
        super.reset()
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}

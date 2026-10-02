import Foundation
import PencilKit
import UIKit
import Vision

enum NotyHandwritingRecognizer {
    static func recognize(drawingData: Data) throws -> String {
        let drawing = try PKDrawing(data: drawingData)
        guard let cgImage = recognitionImage(for: drawing)?.cgImage else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.006

        if let supportedLanguages = try? request.supportedRecognitionLanguages() {
            let preferredLanguages = Locale.preferredLanguages
            let selectedLanguages = preferredLanguages.compactMap { preferred in
                supportedLanguages.first(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame })
                    ?? supportedLanguages.first(where: {
                        $0.split(separator: "-").first?.caseInsensitiveCompare(
                            preferred.split(separator: "-").first.map(String.init) ?? preferred
                        ) == .orderedSame
                    })
            }
            if !selectedLanguages.isEmpty {
                var uniqueLanguages: [String] = []
                for language in selectedLanguages where !uniqueLanguages.contains(language) {
                    uniqueLanguages.append(language)
                }
                request.recognitionLanguages = uniqueLanguages
            }
        }

        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        let observations = request.results ?? []
        let lines = observations
            .sorted { left, right in
                if abs(left.boundingBox.midY - right.boundingBox.midY) > 0.012 {
                    return left.boundingBox.midY > right.boundingBox.midY
                }
                return left.boundingBox.minX < right.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }
    static func recognitionImage(for drawing: PKDrawing) -> UIImage? {
        guard !drawing.strokes.isEmpty else { return nil }

        let drawingBounds = drawing.bounds
        guard !drawingBounds.isNull, !drawingBounds.isEmpty else { return nil }
        // Vision needs surrounding whitespace to detect isolated handwritten words reliably.
        let padding = max(24, min(max(drawingBounds.width, drawingBounds.height) * 0.75, 240))
        let imageBounds = drawingBounds.insetBy(dx: -padding, dy: -padding)
        // Normalize ink for OCR so light ink on dark paper is searchable too.
        let monochrome = PKDrawing(strokes: drawing.strokes.map { stroke in
            PKStroke(ink: PKInk(stroke.ink.inkType, color: .black), path: stroke.path, transform: stroke.transform, mask: stroke.mask)
        })
        let scale = min(2, 4096 / max(imageBounds.width, imageBounds.height))
        let inkImage = monochrome.notyImage(from: imageBounds, scale: scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: inkImage.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: inkImage.size))
            inkImage.draw(at: .zero)
        }
        return image

    }

}

/// Serializes Vision work across pages so a large library doesn't launch many OCR jobs at once.
actor NotyHandwritingRecognitionWorker {
    static let shared = NotyHandwritingRecognitionWorker()
    func recognize(drawingData: Data) throws -> String {
        try NotyHandwritingRecognizer.recognize(drawingData: drawingData)
    }
}

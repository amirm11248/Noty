import Foundation
import PencilKit
import UIKit
import Vision

enum NotyHandwritingRecognizer {
    static func recognize(drawingData: Data) throws -> String {
        let drawing = try PKDrawing(data: drawingData)
        guard !drawing.strokes.isEmpty else { return "" }

        let drawingBounds = drawing.bounds
        guard !drawingBounds.isNull, !drawingBounds.isEmpty else { return "" }
        let imageBounds = drawingBounds.insetBy(dx: -12, dy: -12)
        let image = drawing.image(from: imageBounds, scale: 2)
        guard let cgImage = image.cgImage else { return "" }

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
}

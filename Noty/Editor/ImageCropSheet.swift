import SwiftUI
import UIKit

extension UIImage {
    func notyCropped(x: Double, y: Double, width: Double, height: Double) -> UIImage {
        guard x != 0 || y != 0 || width != 1 || height != 1 else { return self }
        let normalized: UIImage
        if imageOrientation != .up {
            normalized = UIGraphicsImageRenderer(size: size).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
        } else { normalized = self }
        guard let cg = normalized.cgImage else { return self }
        let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let crop = CGRect(x: Double(cg.width) * x, y: Double(cg.height) * y, width: Double(cg.width) * width, height: Double(cg.height) * height).intersection(bounds).integral
        guard crop.width > 0, crop.height > 0, let cropped = cg.cropping(to: crop) else { return self }
        return UIImage(cgImage: cropped, scale: normalized.scale, orientation: .up)
    }
}

struct ImageCropSheet: View {
    let image: UIImage
    let pageImage: NotyPageImage
    let onSave: (NotyPageImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    @State private var x = 0.5
    @State private var y = 0.5
    @State private var aspect = "Original"
    private var cropSize: CGSize {
        let base = Double(image.size.width / image.size.height)
        let desired: Double = aspect == "Square" ? 1 : aspect == "4:3" ? 4.0 / 3.0 : aspect == "16:9" ? 16.0 / 9.0 : base
        let width = min(1, desired / base) / zoom
        return CGSize(width: width, height: width * base / desired)
    }
    private var cropX: Double { x * (1 - cropSize.width) }
    private var cropY: Double { y * (1 - cropSize.height) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(uiImage: image.notyCropped(x: cropX, y: cropY, width: cropSize.width, height: cropSize.height))
                    .resizable().scaledToFit().frame(maxHeight: 330).clipShape(RoundedRectangle(cornerRadius: 12))
                Picker("Crop shape", selection: $aspect) { ForEach(["Original", "Square", "4:3", "16:9"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Zoom").font(.caption); Slider(value: $zoom, in: 1...4)
                    Text("Horizontal position").font(.caption); Slider(value: $x, in: 0...1)
                    Text("Vertical position").font(.caption); Slider(value: $y, in: 0...1)
                }
                Button("Reset crop") { zoom = 1; x = 0.5; y = 0.5; aspect = "Original" }
                Spacer(minLength: 0)
            }.padding(24).background { FrostedWorkspaceBackground() }
                .navigationTitle("Crop photo").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            var updated = pageImage
                            updated.cropX = cropX; updated.cropY = cropY; updated.cropWidth = cropSize.width; updated.cropHeight = cropSize.height
                            let ratio = image.size.width * cropSize.width / (image.size.height * cropSize.height)
                            let oldHeight = updated.height
                            updated.height = updated.width / ratio
                            if updated.height > oldHeight { updated.width *= oldHeight / updated.height; updated.height = oldHeight }
                            onSave(updated); dismiss()
                        }.fontWeight(.semibold)
                    }
                }
                .onAppear {
                    let width = pageImage.cropWidth ?? 1; let height = pageImage.cropHeight ?? 1
                    if width < 1 || height < 1 {
                        zoom = 1 / max(width, height)
                        if abs(width - height) > 0.01 {
                            let ratio = image.size.width * width / (image.size.height * height)
                            aspect = abs(ratio - 1) < 0.02 ? "Square" : abs(ratio - 4 / 3) < 0.02 ? "4:3" : abs(ratio - 16 / 9) < 0.02 ? "16:9" : "Original"
                        }
                        x = (pageImage.cropX ?? 0) / max(0.001, 1 - width)
                        y = (pageImage.cropY ?? 0) / max(0.001, 1 - height)
                    }
                }
        }
    }
}

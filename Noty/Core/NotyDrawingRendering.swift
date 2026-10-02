import PencilKit
import UIKit

extension PKDrawing {
    /// Paper and ink use explicit colors, independent of the surrounding app appearance.
    func notyImage(from rect: CGRect, scale: CGFloat) -> UIImage {
        var rendered = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            rendered = image(from: rect, scale: scale)
        }
        return rendered
    }
}

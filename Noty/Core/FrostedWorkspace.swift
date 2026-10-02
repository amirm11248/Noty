import SwiftUI

struct FrostedWorkspaceBackground: View {
    var body: some View {
        NotionTheme.canvas.ignoresSafeArea()
    }
}

struct FrostedPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .background { if reduceTransparency { RoundedRectangle(cornerRadius: 18).fill(NotionTheme.card) } else { RoundedRectangle(cornerRadius: 18).fill(.regularMaterial) } }
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 6)
    }
}
extension View { func frostedPanel() -> some View { modifier(FrostedPanel()) } }

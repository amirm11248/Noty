import SwiftUI

// The palette has four stable destinations; its drag preview never obscures the drop target.
enum NotebookToolbarDock: String, CaseIterable {
    case top, bottom, left, right
    var isVertical: Bool { self == .left || self == .right }
    var alignment: Alignment {
        switch self { case .top: .top; case .bottom: .bottom; case .left: .leading; case .right: .trailing }
    }
    static func nearest(to location: CGPoint, in size: CGSize) -> Self {
        let distances: [(Self, CGFloat)] = [(.top, location.y), (.bottom, size.height - location.y), (.left, location.x), (.right, size.width - location.x)]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .top
    }
}

struct FloatingNotebookToolbar<Content: View>: View {
    @AppStorage("noty.editor.toolbarDock") private var dockValue = NotebookToolbarDock.top.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @GestureState private var isDragging = false
    @State private var previewDock: NotebookToolbarDock?
    var onDragBegan: () -> Void = {}
    @ViewBuilder var content: (_ vertical: Bool, _ compact: Bool) -> Content
    private var dock: NotebookToolbarDock { NotebookToolbarDock(rawValue: dockValue) ?? .top }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                palette(at: dock, in: proxy.size, preview: false)
                    .opacity(isDragging ? 0 : 1)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .named("notebookToolbarSpace"))
                            .updating($isDragging) { _, state, _ in state = true }
                            .onChanged { value in
                                if previewDock == nil { onDragBegan() }
                                previewDock = NotebookToolbarDock.nearest(to: value.location, in: proxy.size)
                            }
                            .onEnded { value in
                                dockValue = NotebookToolbarDock.nearest(to: value.location, in: proxy.size).rawValue
                                previewDock = nil
                            },
                        including: .all
                    )
                    .accessibilityHint("Drag anywhere on the toolbar to dock it at the top, bottom, left or right")
                    .accessibilityAction(named: "Dock at top") { dockValue = NotebookToolbarDock.top.rawValue }
                    .accessibilityAction(named: "Dock at bottom") { dockValue = NotebookToolbarDock.bottom.rawValue }
                    .accessibilityAction(named: "Dock on left") { dockValue = NotebookToolbarDock.left.rawValue }
                    .accessibilityAction(named: "Dock on right") { dockValue = NotebookToolbarDock.right.rawValue }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dock.alignment)
                if isDragging, let previewDock {
                    palette(at: previewDock, in: proxy.size, preview: true)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: previewDock.alignment)
                }
            }
            .padding(10)
            .coordinateSpace(name: "notebookToolbarSpace")
            .onChange(of: isDragging) { _, dragging in if !dragging { previewDock = nil } }
        }
    }

    private func palette(at edge: NotebookToolbarDock, in size: CGSize, preview: Bool) -> some View {
        let compact = edge.isVertical ? size.height < 710 : size.width < 700
        return content(edge.isVertical, compact)
            .padding(6)
            .fixedSize()
            .foregroundStyle(NotionTheme.ink)
            .background(Color(white: colorScheme == .dark ? (preview ? 0.035 : 0.095) : (preview ? 0.74 : 0.98)), in: Capsule())
            .overlay(Capsule().stroke(NotionTheme.hairline.opacity(preview ? 1 : 0.8), lineWidth: 1))
            .shadow(color: .black.opacity(preview ? 0.08 : 0.18), radius: 12, y: 4)
            .opacity(preview ? 0.65 : 1)
            .contentShape(Capsule())
            .accessibilityIdentifier(preview ? "editor.toolbar.dockPreview" : "editor.floatingToolbar")
    }
}

struct NotebookToolButtonStyle: ButtonStyle {
    var isSelected = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 17 : 19, weight: .regular))
            .foregroundStyle(NotionTheme.ink.opacity(isEnabled ? 0.9 : 0.25))
            .frame(width: compact ? 28 : 36, height: 38)
            .background((colorScheme == .dark ? Color.white : Color.black).opacity(isSelected ? 0.13 : configuration.isPressed ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
    }
}

struct NotebookToolSettings<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.headline)
            content
        }
        .padding(22)
        .frame(width: 320)
        .foregroundStyle(NotionTheme.ink)
        .tint(NotionTheme.accent)
        .background(NotionTheme.card)
    }
}

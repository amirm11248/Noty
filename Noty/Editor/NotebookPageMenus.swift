import PDFKit
import SwiftUI

struct NotebookPaperMenus: View {
    let documentID: UUID
    let page: NotyPage
    let store: NotyStore
    var isInfinite = false
    var prepare: () -> Void = {}
    var editCover: () -> Void = {}
    private let colors = ["FFFFFF", "FFFDF5", "FFF3B0", "EAF4FF", "ECF7EE", "FCECEF", "292927"]

    var body: some View {
        Menu("Design", systemImage: "square.grid.2x2") {
            if page.isCover {
                Button("Edit cover…", systemImage: "book.closed", action: editCover)
            } else {
                ForEach(isInfinite ? [.blank, .ruled, .narrowRuled, .grid, .smallGrid, .dots] : NotyPageTemplate.allCases, id: \.self) { template in
                    Button {
                        prepare(); store.updatePageFormat(documentID: documentID, pageID: page.id, template: template)
                    } label: { Label(template.title, systemImage: page.template == template ? "checkmark" : "doc") }
                }
            }
        }.disabled(page.sourcePageIndex != nil)
        Menu("Color", systemImage: "paintpalette") {
            ForEach(colors, id: \.self) { hex in
                Button {
                    prepare(); setColor(hex)
                } label: {
                    Label(NotyColorName.name(hex), systemImage: currentColor == hex ? "checkmark" : "circle.fill")
                }
            }
            ColorPicker("Custom color", selection: Binding(
                get: { Color(uiColor: UIColor(notyHex: currentColor)) },
                set: { value in
                    let color = UIColor(value)
                    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
                    guard color.getRed(&red, green: &green, blue: &blue, alpha: nil) else { return }
                    prepare(); setColor(String(format: "%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255)))
                }
            ), supportsOpacity: false)
        }
        if !isInfinite {
            Menu("Size", systemImage: "arrow.up.left.and.arrow.down.right") {
                ForEach(NotyPageSizePreset.allCases, id: \.self) { size in
                    Button {
                        prepare(); store.updatePageFormat(documentID: documentID, pageID: page.id, sizePreset: size)
                    } label: { Label(size.designTitle, systemImage: page.sizePreset == size && page.customWidth == nil ? "checkmark" : "doc") }
                }
                Section("Orientation") {
                    ForEach(NotyPageOrientation.allCases, id: \.self) { orientation in
                        Button {
                            prepare(); store.updatePageFormat(documentID: documentID, pageID: page.id, orientation: orientation)
                        } label: { Label(orientation.rawValue.capitalized, systemImage: page.orientation == orientation ? "checkmark" : "rectangle") }
                    }
                }
            }
        }
    }

    private var currentColor: String {
        if page.isCover { return store.documents.first(where: { $0.id == documentID })?.displayCover.colorHex ?? page.paperColorHex }
        return page.paperColorHex
    }
    private func setColor(_ hex: String) {
        if page.isCover, let document = store.documents.first(where: { $0.id == documentID }) {
            var cover = document.displayCover; cover.colorHex = hex; cover.imageFileName = nil
            try? store.updateCover(documentID: documentID, cover: cover)
        } else { store.updatePageFormat(documentID: documentID, pageID: page.id, paperColorHex: hex) }
    }
}

struct NotebookPageExportSheet: View {
    let documentID: UUID
    let store: NotyStore
    let sourcePDF: PDFDocument?
    var initialPageID: UUID?
    let onExport: (Set<UUID>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    private var pages: [NotyPage] { store.documents.first(where: { $0.id == documentID })?.pages ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("\(selected.count) selected").foregroundStyle(.secondary)
                        Spacer()
                        Button(selected.count == pages.count ? "Deselect all" : "Select all") {
                            selected = selected.count == pages.count ? [] : Set(pages.map(\.id))
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 18)], spacing: 22) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            PageThumbnail(documentID: documentID, page: page, number: index + 1, store: store, sourcePDF: sourcePDF, isSelected: selected.contains(page.id)) {
                                if selected.contains(page.id) { selected.remove(page.id) } else { selected.insert(page.id) }
                            }
                            .overlay(alignment: .topLeading) {
                                Image(systemName: selected.contains(page.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(selected.contains(page.id) ? NotionTheme.accent : NotionTheme.inkSecondary)
                                    .background(NotionTheme.card, in: Circle()).padding(8).allowsHitTesting(false)
                            }
                        }
                    }
                }.padding(24)
            }
            .background(NotionTheme.canvas)
            .navigationTitle("Export selected pages").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export PDF") { onExport(selected); dismiss() }.disabled(selected.isEmpty)
                }
            }
            .onAppear { if let initialPageID { selected = [initialPageID] } }
        }.presentationDragIndicator(.visible)
    }
}

struct NotebookPageArrangementSheet: View {
    let documentID: UUID
    let store: NotyStore
    @Environment(\.dismiss) private var dismiss
    private var pages: [NotyPage] { store.documents.first(where: { $0.id == documentID })?.pages ?? [] }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    HStack(spacing: 16) {
                        PaperDesignPreview(page: page).frame(width: 38, height: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(page.isCover ? "Cover" : "Page \(index + 1)")
                            Text(page.bookmarkTitle ?? page.template.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }.moveDisabled(page.isCover)
                }.onMove { source, destination in store.movePage(documentID: documentID, from: source, to: destination) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Arrange pages").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDragIndicator(.visible)
    }
}

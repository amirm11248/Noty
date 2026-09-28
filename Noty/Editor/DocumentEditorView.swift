import PDFKit
import PencilKit
import PhotosUI
import SwiftUI
import UIKit

struct DocumentEditorView: View {
    let documentID: UUID
    let store: NotyStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var canvasController = InkCanvasController()
    @State private var selectedPageID: UUID?
    @State private var selectedTextBoxID: UUID?
    @State private var editingTextBoxID: UUID?
    @State private var selectedImageID: UUID?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isPresentationMode = false
    @State private var isPresenterControlsVisible = true
    @State private var isLaserPointerEnabled = false
    @State private var presenterLaserLocation: CGPoint?
    @State private var isPresenterBlackout = false
    @State private var isToolPickerVisible = false
    @State private var isShowingThumbnails = true
    @State private var isShowingRename = false
    @State private var renameTitle = ""
    @State private var shareURL: URL?
    @State private var exportError: String?
    @State private var sourcePDF: PDFDocument?
    @State private var recognitionMessage: String?
    @State private var imageImportError: String?
    @State private var zoomScale: CGFloat = 1
    @State private var zoomBaseScale: CGFloat = 1
    @State private var inkType: EditorInkType = .ballPen
    @State private var inkColorHex = "37352F"
    @State private var inkWidth = 2.5
    @State private var inkOpacity = 1.0
    @AppStorage("noty.editor.customInkColors") private var customInkColorsStorage = "37352F,D34836,2383E2,2F8F4E,E3A008"

    private var document: NotyDocument? {
        store.documents.first { $0.id == documentID }
    }

    private var selectedPage: NotyPage? {
        guard let document else { return nil }
        return document.pages.first { $0.id == selectedPageID } ?? document.pages.first
    }

    var body: some View {
        Group {
            if let document {
                editor(document)
            } else {
                ContentUnavailableView("Document unavailable", systemImage: "doc.questionmark")
            }
        }
        .background(EditorPalette.workspace.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .onAppear(perform: selectInitialPage)
        .task(id: documentID) {
            sourcePDF = store.sourcePDF(documentID: documentID)
        }
        .onChange(of: document?.pages.map(\.id) ?? []) { _, pageIDs in
            if selectedPageID.map(pageIDs.contains) != true {
                selectedPageID = pageIDs.first
                selectedTextBoxID = nil
                editingTextBoxID = nil
                selectedImageID = nil
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                defer { selectedPhotoItem = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let page = selectedPage else {
                        throw NotyStoreError.invalidImage
                    }
                    let image = try store.addPageImage(data: data, documentID: documentID, pageID: page.id)
                    selectedImageID = image.id
                    selectedTextBoxID = nil
                    editingTextBoxID = nil
                    isToolPickerVisible = false
                } catch {
                    imageImportError = error.localizedDescription
                }
            }
        }
        .alert("Rename document", isPresented: $isShowingRename) {
            TextField("Document title", text: $renameTitle)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                store.renameDocument(id: documentID, title: renameTitle)
            }
        }
        .alert("Couldn’t export", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Please try again.")
        }
        .alert("Couldn’t add image", isPresented: Binding(
            get: { imageImportError != nil },
            set: { if !$0 { imageImportError = nil } }
        )) {
            Button("OK", role: .cancel) { imageImportError = nil }
        } message: {
            Text(imageImportError ?? "Please try another image.")
        }
        .alert("Handwriting to text", isPresented: Binding(
            get: { recognitionMessage != nil },
            set: { if !$0 { recognitionMessage = nil } }
        )) {
            Button("OK", role: .cancel) { recognitionMessage = nil }
        } message: {
            Text(recognitionMessage ?? "")
        }
        .sheet(item: Binding(
            get: { shareURL.map(SharedFile.init(url:)) },
            set: { shareURL = $0?.url }
        )) { sharedFile in
            ActivityViewController(items: [sharedFile.url])
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func editor(_ document: NotyDocument) -> some View {
        Group {
            if isPresentationMode {
                presentation(document)
            } else {
                VStack(spacing: 0) {
                    header(document)
                    Rectangle().fill(EditorPalette.border).frame(height: 1)
                    HStack(spacing: 0) {
                        if isShowingThumbnails && horizontalSizeClass != .compact {
                            thumbnailRail(document, sourcePDF: sourcePDF)
                            Rectangle().fill(EditorPalette.border).frame(width: 1)
                        }

                        VStack(spacing: 0) {
                            pageToolbar(document)
                            Rectangle().fill(EditorPalette.border).frame(height: 1)
                            canvasArea(document, sourcePDF: sourcePDF)
                        }
                    }
                }
            }
        }
        .statusBarHidden(isPresentationMode)
        .persistentSystemOverlays(isPresentationMode ? .hidden : .automatic)
        .foregroundStyle(EditorPalette.ink)
    }

    private func presentation(_ document: NotyDocument) -> some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.96).ignoresSafeArea()

                if !isPresenterBlackout, let page = selectedPage {
                    PresentedPageCanvas(
                        documentID: documentID,
                        page: page,
                        store: store,
                        sourcePDF: sourcePDF
                    )
                    .padding(36)
                    .transition(.opacity.combined(with: .scale(scale: 0.995)))
                }

                if isPresenterBlackout {
                    VStack(spacing: 8) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 26, weight: .medium))
                        Text("Screen hidden")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }

                if isLaserPointerEnabled, let presenterLaserLocation {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                        .shadow(color: .red.opacity(0.65), radius: 12)
                        .position(presenterLaserLocation)
                        .allowsHitTesting(false)
                }

                if isPresenterControlsVisible {
                    VStack {
                        HStack(spacing: 8) {
                            Button {
                                moveSelection(in: document, by: -1)
                                presenterLaserLocation = nil
                            } label: {
                                Image(systemName: "chevron.left")
                                    .frame(width: 32, height: 32)
                            }
                            .disabled((selectedPageIndex(in: document) ?? 0) == 0)
                            .accessibilityLabel("Previous presentation page")

                            Text("\((selectedPageIndex(in: document) ?? 0) + 1) / \(max(document.pages.count, 1))")
                                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.84))
                                .frame(minWidth: 48)

                            Button {
                                moveSelection(in: document, by: 1)
                                presenterLaserLocation = nil
                            } label: {
                                Image(systemName: "chevron.right")
                                    .frame(width: 32, height: 32)
                            }
                            .disabled((selectedPageIndex(in: document) ?? 0) >= document.pages.count - 1)
                            .accessibilityLabel("Next presentation page")

                            Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 18)

                            Button {
                                isLaserPointerEnabled.toggle()
                                if !isLaserPointerEnabled { presenterLaserLocation = nil }
                            } label: {
                                Image(systemName: isLaserPointerEnabled ? "scope" : "hand.point.up.left.fill")
                                    .frame(width: 32, height: 32)
                            }
                            .foregroundStyle(isLaserPointerEnabled ? Color.red : Color.white)
                            .accessibilityLabel(isLaserPointerEnabled ? "Turn off laser pointer" : "Turn on laser pointer")

                            Button {
                                isPresenterBlackout.toggle()
                                presenterLaserLocation = nil
                            } label: {
                                Image(systemName: isPresenterBlackout ? "eye" : "moon")
                                    .frame(width: 32, height: 32)
                            }
                            .accessibilityLabel(isPresenterBlackout ? "Show presentation page" : "Hide presentation page")

                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    isPresentationMode = false
                                    isLaserPointerEnabled = false
                                    presenterLaserLocation = nil
                                    isPresenterBlackout = false
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .frame(width: 32, height: 32)
                            }
                            .accessibilityLabel("Exit presentation")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .buttonStyle(PresenterButtonStyle())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                        .padding(18)

                        Spacer()

                        Text(isLaserPointerEnabled ? "Drag anywhere to point" : "Swipe left or right for pages · Tap to hide controls")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.black.opacity(0.42), in: Capsule())
                            .padding(.bottom, 18)
                    }
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isLaserPointerEnabled else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    isPresenterControlsVisible.toggle()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .local)
                    .onChanged { value in
                        guard isLaserPointerEnabled else { return }
                        presenterLaserLocation = CGPoint(
                            x: min(max(value.location.x, 8), proxy.size.width - 8),
                            y: min(max(value.location.y, 8), proxy.size.height - 8)
                        )
                    }
                    .onEnded { value in
                        if isLaserPointerEnabled {
                            presenterLaserLocation = nil
                            return
                        }
                        guard abs(value.translation.width) > 55,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        moveSelection(in: document, by: value.translation.width < 0 ? 1 : -1)
                    }
            )
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea()
    }

    private func header(_ document: NotyDocument) -> some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(NotionIconButtonStyle())
            .accessibilityLabel("Back to library")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("Noty")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(document.kind.editorLabel)
                }
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(EditorPalette.secondaryInk)

                Button {
                    renameTitle = document.title
                    isShowingRename = true
                } label: {
                    HStack(spacing: 6) {
                        Text(document.title)
                            .font(.system(size: 18, weight: .semibold))
                            .tracking(-0.25)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 10)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isShowingThumbnails.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(NotionIconButtonStyle())
            .accessibilityLabel(isShowingThumbnails ? "Hide page thumbnails" : "Show page thumbnails")

            Menu {
                ForEach(NotyPageTemplate.allCases, id: \.self) { template in
                    Button {
                        addPage(template: template)
                    } label: {
                        Label(template.editorLabel, systemImage: template.symbolName)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(NotionIconButtonStyle())
            .accessibilityLabel("Add page")

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isPresenterControlsVisible = true
                    isLaserPointerEnabled = false
                    presenterLaserLocation = nil
                    isPresenterBlackout = false
                    isPresentationMode = true
                }
            } label: {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(NotionIconButtonStyle())
            .accessibilityLabel("Present document")

            Menu {
                Button {
                    exportPDF()
                } label: {
                    Label("Export as PDF", systemImage: "doc.richtext")
                }
                if selectedPage != nil {
                    Button {
                        exportPageImage()
                    } label: {
                        Label("Export current page as image", systemImage: "photo")
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(NotionIconButtonStyle())
            .accessibilityLabel("Export document")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(EditorPalette.paper)
    }

    private func thumbnailRail(_ document: NotyDocument, sourcePDF: PDFDocument?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                NotionSectionLabel(text: "Pages")
                Spacer()
                Text("\(document.pages.count)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(EditorPalette.secondaryInk)
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                        PageThumbnail(
                            documentID: documentID,
                            page: page,
                            number: index + 1,
                            store: store,
                            sourcePDF: sourcePDF,
                            isSelected: page.id == selectedPage?.id
                        ) {
                            selectedPageID = page.id
                            selectedTextBoxID = nil
                            editingTextBoxID = nil
                        }
                        .draggable(page.id.uuidString)
                        .dropDestination(for: String.self) { values, _ in
                            guard let value = values.first,
                                  let fromID = UUID(uuidString: value),
                                  let fromIndex = document.pages.firstIndex(where: { $0.id == fromID }),
                                  let toIndex = document.pages.firstIndex(where: { $0.id == page.id }),
                                  fromIndex != toIndex else { return false }
                            let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
                            store.movePage(documentID: documentID, from: IndexSet(integer: fromIndex), to: destination)
                            return true
                        }
                        .contextMenu {
                            Button {
                                selectedPageID = page.id
                                addPage(template: page.template)
                            } label: {
                                Label("Add page after", systemImage: "plus.rectangle.on.rectangle")
                            }
                            Button(role: .destructive) {
                                store.deletePage(documentID: documentID, pageID: page.id)
                            } label: {
                                Label("Delete page", systemImage: "trash")
                            }
                        }
                    }

                    Button {
                        addPage(template: .blank)
                    } label: {
                        Label("New page", systemImage: "plus")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(EditorPalette.secondaryInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.clear, in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium))
                            .overlay(RoundedRectangle(cornerRadius: NotionTheme.radiusMedium).stroke(EditorPalette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(width: 208)
        .background(EditorPalette.rail)
    }

    private func pageToolbar(_ document: NotyDocument) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                Button { moveSelection(in: document, by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(selectedPageIndex(in: document) == 0)
                .accessibilityLabel("Previous page")

                Text("\((selectedPageIndex(in: document) ?? 0) + 1) / \(max(document.pages.count, 1))")
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(EditorPalette.secondaryInk)
                    .frame(minWidth: 44)
                    .accessibilityLabel("Page \((selectedPageIndex(in: document) ?? 0) + 1) of \(document.pages.count)")

                Button { moveSelection(in: document, by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled((selectedPageIndex(in: document) ?? 0) >= document.pages.count - 1)
                .accessibilityLabel("Next page")

                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0, 2.5], id: \.self) { scale in
                        Button {
                            zoomScale = CGFloat(scale)
                            zoomBaseScale = CGFloat(scale)
                        } label: {
                            if abs(zoomScale - CGFloat(scale)) < 0.01 {
                                Label("\(Int(scale * 100))%", systemImage: "checkmark")
                            } else {
                                Text("\(Int(scale * 100))%")
                            }
                        }
                    }
                    Button("Reset zoom", systemImage: "arrow.counterclockwise") {
                        zoomScale = 1
                        zoomBaseScale = 1
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Page zoom")

                if document.pages.contains(where: \.isBookmarked) {
                    Menu {
                        ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, bookmarkedPage in
                            if bookmarkedPage.isBookmarked {
                                Button {
                                    selectedPageID = bookmarkedPage.id
                                    selectedTextBoxID = nil
                                    editingTextBoxID = nil
                                    selectedImageID = nil
                                } label: {
                                    Label(bookmarkedPage.bookmarkTitle ?? "Page \(index + 1)", systemImage: "bookmark.fill")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "bookmark")
                    }
                    .accessibilityLabel("Bookmarked pages")
                }

                toolbarDivider

                Button { canvasController.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!canvasController.canUndo)
                .accessibilityLabel("Undo drawing")

                Button { canvasController.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!canvasController.canRedo)
                .accessibilityLabel("Redo drawing")

                toolbarDivider

                Menu {
                    ForEach(EditorInkType.allCases) { type in
                        Button {
                            inkType = type
                        } label: {
                            if type == inkType {
                                Label(type.label, systemImage: "checkmark")
                            } else {
                                Label(type.label, systemImage: type.symbolName)
                            }
                        }
                    }
                } label: {
                    Label(inkType.label, systemImage: inkType.symbolName)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(inkColor)
                        .accessibilityLabel("Ink: \(inkType.label)")
                }
                .accessibilityLabel("Choose pen")

                Menu {
                    Section("Presets") {
                        ForEach(customInkColors, id: \.self) { colorHex in
                            let isSelected = colorHex == inkColorHex
                            let title = isSelected ? "Selected color" : colorName(for: colorHex)
                            let symbolName = isSelected ? "checkmark.circle.fill" : "circle.fill"
                            Button {
                                inkColorHex = colorHex
                            } label: {
                                Label(title, systemImage: symbolName)
                                    .tint(Color(hex: colorHex))
                            }
                        }
                    }
                    ColorPicker("Custom color", selection: inkColorSelection, supportsOpacity: false)
                    Button {
                        saveCurrentInkColorPreset()
                    } label: {
                        Label("Save current color preset", systemImage: "plus.circle")
                    }
                } label: {
                    Circle()
                        .fill(inkColor)
                        .frame(width: 17, height: 17)
                        .overlay(Circle().stroke(EditorPalette.border, lineWidth: 1))
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Ink color")

                Menu {
                    Section("Thickness") {
                        Slider(value: $inkWidth, in: 1...14, step: 0.5)
                        Text("\(inkWidth, specifier: "%.1f") pt")
                            .font(.caption.monospacedDigit())
                    }
                    Section("Opacity") {
                        Slider(value: $inkOpacity, in: 0.15...1, step: 0.05)
                        Text("\(Int(inkOpacity * 100))%")
                            .font(.caption.monospacedDigit())
                    }
                } label: {
                    Image(systemName: "lineweight")
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Ink thickness and opacity")

                Button {
                    isToolPickerVisible.toggle()
                } label: {
                    Image(systemName: "scribble.variable")
                        .foregroundStyle(isToolPickerVisible ? NotionTheme.accent : EditorPalette.ink)
                        .frame(width: 30, height: 30)
                        .background(isToolPickerVisible ? NotionTheme.rowHover : Color.clear, in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium))
                        .overlay {
                            if isToolPickerVisible {
                                RoundedRectangle(cornerRadius: NotionTheme.radiusMedium)
                                    .stroke(EditorPalette.border, lineWidth: 0.8)
                            }
                        }
                }
                .accessibilityLabel(isToolPickerVisible ? "Hide drawing tools" : "Show drawing tools")
                .accessibilityHint("PencilKit provides eraser, lasso, and ruler tools")

                Menu {
                    Section("Ruler") {
                        Button {
                            canvasController.toggleRuler()
                        } label: {
                            Label(canvasController.isRulerActive ? "Hide ruler" : "Show ruler", systemImage: canvasController.isRulerActive ? "checkmark.ruler" : "ruler")
                        }
                    }
                    Section("Shapes") {
                        Button { canvasController.insertShape(.line, color: inkUIColor, width: inkWidth, canvasSize: selectedPage?.canvasSize ?? CGSize(width: 612, height: 792)) } label: {
                            Label("Straight line", systemImage: "line.diagonal")
                        }
                        Button { canvasController.insertShape(.rectangle, color: inkUIColor, width: inkWidth, canvasSize: selectedPage?.canvasSize ?? CGSize(width: 612, height: 792)) } label: {
                            Label("Rectangle", systemImage: "rectangle")
                        }
                        Button { canvasController.insertShape(.ellipse, color: inkUIColor, width: inkWidth, canvasSize: selectedPage?.canvasSize ?? CGSize(width: 612, height: 792)) } label: {
                            Label("Ellipse", systemImage: "circle")
                        }
                    }
                } label: {
                    Image(systemName: canvasController.isRulerActive ? "checkmark.ruler" : "shapes")
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Ruler and shapes")

                Button { addTextBox() } label: {
                    Image(systemName: "text.cursor")
                }
                .disabled(selectedPage == nil)
                .accessibilityLabel("Add text box")

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "photo.badge.plus")
                        .frame(width: 30, height: 30)
                }
                .disabled(selectedPage == nil)
                .accessibilityLabel("Add photo")

                if let page = selectedPage, !page.images.isEmpty {
                    Menu {
                        ForEach(Array(page.images.enumerated()), id: \.element.id) { index, image in
                            Button {
                                selectedImageID = image.id
                                selectedTextBoxID = nil
                                editingTextBoxID = nil
                                isToolPickerVisible = false
                            } label: {
                                if selectedImageID == image.id {
                                    Label("Image \(index + 1)", systemImage: "checkmark")
                                } else {
                                    Label("Image \(index + 1)", systemImage: "photo")
                                }
                            }
                        }
                        if selectedImageID != nil {
                            Divider()
                            Button("Done selecting image", systemImage: "checkmark") {
                                selectedImageID = nil
                            }
                        }
                    } label: {
                        Image(systemName: selectedImageID == nil ? "photo.on.rectangle" : "photo.fill.on.rectangle.fill")
                    }
                    .accessibilityLabel("Select page image")
                }

                if let page = selectedPage,
                   let selectedImageID,
                   let selectedImage = page.images.first(where: { $0.id == selectedImageID }) {
                    Button {
                        updatePageImage(page, imageID: selectedImage.id) { $0.rotationDegrees -= 90 }
                    } label: {
                        Image(systemName: "rotate.left")
                    }
                    .accessibilityLabel("Rotate image left")

                    Button {
                        updatePageImage(page, imageID: selectedImage.id) { $0.rotationDegrees += 90 }
                    } label: {
                        Image(systemName: "rotate.right")
                    }
                    .accessibilityLabel("Rotate image right")

                    Button(role: .destructive) {
                        store.updatePageImages(
                            documentID: documentID,
                            pageID: page.id,
                            images: page.images.filter { $0.id != selectedImage.id }
                        )
                        self.selectedImageID = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete image")
                }

                if let page = selectedPage {
                    Button { convertHandwritingToText(page) } label: {
                        Image(systemName: "character.book.closed")
                    }
                    .accessibilityLabel("Convert handwriting to text")
                }

                if let selectedTextBoxID, let page = selectedPage,
                   let textBox = page.textBoxes.first(where: { $0.id == selectedTextBoxID }) {
                    Menu {
                        Section("Font") {
                            Button {
                                updateTextBox(page, boxID: textBox.id) { $0.fontName = nil }
                            } label: {
                                if textBox.fontName == nil { Label("System", systemImage: "checkmark") }
                                else { Text("System") }
                            }
                            ForEach(["Avenir Next", "Georgia", "Courier New"], id: \.self) { fontName in
                                Button {
                                    updateTextBox(page, boxID: textBox.id) { $0.fontName = fontName }
                                } label: {
                                    if textBox.fontName == fontName { Label(fontName, systemImage: "checkmark") }
                                    else { Text(fontName) }
                                }
                            }
                        }
                        Section("Text size") {
                            ForEach([12.0, 14.0, 18.0, 22.0, 28.0, 36.0, 48.0], id: \.self) { size in
                                Button {
                                    updateTextBox(page, boxID: textBox.id) { $0.fontSize = size }
                                } label: {
                                    if textBox.fontSize == size { Label("\(Int(size)) pt", systemImage: "checkmark") }
                                    else { Text("\(Int(size)) pt") }
                                }
                            }
                        }
                        Section("Style") {
                            Button {
                                updateTextBox(page, boxID: textBox.id) { $0.isBold.toggle() }
                            } label: {
                                Label("Bold", systemImage: textBox.isBold ? "checkmark" : "bold")
                            }
                            Button {
                                updateTextBox(page, boxID: textBox.id) { $0.isItalic.toggle() }
                            } label: {
                                Label("Italic", systemImage: textBox.isItalic ? "checkmark" : "italic")
                            }
                            Button {
                                updateTextBox(page, boxID: textBox.id) { $0.isUnderlined.toggle() }
                            } label: {
                                Label("Underline", systemImage: textBox.isUnderlined ? "checkmark" : "underline")
                            }
                        }
                        Section("Alignment") {
                            ForEach(NotyTextAlignment.allCases, id: \.self) { alignment in
                                Button {
                                    updateTextBox(page, boxID: textBox.id) { $0.alignment = alignment }
                                } label: {
                                    Label(alignment.editorLabel, systemImage: textBox.alignment == alignment ? "checkmark" : alignment.symbolName)
                                }
                            }
                        }
                        Section("Color") {
                            ForEach(["37352F", "D34836", "2383E2", "2F8F4E", "E3A008"], id: \.self) { colorHex in
                                Button {
                                    updateTextBox(page, boxID: textBox.id) { $0.colorHex = colorHex }
                                } label: {
                                    Label(colorName(for: colorHex), systemImage: textBox.colorHex == colorHex ? "checkmark.circle.fill" : "circle.fill")
                                        .tint(Color(hex: colorHex))
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "textformat")
                    }
                    .accessibilityLabel("Text formatting")

                    Button {
                        editingTextBoxID = editingTextBoxID == textBox.id ? nil : textBox.id
                    } label: {
                        Image(systemName: editingTextBoxID == textBox.id ? "checkmark" : "square.and.pencil")
                    }
                    .accessibilityLabel(editingTextBoxID == textBox.id ? "Done editing text" : "Edit text")

                    Button(role: .destructive) {
                        updateTextBoxes(page, removing: textBox.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete text box")
                }

                if let page = selectedPage {
                    toolbarDivider
                    Menu {
                        if page.sourcePageIndex == nil {
                            Section("Paper design") {
                                ForEach(NotyPageTemplate.allCases, id: \.self) { template in
                                    Button {
                                        store.updatePageFormat(documentID: documentID, pageID: page.id, template: template)
                                    } label: {
                                        if page.template == template {
                                            Label(template.editorLabel, systemImage: "checkmark")
                                        } else {
                                            Label(template.editorLabel, systemImage: template.symbolName)
                                        }
                                    }
                                }
                            }
                        }
                        Section("Paper color") {
                            ForEach(paperColorPresets, id: \.hex) { preset in
                                Button {
                                    store.updatePageFormat(documentID: documentID, pageID: page.id, paperColorHex: preset.hex)
                                } label: {
                                    Label(preset.name, systemImage: page.paperColorHex.uppercased() == preset.hex ? "checkmark.circle.fill" : "circle.fill")
                                        .tint(Color(hex: preset.hex))
                                }
                            }
                            ColorPicker("Custom color", selection: paperColorBinding(for: page), supportsOpacity: false)
                        }
                        Section("Paper size") {
                            ForEach(NotyPageSizePreset.allCases, id: \.self) { size in
                                Button {
                                    store.updatePageFormat(documentID: documentID, pageID: page.id, sizePreset: size)
                                } label: {
                                    if page.sizePreset == size {
                                        Label(size.editorLabel, systemImage: "checkmark")
                                    } else {
                                        Label(size.editorLabel, systemImage: size.symbolName)
                                    }
                                }
                            }
                        }
                        Section("Orientation") {
                            ForEach(NotyPageOrientation.allCases, id: \.self) { orientation in
                                Button {
                                    store.updatePageFormat(documentID: documentID, pageID: page.id, orientation: orientation)
                                } label: {
                                    if page.orientation == orientation {
                                        Label(orientation.editorLabel, systemImage: "checkmark")
                                    } else {
                                        Label(orientation.editorLabel, systemImage: orientation.symbolName)
                                    }
                                }
                            }
                        }
                        Section("Page") {
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    isPresenterControlsVisible = true
                                    isLaserPointerEnabled = false
                                    presenterLaserLocation = nil
                                    isPresenterBlackout = false
                                    isPresentationMode = true
                                }
                            } label: {
                                Label("Present pages", systemImage: "play.rectangle")
                            }
                            Button {
                                store.updatePageBookmark(
                                    documentID: documentID,
                                    pageID: page.id,
                                    isBookmarked: !page.isBookmarked
                                )
                            } label: {
                                Label(page.isBookmarked ? "Remove page bookmark" : "Bookmark page", systemImage: page.isBookmarked ? "bookmark.slash" : "bookmark")
                            }
                            Button {
                                addPage(template: page.template)
                            } label: {
                                Label("Add page after", systemImage: "plus.rectangle.on.rectangle")
                            }
                            Button {
                                duplicatePage(page)
                            } label: {
                                Label("Duplicate page", systemImage: "plus.square.on.square")
                            }
                            Button {
                                moveCurrentPage(in: document, by: -1)
                            } label: {
                                Label("Move page earlier", systemImage: "arrow.up.to.line")
                            }
                            .disabled((selectedPageIndex(in: document) ?? 0) == 0)
                            Button {
                                moveCurrentPage(in: document, by: 1)
                            } label: {
                                Label("Move page later", systemImage: "arrow.down.to.line")
                            }
                            .disabled((selectedPageIndex(in: document) ?? 0) >= document.pages.count - 1)
                            Button(role: .destructive) {
                                store.deletePage(documentID: documentID, pageID: page.id)
                            } label: {
                                Label("Delete page", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 30, height: 30)
                    }
                    .accessibilityLabel("Page options")
                }
            }
            .font(.system(size: 13, weight: .medium))
            .buttonStyle(EditorToolbarButtonStyle())
            .padding(.horizontal, 14)
            .frame(height: 46)
        }
        .scrollIndicators(.hidden)
        .background(EditorPalette.paper)
    }

    private var toolbarDivider: some View {
        Rectangle().fill(EditorPalette.border).frame(width: 1, height: 19).padding(.horizontal, 4)
    }

    private var inkColor: Color { Color(hex: inkColorHex) }
    private var inkUIColor: UIColor { UIColor(hex: inkColorHex).withAlphaComponent(inkOpacity) }
    private var inkSettings: EditorInkSettings {
        EditorInkSettings(type: inkType, color: inkUIColor, width: CGFloat(inkWidth))
    }
    private var customInkColors: [String] {
        customInkColorsStorage.split(separator: ",").map(String.init)
    }
    private var inkColorSelection: Binding<Color> {
        Binding(
            get: { inkColor },
            set: { inkColorHex = $0.hexString ?? inkColorHex }
        )
    }

    private func colorName(for hex: String) -> String {
        switch hex.uppercased() {
        case "37352F": "Ink"
        case "D34836": "Red"
        case "2383E2": "Blue"
        case "2F8F4E": "Green"
        case "E3A008": "Gold"
        default: "Custom color"
        }
    }

    private var paperColorPresets: [(name: String, hex: String)] {
        [
            ("White", "FFFFFF"),
            ("Ivory", "FFFDF5"),
            ("Cream", "FFF7E0"),
            ("Soft yellow", "FFF3B0"),
            ("Soft blue", "EAF4FF"),
            ("Soft green", "ECF7EE"),
            ("Soft pink", "FCECEF"),
            ("Light gray", "F1F1EF"),
            ("Charcoal", "292927")
        ]
    }

    private func paperColorBinding(for page: NotyPage) -> Binding<Color> {
        Binding(
            get: { Color(hex: page.paperColorHex) },
            set: { color in
                guard let hex = color.hexString else { return }
                store.updatePageFormat(documentID: documentID, pageID: page.id, paperColorHex: hex)
            }
        )
    }

    private func saveCurrentInkColorPreset() {
        let preset = inkColorHex.uppercased()
        guard !customInkColors.contains(preset) else { return }
        customInkColorsStorage = (customInkColors + [preset]).joined(separator: ",")
    }

    @ViewBuilder
    private func canvasArea(_ document: NotyDocument, sourcePDF: PDFDocument?) -> some View {
        if let page = selectedPage {
            GeometryReader { proxy in
                let canvasSize = page.canvasSize
                let availableWidth = max(proxy.size.width - 48, 100)
                let availableHeight = max(proxy.size.height - 40, 100)
                let aspect = canvasSize.width / canvasSize.height
                let baseWidth = min(availableWidth, availableHeight * aspect, 880)
                let baseHeight = baseWidth / aspect
                let pageWidth = baseWidth * zoomScale
                let pageHeight = baseHeight * zoomScale

                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white)
                            .frame(width: pageWidth + 1, height: pageHeight + 1)
                            .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)

                        EditablePageCanvas(
                            documentID: documentID,
                            page: page,
                            store: store,
                            sourcePDF: sourcePDF,
                            canvasController: canvasController,
                            inkSettings: inkSettings,
                            isToolPickerVisible: isToolPickerVisible,
                            selectedTextBoxID: $selectedTextBoxID,
                            editingTextBoxID: $editingTextBoxID,
                            selectedImageID: $selectedImageID,
                            onDrawingChanged: { store.saveDrawing($0, documentID: documentID, pageID: page.id) },
                            onTextBoxesChanged: { store.updateTextBoxes(documentID: documentID, pageID: page.id, textBoxes: $0) },
                            onImagesChanged: { store.updatePageImages(documentID: documentID, pageID: page.id, images: $0) }
                        )
                        .frame(width: pageWidth, height: pageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(EditorPalette.border.opacity(0.7), lineWidth: 0.7))
                    }
                    .frame(minWidth: max(proxy.size.width, pageWidth + 48), minHeight: max(proxy.size.height, pageHeight + 40))
                    .padding(20)
                }
                .scrollIndicators(.visible)
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { magnification in
                            zoomScale = min(max(zoomBaseScale * magnification, 0.65), 3)
                        }
                        .onEnded { _ in
                            zoomBaseScale = zoomScale
                        }
                )
            }
            .background(EditorPalette.workspace)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(EditorPalette.secondaryInk)
                Text("This document has no pages")
                    .font(.system(size: 14, weight: .medium))
                Button("Add a blank page") {
                    store.addPage(documentID: documentID, after: nil, template: .blank)
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectInitialPage() {
        if selectedPageID == nil {
            selectedPageID = document?.pages.first?.id
        }
    }

    private func selectedPageIndex(in document: NotyDocument) -> Int? {
        guard let selectedPageID else { return document.pages.isEmpty ? nil : 0 }
        return document.pages.firstIndex(where: { $0.id == selectedPageID })
    }

    private func moveSelection(in document: NotyDocument, by delta: Int) {
        guard let index = selectedPageIndex(in: document) else { return }
        let nextIndex = min(max(index + delta, 0), document.pages.count - 1)
        guard document.pages.indices.contains(nextIndex) else { return }
        selectedPageID = document.pages[nextIndex].id
        selectedTextBoxID = nil
        editingTextBoxID = nil
    }

    private func addPage(template: NotyPageTemplate) {
        store.addPage(documentID: documentID, after: selectedPage?.id, template: template)
        if let updatedDocument = store.documents.first(where: { $0.id == documentID }),
           let currentIndex = updatedDocument.pages.firstIndex(where: { $0.id == selectedPageID }),
           updatedDocument.pages.indices.contains(currentIndex + 1) {
            selectedPageID = updatedDocument.pages[currentIndex + 1].id
        } else {
            selectedPageID = store.documents.first(where: { $0.id == documentID })?.pages.last?.id
        }
        selectedTextBoxID = nil
        selectedImageID = nil
    }

    private func duplicatePage(_ page: NotyPage) {
        guard let copy = store.duplicatePage(documentID: documentID, pageID: page.id) else { return }
        selectedPageID = copy.id
        selectedTextBoxID = nil
        editingTextBoxID = nil
        selectedImageID = nil
    }

    private func moveCurrentPage(in document: NotyDocument, by offset: Int) {
        guard let index = selectedPageIndex(in: document) else { return }
        let destination = index + offset
        guard document.pages.indices.contains(destination) else { return }
        store.movePage(documentID: documentID, from: IndexSet(integer: index), to: destination > index ? destination + 1 : destination)
    }

    private func addTextBox() {
        guard let page = selectedPage else { return }
        let index = page.textBoxes.count
        let box = NotyTextBox(
            id: UUID(),
            text: "Type something…",
            x: 50 + Double(index % 3) * 24,
            y: 70 + Double(index % 4) * 34,
            width: 260,
            height: 112,
            fontSize: 20
        )
        var boxes = page.textBoxes
        boxes.append(box)
        store.updateTextBoxes(documentID: documentID, pageID: page.id, textBoxes: boxes)
        selectedTextBoxID = box.id
        editingTextBoxID = box.id
        selectedImageID = nil
        isToolPickerVisible = false
    }

    private func updateTextBoxes(_ page: NotyPage, removing id: UUID) {
        store.updateTextBoxes(documentID: documentID, pageID: page.id, textBoxes: page.textBoxes.filter { $0.id != id })
        selectedTextBoxID = nil
        editingTextBoxID = nil
    }

    private func updateTextBox(_ page: NotyPage, boxID: UUID, mutation: (inout NotyTextBox) -> Void) {
        var boxes = page.textBoxes
        guard let index = boxes.firstIndex(where: { $0.id == boxID }) else { return }
        mutation(&boxes[index])
        store.updateTextBoxes(documentID: documentID, pageID: page.id, textBoxes: boxes)
    }

    private func updatePageImage(_ page: NotyPage, imageID: UUID, mutation: (inout NotyPageImage) -> Void) {
        var images = page.images
        guard let index = images.firstIndex(where: { $0.id == imageID }) else { return }
        mutation(&images[index])
        store.updatePageImages(documentID: documentID, pageID: page.id, images: images)
    }

    private func convertHandwritingToText(_ page: NotyPage) {
        let recognizedText = store.recognizedHandwriting(documentID: documentID, pageID: page.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recognizedText.isEmpty else {
            recognitionMessage = "No recognized handwriting is ready yet. Try again in a moment."
            return
        }
        let lines = recognizedText.components(separatedBy: .newlines).count
        let canvasSize = page.canvasSize
        let box = NotyTextBox(
            text: recognizedText,
            x: 36,
            y: 36,
            width: max(120, min(540, Double(canvasSize.width) - 72)),
            height: max(80, min(420, min(Double(canvasSize.height) - 72, Double(lines) * 28 + 24))),
            fontSize: 18
        )
        store.updateTextBoxes(documentID: documentID, pageID: page.id, textBoxes: page.textBoxes + [box])
        selectedTextBoxID = box.id
        editingTextBoxID = nil
    }

    private func exportPDF() {
        do {
            shareURL = try NotyExportService.exportPDF(documentID: documentID, store: store)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportPageImage() {
        guard let page = selectedPage else { return }
        do {
            shareURL = try NotyExportService.exportPageImage(documentID: documentID, pageID: page.id, store: store)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct PresentedPageCanvas: View {
    let documentID: UUID
    let page: NotyPage
    let store: NotyStore
    let sourcePDF: PDFDocument?

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = page.canvasSize
            let scale = min(proxy.size.width / canvasSize.width, proxy.size.height / canvasSize.height)
            let displayWidth = canvasSize.width * scale
            let displayHeight = canvasSize.height * scale

            ZStack(alignment: .topLeading) {
                PageBackground(
                    documentID: documentID,
                    page: page,
                    sourcePDF: sourcePDF,
                    imageSize: CGSize(width: canvasSize.width * 3, height: canvasSize.height * 3)
                )
                .frame(width: canvasSize.width, height: canvasSize.height)

                ForEach(page.images) { pageImage in
                    if let image = store.pageImage(documentID: documentID, pageID: page.id, image: pageImage) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: CGFloat(pageImage.width), height: CGFloat(pageImage.height))
                            .clipped()
                            .rotationEffect(.degrees(pageImage.rotationDegrees))
                            .position(
                                x: CGFloat(pageImage.x + pageImage.width / 2),
                                y: CGFloat(pageImage.y + pageImage.height / 2)
                            )
                    }
                }

                let drawing = store.drawing(documentID: documentID, pageID: page.id)
                if !drawing.strokes.isEmpty {
                    Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: 2))
                        .resizable()
                        .frame(width: canvasSize.width, height: canvasSize.height)
                }

                ForEach(page.textBoxes) { box in
                    PresentedTextBox(box: box)
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: displayWidth, height: displayHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.16), lineWidth: 0.7))
            .shadow(color: Color.black.opacity(0.45), radius: 22, x: 0, y: 8)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

private struct PresentedTextBox: View {
    let box: NotyTextBox

    private var styledFont: Font {
        var font = box.fontName.map { Font.custom($0, size: CGFloat(box.fontSize)) }
            ?? Font.system(size: CGFloat(box.fontSize))
        if box.isBold { font = font.weight(.bold) }
        if box.isItalic { font = font.italic() }
        return font
    }

    var body: some View {
        Text(box.text.isEmpty ? " " : box.text)
            .font(styledFont)
            .underline(box.isUnderlined)
            .foregroundStyle(Color(hex: box.colorHex))
            .multilineTextAlignment(box.alignment.textAlignment)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(
                width: CGFloat(box.width),
                height: CGFloat(box.height),
                alignment: box.alignment.frameAlignment
            )
            .position(
                x: CGFloat(box.x + box.width / 2),
                y: CGFloat(box.y + box.height / 2)
            )
    }
}

private struct EditablePageCanvas: View {
    let documentID: UUID
    let page: NotyPage
    let store: NotyStore
    let sourcePDF: PDFDocument?
    let canvasController: InkCanvasController
    let inkSettings: EditorInkSettings
    let isToolPickerVisible: Bool
    @Binding var selectedTextBoxID: UUID?
    @Binding var editingTextBoxID: UUID?
    @Binding var selectedImageID: UUID?
    let onDrawingChanged: (PKDrawing) -> Void
    let onTextBoxesChanged: ([NotyTextBox]) -> Void
    let onImagesChanged: ([NotyPageImage]) -> Void

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = page.canvasSize
            let scale = proxy.size.width / canvasSize.width
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    PageBackground(
                        documentID: documentID,
                        page: page,
                        sourcePDF: sourcePDF,
                        imageSize: CGSize(width: canvasSize.width * 3, height: canvasSize.height * 3)
                    )
                    .frame(width: canvasSize.width, height: canvasSize.height)

                    ForEach(page.images) { pageImage in
                        if let image = store.pageImage(documentID: documentID, pageID: page.id, image: pageImage) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: CGFloat(pageImage.width), height: CGFloat(pageImage.height))
                                .clipped()
                                .rotationEffect(.degrees(pageImage.rotationDegrees))
                                .position(
                                    x: CGFloat(pageImage.x + pageImage.width / 2),
                                    y: CGFloat(pageImage.y + pageImage.height / 2)
                                )
                                .allowsHitTesting(false)
                        }
                    }

                    PencilCanvasView(
                        drawing: store.drawing(documentID: documentID, pageID: page.id),
                        canvasSize: canvasSize,
                        controller: canvasController,
                        inkSettings: inkSettings,
                        isToolPickerVisible: isToolPickerVisible,
                        onDrawingChanged: onDrawingChanged
                    )
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .id(page.id)

                    ForEach(page.textBoxes) { box in
                        EditableTextBox(
                            box: box,
                            scale: 1,
                            isSelected: selectedTextBoxID == box.id,
                            isEditing: editingTextBoxID == box.id,
                            onSelect: {
                                selectedTextBoxID = box.id
                                selectedImageID = nil
                                if editingTextBoxID != box.id { editingTextBoxID = nil }
                            },
                            onTextChanged: { text in
                                var updated = page.textBoxes
                                guard let index = updated.firstIndex(where: { $0.id == box.id }) else { return }
                                updated[index].text = text
                                onTextBoxesChanged(updated)
                            },
                            onMove: { origin in
                                var updated = page.textBoxes
                                guard let index = updated.firstIndex(where: { $0.id == box.id }) else { return }
                                updated[index].x = Double(min(max(origin.x, 0), canvasSize.width - CGFloat(updated[index].width)))
                                updated[index].y = Double(min(max(origin.y, 0), canvasSize.height - CGFloat(updated[index].height)))
                                onTextBoxesChanged(updated)
                            },
                            onResize: { size in
                                var updated = page.textBoxes
                                guard let index = updated.firstIndex(where: { $0.id == box.id }) else { return }
                                updated[index].width = Double(min(max(size.width, 80), canvasSize.width - CGFloat(updated[index].x)))
                                updated[index].height = Double(min(max(size.height, 42), canvasSize.height - CGFloat(updated[index].y)))
                                onTextBoxesChanged(updated)
                            }
                        )
                    }

                    if let selectedImageID,
                       let selectedImage = page.images.first(where: { $0.id == selectedImageID }) {
                        EditableImageSelection(
                            image: selectedImage,
                            onMove: { origin in
                                var updated = page.images
                                guard let index = updated.firstIndex(where: { $0.id == selectedImage.id }) else { return }
                                updated[index].x = Double(min(max(origin.x, 0), canvasSize.width - CGFloat(updated[index].width)))
                                updated[index].y = Double(min(max(origin.y, 0), canvasSize.height - CGFloat(updated[index].height)))
                                onImagesChanged(updated)
                            },
                            onResize: { size in
                                var updated = page.images
                                guard let index = updated.firstIndex(where: { $0.id == selectedImage.id }) else { return }
                                let aspect = max(CGFloat(updated[index].width / max(updated[index].height, 1)), 0.05)
                                let width = min(max(size.width, 60), canvasSize.width - CGFloat(updated[index].x))
                                let height = min(max(width / aspect, 60), canvasSize.height - CGFloat(updated[index].y))
                                updated[index].width = Double(width)
                                updated[index].height = Double(height)
                                onImagesChanged(updated)
                            }
                        )
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .scaleEffect(scale, anchor: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(EditorPalette.paper)
        }
        .aspectRatio(page.canvasSize.width / page.canvasSize.height, contentMode: .fit)
    }
}

private struct PencilCanvasView: UIViewRepresentable {
    let drawing: PKDrawing
    let canvasSize: CGSize
    let controller: InkCanvasController
    let inkSettings: EditorInkSettings
    let isToolPickerVisible: Bool
    let onDrawingChanged: (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView(frame: .zero)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.contentSize = canvasSize
        canvas.tool = inkSettings.makeTool
        canvas.delegate = context.coordinator
        context.coordinator.toolPicker.addObserver(canvas)
        context.coordinator.toolPicker.setVisible(isToolPickerVisible, forFirstResponder: canvas)
        context.coordinator.controller = controller
        controller.attach(canvas, onDrawingChanged: onDrawingChanged)
        canvas.becomeFirstResponder()
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.contentSize = canvasSize
        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.controller = controller
        controller.attach(canvas, onDrawingChanged: onDrawingChanged)
        context.coordinator.toolPicker.setVisible(isToolPickerVisible, forFirstResponder: canvas)
        if context.coordinator.inkSettings != inkSettings {
            canvas.tool = inkSettings.makeTool
            context.coordinator.inkSettings = inkSettings
        }
        let currentData = canvas.drawing.dataRepresentation()
        let newData = drawing.dataRepresentation()
        if context.coordinator.pendingSave == nil && currentData != newData {
            context.coordinator.isApplyingExternalDrawing = true
            canvas.drawing = drawing
            context.coordinator.isApplyingExternalDrawing = false
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onDrawingChanged: (PKDrawing) -> Void
        let toolPicker = PKToolPicker()
        weak var controller: InkCanvasController?
        var inkSettings: EditorInkSettings?
        var pendingSave: Task<Void, Never>?
        var isApplyingExternalDrawing = false

        init(onDrawingChanged: @escaping (PKDrawing) -> Void) {
            self.onDrawingChanged = onDrawingChanged
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingExternalDrawing else { return }
            pendingSave?.cancel()
            let drawing = canvasView.drawing
            pendingSave = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                self?.onDrawingChanged(drawing)
                self?.pendingSave = nil
                self?.controller?.refreshUndoState()
            }
            controller?.refreshUndoState()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            pendingSave?.cancel()
            pendingSave = nil
            onDrawingChanged(canvasView.drawing)
            controller?.refreshUndoState()
        }
    }
}

@MainActor
private final class InkCanvasController: ObservableObject {
    @Published private(set) var undoState = 0
    weak var canvasView: PKCanvasView?
    var onDrawingChanged: ((PKDrawing) -> Void)?

    var canUndo: Bool {
        _ = undoState
        return canvasView?.undoManager?.canUndo == true
    }
    var canRedo: Bool {
        _ = undoState
        return canvasView?.undoManager?.canRedo == true
    }
    var isRulerActive: Bool { canvasView?.isRulerActive == true }

    func attach(_ canvas: PKCanvasView, onDrawingChanged: @escaping (PKDrawing) -> Void) {
        canvasView = canvas
        self.onDrawingChanged = onDrawingChanged
    }

    func undo() {
        canvasView?.undoManager?.undo()
        refreshUndoState()
    }

    func redo() {
        canvasView?.undoManager?.redo()
        refreshUndoState()
    }

    func toggleRuler() {
        guard let canvasView else { return }
        canvasView.isRulerActive.toggle()
        refreshUndoState()
    }

    func insertShape(_ shape: EditorShape, color: UIColor, width: Double, canvasSize: CGSize) {
        guard let canvas = canvasView else { return }
        let points = shape.controlPoints(in: canvasSize)
        let strokePoints = points.enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: Double(index) * 0.01,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
        let ink = PKInk(.pen, color: color)
        let stroke = PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
        let previous = canvas.drawing
        registerDrawingUndo(on: canvas, restoring: previous)
        canvas.drawing = PKDrawing(strokes: previous.strokes + [stroke])
        onDrawingChanged?(canvas.drawing)
        refreshUndoState()
    }

    func refreshUndoState() {
        undoState &+= 1
    }

    private func registerDrawingUndo(on canvas: PKCanvasView, restoring drawing: PKDrawing) {
        canvas.undoManager?.registerUndo(withTarget: canvas) { [weak self] target in
            let inverseDrawing = target.drawing
            self?.registerDrawingUndo(on: target, restoring: inverseDrawing)
            target.drawing = drawing
            self?.onDrawingChanged?(target.drawing)
            self?.refreshUndoState()
        }
    }
}

private enum EditorInkType: String, CaseIterable, Identifiable {
    case ballPen
    case fountainPen
    case brushPen
    case pencil
    case highlighter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ballPen: "Ball pen"
        case .fountainPen: "Fountain pen"
        case .brushPen: "Brush pen"
        case .pencil: "Pencil"
        case .highlighter: "Highlighter"
        }
    }

    var symbolName: String {
        switch self {
        case .ballPen: "pencil.tip"
        case .fountainPen: "pencil.tip.crop.circle"
        case .brushPen: "paintbrush.pointed"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        }
    }

    var inkType: PKInkingTool.InkType {
        switch self {
        case .ballPen: .pen
        case .fountainPen: .fountainPen
        case .brushPen: .watercolor
        case .pencil: .pencil
        case .highlighter: .marker
        }
    }
}

private struct EditorInkSettings: Equatable {
    let type: EditorInkType
    let color: UIColor
    let width: CGFloat

    static func == (lhs: EditorInkSettings, rhs: EditorInkSettings) -> Bool {
        lhs.type == rhs.type && lhs.color.isEqual(rhs.color) && lhs.width == rhs.width
    }

    var makeTool: any PKTool {
        PKInkingTool(type.inkType, color: color, width: width)
    }
}

private extension UIColor {
    convenience init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(digits, radix: 16) ?? 0x37352F
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: nil) else { return nil }
        return String(format: "%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }

    var isDarkBackground: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: nil) else { return false }
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance < 0.48
    }
}

private extension Color {
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }

    var hexString: String? {
        UIColor(self).hexString
    }
}

private enum EditorShape {
    case line
    case rectangle
    case ellipse

    func controlPoints(in size: CGSize) -> [CGPoint] {
        switch self {
        case .line:
            return [
                CGPoint(x: size.width * 0.2, y: size.height * 0.5),
                CGPoint(x: size.width * 0.8, y: size.height * 0.5)
            ]
        case .rectangle:
            let left = size.width * 0.25
            let right = size.width * 0.75
            let top = size.height * 0.35
            let bottom = size.height * 0.65
            return [
                CGPoint(x: left, y: top), CGPoint(x: right, y: top),
                CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom),
                CGPoint(x: left, y: top)
            ]
        case .ellipse:
            let radiusX = size.width * 0.23
            let radiusY = size.height * 0.14
            return (0...48).map { step in
                let angle = CGFloat(step) / 48 * .pi * 2
                return CGPoint(
                    x: size.width / 2 + cos(angle) * radiusX,
                    y: size.height / 2 + sin(angle) * radiusY
                )
            }
        }
    }
}

private struct PageBackground: View {
    let documentID: UUID
    let page: NotyPage
    let sourcePDF: PDFDocument?
    let imageSize: CGSize

    var body: some View {
        ZStack {
            Color(hex: page.paperColorHex)
            if let sourcePageIndex = page.sourcePageIndex, let sourcePDF {
                PDFPageBackground(documentID: documentID, pageIndex: sourcePageIndex, sourcePDF: sourcePDF, imageSize: imageSize)
            } else {
                PageTemplateView(template: page.template, paperColorHex: page.paperColorHex)
            }
        }
        .clipped()
    }
}

private struct PDFPageBackground: View {
    let documentID: UUID
    let pageIndex: Int
    let sourcePDF: PDFDocument
    let imageSize: CGSize
    @State private var snapshot: UIImage?

    var body: some View {
        Group {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(documentID.uuidString)-\(pageIndex)") {
            guard let sourcePage = sourcePDF.page(at: pageIndex) else {
                snapshot = nil
                return
            }
            snapshot = sourcePage.thumbnail(of: imageSize, for: .mediaBox)
        }
        .accessibilityHidden(true)
    }
}

private struct PageTemplateView: View {
    let template: NotyPageTemplate
    let paperColorHex: String

    private var line: Color {
        UIColor(hex: paperColorHex).isDarkBackground
            ? Color.white.opacity(0.24)
            : NotionTheme.templateLine
    }

    var body: some View {
        Canvas { context, size in
            switch template {
            case .blank:
                break
            case .ruled, .narrowRuled:
                let spacing = template == .narrowRuled ? 20.0 : 28.0
                stride(from: 34.0, through: size.height, by: spacing).forEach { y in
                    var path = Path()
                    path.move(to: CGPoint(x: 28, y: y))
                    path.addLine(to: CGPoint(x: size.width - 24, y: y))
                    context.stroke(path, with: .color(line), lineWidth: 0.7)
                }
                var margin = Path()
                margin.move(to: CGPoint(x: min(56, size.width * 0.12), y: 0))
                margin.addLine(to: CGPoint(x: min(56, size.width * 0.12), y: size.height))
                context.stroke(margin, with: .color(line.opacity(0.7)), lineWidth: 0.7)
            case .grid, .smallGrid:
                let spacing = template == .smallGrid ? 16.0 : 24.0
                stride(from: spacing, through: size.width, by: spacing).forEach { x in
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(line.opacity(0.8)), lineWidth: 0.55)
                }
                stride(from: spacing, through: size.height, by: spacing).forEach { y in
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(line.opacity(0.8)), lineWidth: 0.55)
                }
            case .dots:
                for x in stride(from: 18.0, through: size.width, by: 24.0) {
                    for y in stride(from: 18.0, through: size.height, by: 24.0) {
                        let rect = CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)
                        context.fill(Path(ellipseIn: rect), with: .color(line))
                    }
                }
            case .cornell:
                let cueX = max(90, size.width * 0.3)
                let summaryY = max(120, size.height - 110)
                var divider = Path()
                divider.move(to: CGPoint(x: cueX, y: 54))
                divider.addLine(to: CGPoint(x: cueX, y: summaryY))
                divider.move(to: CGPoint(x: 24, y: 54))
                divider.addLine(to: CGPoint(x: size.width - 24, y: 54))
                divider.move(to: CGPoint(x: 24, y: summaryY))
                divider.addLine(to: CGPoint(x: size.width - 24, y: summaryY))
                context.stroke(divider, with: .color(line.opacity(0.9)), lineWidth: 0.8)
                stride(from: 82.0, through: summaryY - 12, by: 28.0).forEach { y in
                    var path = Path()
                    path.move(to: CGPoint(x: cueX + 12, y: y))
                    path.addLine(to: CGPoint(x: size.width - 24, y: y))
                    context.stroke(path, with: .color(line.opacity(0.75)), lineWidth: 0.55)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct EditableImageSelection: View {
    let image: NotyPageImage
    let onMove: (CGPoint) -> Void
    let onResize: (CGSize) -> Void

    @State private var dragOffset = CGSize.zero
    @State private var dragOrigin = CGPoint.zero
    @State private var resizeOrigin: CGSize?
    @State private var isResizing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(EditorPalette.accent, style: StrokeStyle(lineWidth: 1.4, dash: [5, 3]))
            )
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(EditorPalette.paper)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(EditorPalette.accent, lineWidth: 1.5))
                    .offset(x: 5, y: 5)
                    .contentShape(Rectangle().inset(by: -10))
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { _ in
                                if resizeOrigin == nil {
                                    resizeOrigin = CGSize(width: image.width, height: image.height)
                                }
                                isResizing = true
                            }
                            .onEnded { value in
                                guard let resizeOrigin else { return }
                                onResize(CGSize(
                                    width: resizeOrigin.width + value.translation.width,
                                    height: resizeOrigin.height + value.translation.height
                                ))
                                self.resizeOrigin = nil
                                isResizing = false
                            }
                    )
                    .accessibilityLabel("Resize image")
            }
            .frame(width: CGFloat(image.width), height: CGFloat(image.height))
            .rotationEffect(.degrees(image.rotationDegrees))
            .position(
                x: CGFloat(image.x + image.width / 2),
                y: CGFloat(image.y + image.height / 2)
            )
            .offset(dragOffset)
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        guard !isResizing else { return }
                        if dragOrigin == .zero {
                            dragOrigin = CGPoint(x: CGFloat(image.x), y: CGFloat(image.y))
                        }
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        guard !isResizing else { return }
                        onMove(CGPoint(
                            x: dragOrigin.x + value.translation.width,
                            y: dragOrigin.y + value.translation.height
                        ))
                        dragOffset = .zero
                        dragOrigin = .zero
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Selected image")
            .accessibilityHint("Drag to move. Drag the corner handle to resize.")
    }
}

private struct EditableTextBox: View {
    let box: NotyTextBox
    let scale: CGFloat
    let isSelected: Bool
    let isEditing: Bool
    let onSelect: () -> Void
    let onTextChanged: (String) -> Void
    let onMove: (CGPoint) -> Void
    let onResize: (CGSize) -> Void

    @State private var text = ""
    @State private var dragOffset = CGSize.zero
    @State private var dragOrigin = CGPoint.zero
    @State private var resizeOrigin: CGSize?
    @State private var isResizing = false
    @FocusState private var isFocused: Bool

    private var styledFont: Font {
        let size = max(10, CGFloat(box.fontSize) * scale)
        var font = box.fontName.map { Font.custom($0, size: size) } ?? Font.system(size: size)
        if box.isBold { font = font.weight(.bold) }
        if box.isItalic { font = font.italic() }
        return font
    }

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: $text)
                    .font(styledFont)
                    .foregroundStyle(Color(hex: box.colorHex))
                    .multilineTextAlignment(box.alignment.textAlignment)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .onChange(of: text) { _, newValue in onTextChanged(newValue) }
                    .padding(5 * scale)
            } else {
                Text(box.text.isEmpty ? " " : box.text)
                    .font(styledFont)
                    .underline(box.isUnderlined)
                    .foregroundStyle(Color(hex: box.colorHex))
                    .multilineTextAlignment(box.alignment.textAlignment)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: box.alignment.frameAlignment)
                    .padding(9 * scale)
                    .contentShape(Rectangle())
            }
        }
        .background {
            if isSelected || isEditing {
                RoundedRectangle(cornerRadius: 6 * scale)
                    .fill(EditorPalette.paper)
            }
        }
        .overlay {
            if isSelected || isEditing {
                RoundedRectangle(cornerRadius: 6 * scale)
                    .stroke(isSelected ? EditorPalette.accent : EditorPalette.border, lineWidth: isSelected ? 1.2 : 0.7)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected && !isEditing {
                Circle()
                    .fill(EditorPalette.paper)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(EditorPalette.accent, lineWidth: 1.5))
                    .offset(x: 4, y: 4)
                    .contentShape(Rectangle().inset(by: -8))
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { _ in
                                if resizeOrigin == nil {
                                    resizeOrigin = CGSize(width: box.width, height: box.height)
                                }
                                isResizing = true
                            }
                            .onEnded { value in
                                guard let resizeOrigin else { return }
                                onResize(CGSize(
                                    width: resizeOrigin.width + value.translation.width / scale,
                                    height: resizeOrigin.height + value.translation.height / scale
                                ))
                                self.resizeOrigin = nil
                                isResizing = false
                            }
                    )
                    .accessibilityLabel("Resize text box")
            }
        }
        .frame(width: CGFloat(box.width) * scale, height: CGFloat(box.height) * scale)
        .position(x: (CGFloat(box.x) + CGFloat(box.width) / 2) * scale, y: (CGFloat(box.y) + CGFloat(box.height) / 2) * scale)
        .offset(dragOffset)
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    guard !isEditing, !isResizing else { return }
                    if dragOrigin == .zero { dragOrigin = CGPoint(x: CGFloat(box.x), y: CGFloat(box.y)) }
                    dragOffset = value.translation
                }
                .onEnded { value in
                    guard !isEditing, !isResizing else { return }
                    let origin = CGPoint(x: dragOrigin.x + value.translation.width / scale, y: dragOrigin.y + value.translation.height / scale)
                    onMove(origin)
                    dragOffset = .zero
                    dragOrigin = .zero
                    onSelect()
                }
        )
        .onChange(of: isEditing) { _, editing in
            isFocused = editing
        }
        .onChange(of: box.text) { _, newText in
            if text != newText { text = newText }
        }
        .onAppear {
            text = box.text
            isFocused = isEditing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(box.text.isEmpty ? "Text box" : box.text)
        .accessibilityHint(isEditing ? "Edit text" : "Drag to move")
    }
}

private extension NotyTextAlignment {
    var editorLabel: String {
        switch self {
        case .leading: "Left"
        case .center: "Center"
        case .trailing: "Right"
        }
    }

    var symbolName: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }
}

private struct PageThumbnail: View {
    let documentID: UUID
    let page: NotyPage
    let number: Int
    let store: NotyStore
    let sourcePDF: PDFDocument?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    PageBackground(documentID: documentID, page: page, sourcePDF: sourcePDF, imageSize: CGSize(width: 360, height: 466))
                    GeometryReader { proxy in
                        let scale = proxy.size.width / page.canvasSize.width
                        ForEach(page.images) { pageImage in
                            if let image = store.pageImage(documentID: documentID, pageID: page.id, image: pageImage) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(
                                        width: CGFloat(pageImage.width) * scale,
                                        height: CGFloat(pageImage.height) * scale
                                    )
                                    .clipped()
                                    .rotationEffect(.degrees(pageImage.rotationDegrees))
                                    .position(
                                        x: CGFloat(pageImage.x + pageImage.width / 2) * scale,
                                        y: CGFloat(pageImage.y + pageImage.height / 2) * scale
                                    )
                            }
                        }
                    }
                    .allowsHitTesting(false)

                    let drawing = store.drawing(documentID: documentID, pageID: page.id)
                    if !drawing.strokes.isEmpty {
                        Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: page.canvasSize), scale: 0.35))
                            .resizable()
                            .scaledToFill()
                    }
                    if page.isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(EditorPalette.ink)
                            .padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .aspectRatio(page.canvasSize.width / page.canvasSize.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSelected ? EditorPalette.selection : EditorPalette.border, lineWidth: isSelected ? 1.2 : 0.8))
                .shadow(color: Color.black.opacity(isSelected ? 0.06 : 0.02), radius: 2, x: 0, y: 1)
                Text("Page \(number)")
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? EditorPalette.ink : EditorPalette.secondaryInk)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private enum EditorPalette {
    static let workspace = NotionTheme.workspace
    static let rail = NotionTheme.sidebar
    static let paper = NotionTheme.paper
    static let pageShadow = NotionTheme.card
    static let ink = NotionTheme.ink
    static let secondaryInk = NotionTheme.inkSecondary
    static let border = NotionTheme.hairline
    static let control = Color.clear
    static let accent = NotionTheme.accent
    static let selection = NotionTheme.inkSecondary.opacity(0.72)
}

private struct PresenterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.white.opacity(0.55) : Color.white)
            .background(
                configuration.isPressed ? Color.white.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
    }
}

private struct EditorToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? NotionTheme.accent : NotionTheme.ink)
            .padding(.horizontal, 7)
            .frame(height: 30)
            .background(
                configuration.isPressed ? NotionTheme.rowPressed : Color.clear,
                in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium)
            )
            .contentShape(Rectangle())
    }
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

private extension NotyDocumentKind {
    var editorLabel: String {
        switch self {
        case .note: "Note"
        case .pdf: "PDF document"
        case .book: "Book"
        }
    }
}

private extension NotyPageTemplate {
    var editorLabel: String {
        switch self {
        case .blank: "Blank"
        case .ruled: "Ruled"
        case .narrowRuled: "Narrow ruled"
        case .grid: "Grid"
        case .smallGrid: "Small grid"
        case .dots: "Dotted"
        case .cornell: "Cornell"
        }
    }

    var symbolName: String {
        switch self {
        case .blank: "square"
        case .ruled, .narrowRuled: "line.3.horizontal"
        case .grid, .smallGrid: "grid"
        case .dots: "circle.grid.3x3"
        case .cornell: "rectangle.split.2x1"
        }
    }
}

private extension NotyPageSizePreset {
    var editorLabel: String {
        switch self {
        case .a4: "A4"
        case .a5: "A5"
        case .letter: "US Letter"
        case .legal: "US Legal"
        case .square: "Square"
        case .screen4x3: "Screen 4:3"
        case .widescreen16x9: "Widescreen 16:9"
        }
    }

    var symbolName: String {
        switch self {
        case .square: "square"
        case .screen4x3: "rectangle"
        case .widescreen16x9: "rectangle.wide"
        default: "doc"
        }
    }
}

private extension NotyPageOrientation {
    var editorLabel: String {
        switch self {
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        }
    }

    var symbolName: String {
        switch self {
        case .portrait: "rectangle.portrait"
        case .landscape: "rectangle"
        }
    }
}

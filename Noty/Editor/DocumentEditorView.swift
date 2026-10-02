import Combine
import PDFKit
import PencilKit
import PhotosUI
import SwiftUI
import UIKit

struct DocumentEditorView: View {
    let documentID: UUID
    let store: NotyStore
    var initialPageID: UUID? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var objectHistory = NotyPageObjectHistory()
    @StateObject private var canvasSessions = NotebookCanvasSessions()
    @State private var pageNavigationRequest: PageNavigationRequest?
    @State private var isSelectingExportPages = false
    @State private var pendingExportPageIDs: Set<UUID>?
    @State private var isArrangingPages = false

    private var canvasController: InkCanvasController { canvasSessions.controller(for: selectedPage?.id) }
    @AppStorage("noty.study.focusEndsAt") private var focusEndsAt = 0.0
    @AppStorage("noty.editor.fingerDrawing") private var fingerDrawing = false
    @State private var drawingTool: EditorDrawingTool = .ink
    @State private var isAddingPage = false
    @State private var isEditingCover = false
    @State private var isShowingStudyTools = false
    @State private var isShowingAudio = false
    @State private var lectureAudio = LectureAudioController()
    @State private var isShowingImageImporter = false
    @State private var croppingImage: NotyPageImage?
    @State private var isSearching = false
    @State private var activeToolSettings: EditorToolSettings?
    @State private var documentSearch = ""
    @State private var bookmarkPage: NotyPage?
    @State private var bookmarkName = ""
    @State private var selectedPageID: UUID?
    @State private var selectedTextBoxID: UUID?
    @State private var editingTextBoxID: UUID?
    @State private var selectedImageID: UUID?
    @State private var lassoSelection: NotyPageSelection?
    @AppStorage("noty.editor.lassoShape") private var lassoShapeValue = NotyLassoShape.freehand.rawValue
    @AppStorage("noty.editor.lassoInk") private var lassoIncludesInk = true
    @AppStorage("noty.editor.lassoText") private var lassoIncludesText = true
    @AppStorage("noty.editor.lassoPhotos") private var lassoIncludesPhotos = true
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
    @State private var lastPenType: EditorInkType = .ballPen
    @AppStorage("noty.editor.eraserWidth") private var eraserWidth = 20.0
    @AppStorage("noty.editor.eraseWholeStrokes") private var eraseWholeStrokes = false
    @AppStorage("noty.editor.highlighterWidth") private var highlighterWidth = 12.0
    @AppStorage("noty.editor.highlighterOpacity") private var highlighterOpacity = 0.38
    @AppStorage("noty.editor.shapeCorrection") private var shapeCorrectionEnabled = true
    @State private var inkColorHex = "222222"
    @State private var inkWidth = 2.5
    @State private var inkOpacity = 1.0
    @AppStorage("noty.editor.customInkColors") private var customInkColorsStorage = "222222,326BB8,C45C55"

    private var document: NotyDocument? {
        store.documents.first { $0.id == documentID }
    }

    private var selectedPage: NotyPage? {
        guard let document else { return nil }
        return document.pages.first { $0.id == selectedPageID } ?? document.pages.first
    }

    private var currentPaper: NotyPage {
        if let selectedPage, !selectedPage.isCover { return selectedPage }
        return document?.pages.first(where: { !$0.isCover }) ?? NotyPage(template: .ruled)
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
        .onDisappear { canvasSessions.flushAll(); store.removeUnusedPhotoAssets(documentID: documentID); lectureAudio.stopRecording(); lectureAudio.stopPlayback() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { canvasSessions.flushAll() }; if phase == .background { lectureAudio.stopRecording(); lectureAudio.stopPlayback() } }
        .onChange(of: selectedPageID) { _, _ in
            activeToolSettings = nil
        }
        .onChange(of: drawingTool) { _, tool in if tool != .lasso { lassoSelection = nil } }
        .onChange(of: canvasController.undoRevision) { _, _ in lassoSelection = nil }
        .sheet(item: $croppingImage) { image in
            if let page = selectedPage, let original = store.originalPageImage(documentID: documentID, pageID: page.id, image: image) {
                ImageCropSheet(image: original, pageImage: image) { updated in updatePageImage(page, imageID: image.id) { $0 = updated } }
            }
        }
        .sheet(isPresented: $isSearching) {
            NotebookSearchSheet(documentID: documentID, store: store) { pageID in
                navigate(to: pageID)
            }
        }
        .alert("Name bookmark", isPresented: Binding(get: { bookmarkPage != nil }, set: { if !$0 { bookmarkPage = nil } })) {
            TextField("Section title", text: $bookmarkName)
            Button("Save") { if let page = bookmarkPage { store.updatePageBookmark(documentID: documentID, pageID: page.id, isBookmarked: true, title: bookmarkName) }; bookmarkPage = nil }
            Button("Cancel", role: .cancel) { bookmarkPage = nil }
        }
        .sheet(isPresented: $isSelectingExportPages, onDismiss: {
            if let pageIDs = pendingExportPageIDs { pendingExportPageIDs = nil; exportPDF(selectedPageIDs: pageIDs) }
        }) {
            NotebookPageExportSheet(documentID: documentID, store: store, sourcePDF: sourcePDF, initialPageID: selectedPage?.id) { pageIDs in pendingExportPageIDs = pageIDs }
        }
        .sheet(isPresented: $isArrangingPages) { NotebookPageArrangementSheet(documentID: documentID, store: store) }
        .sheet(isPresented: $isAddingPage) {
            NotebookDesignSheet(purpose: .page, initialPage: currentPaper) { _, page, _, _ in
                addPage(template: page.template, format: page)
            }
        }
        .sheet(isPresented: $isEditingCover) {
            if let document {
                NotebookDesignSheet(purpose: .cover, initialTitle: document.title, initialCover: document.displayCover, existingCoverImage: store.coverImage(for: document)) { title, _, cover, imageData in
                    store.renameDocument(id: documentID, title: title)
                    do { try store.updateCover(documentID: documentID, cover: cover, imageData: imageData) } catch { imageImportError = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: $isShowingAudio) {
            LectureAudioSheet(documentID: documentID, pageID: selectedPage?.id, store: store, controller: lectureAudio) { pageID in navigate(to: pageID) }
        }
        .sheet(isPresented: $isShowingStudyTools) {
            StudyToolsSheet(documentID: documentID, store: store, selectedText: selectedPage?.textBoxes.first(where: { $0.id == selectedTextBoxID })?.text)
        }
        .fileImporter(isPresented: $isShowingImageImporter, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                guard let page = selectedPage else { return }
                let image = try objectHistory.addImage(store: store, undoManager: canvasController.undoManager, data: Data(contentsOf: url), documentID: documentID, pageID: page.id)
                selectedImageID = image.id; drawingTool = .hand
            } catch { imageImportError = error.localizedDescription }
        }
        .task(id: documentID) {
            sourcePDF = store.sourcePDF(documentID: documentID)
        }
        .onChange(of: document?.pages.map(\.id) ?? []) { _, pageIDs in
            if selectedPageID.map(pageIDs.contains) != true {
                if let first = pageIDs.first { navigate(to: first) } else { selectedPageID = nil }
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
                    let image = try objectHistory.addImage(store: store, undoManager: canvasController.undoManager, data: data, documentID: documentID, pageID: page.id)
                    activeToolSettings = nil
                    selectedImageID = image.id
                    selectedTextBoxID = nil
                    editingTextBoxID = nil
                    isToolPickerVisible = false
                    drawingTool = .hand
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
                HStack(spacing: 0) {
                    if isShowingThumbnails && document.kind != .whiteboard {
                        thumbnailRail(document, sourcePDF: sourcePDF)
                            .padding(.top, 48)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        Rectangle().fill(EditorPalette.border).frame(width: 1)
                    }
                    canvasArea(document, sourcePDF: sourcePDF)
                        .overlay {
                            FloatingNotebookToolbar(onDragBegan: { activeToolSettings = nil }) { vertical, compact in
                                toolbarContents(document, vertical: vertical, compact: compact)
                            }.padding(.top, horizontalSizeClass == .compact ? 48 : 0)
                        }
                        .overlay(alignment: .leading) {
                            if !isShowingThumbnails && document.kind != .whiteboard {
                                Color.clear.frame(width: 24).contentShape(Rectangle())
                                    .gesture(DragGesture(minimumDistance: 16).onEnded { value in
                                        if value.translation.width > 55 && abs(value.translation.width) > abs(value.translation.height) { togglePageSidebar() }
                                    })
                                    .accessibilityLabel("Show pages").accessibilityAction { togglePageSidebar() }
                            }
                        }
                }
                .overlay(alignment: .top) { header(document) }

            }
        }
        .ignoresSafeArea(.container, edges: UIDevice.current.userInterfaceIdiom == .pad ? .vertical : .bottom)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
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
        HStack {
            Button { canvasSessions.flushAll(); dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }.buttonStyle(NotionIconButtonStyle()).accessibilityLabel("Back to Home")
            Spacer()
            Menu {
                Button(isShowingThumbnails ? "Hide pages" : "Show pages", systemImage: "sidebar.left") { togglePageSidebar() }
                    .disabled(document.kind == .whiteboard)
                Button("Search notebook", systemImage: "magnifyingglass") { canvasSessions.flushAll(); isSearching = true }
                if document.kind != .whiteboard {
                    Menu("Add page", systemImage: "plus") {
                        Button("Use current paper", systemImage: "doc.badge.plus") { addPage(template: currentPaper.template) }
                        Button("Choose design…", systemImage: "square.grid.2x2") { isAddingPage = true }
                    }
                    Button("Arrange pages", systemImage: "arrow.up.arrow.down") { canvasSessions.flushAll(); isArrangingPages = true }
                    Button("Present", systemImage: "play.rectangle") { startPresentation() }
                }
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button(document.kind == .whiteboard ? "Export whiteboard as PDF" : "Export all pages as PDF", systemImage: "doc.richtext") { exportPDF() }
                    if document.kind != .whiteboard {
                        Button("Export selected pages…", systemImage: "checkmark.square") { canvasSessions.flushAll(); isSelectingExportPages = true }
                    }
                    Button(document.kind == .whiteboard ? "Export whiteboard as image" : "Export current page as image", systemImage: "photo") { exportPageImage() }
                }
                if document.kind == .whiteboard, let page = selectedPage {
                    Menu("Board background", systemImage: "paintpalette") {
                        NotebookPaperMenus(documentID: documentID, page: page, store: store, isInfinite: true, prepare: { canvasSessions.flushAll() })
                    }
                }
                Section(document.title) {
                    Button("Rename", systemImage: "pencil") { renameTitle = document.title; isShowingRename = true }
                    if document.kind != .whiteboard { Button("Edit cover", systemImage: "book.closed") { isEditingCover = true } }
                    Button("Lecture audio", systemImage: "mic") { isShowingAudio = true }
                    Button("Study tools", systemImage: "rectangle.on.rectangle") { isShowingStudyTools = true }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }.buttonStyle(NotionIconButtonStyle()).accessibilityLabel("Document options").accessibilityIdentifier("editor.documentOptions")
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
    }

    private func startPresentation() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            isPresenterControlsVisible = true; isLaserPointerEnabled = false
            presenterLaserLocation = nil; isPresenterBlackout = false; isPresentationMode = true
        }
    }

    private func togglePageSidebar() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isShowingThumbnails.toggle() }
    }

    private func thumbnailRail(_ document: NotyDocument, sourcePDF: PDFDocument?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                NotionSectionLabel(text: "Pages")
                Spacer()
                Text("\(document.pages.count)")
                    .font(NotionTheme.captionSmall)
                    .foregroundStyle(EditorPalette.secondaryInk)
            }
            .padding(.horizontal, 3)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                        PageThumbnail(
                            documentID: documentID,
                            page: page,
                            number: index + 1,
                            store: store,
                            sourcePDF: sourcePDF,
                            isSelected: page.id == selectedPage?.id
                        ) {
                            navigate(to: page.id)
                        }
                        .overlay(alignment: .topTrailing) {
                            Menu { pageActions(page, in: document) } label: {
                                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                                    .frame(width: 30, height: 28)
                                    .background(NotionTheme.card.opacity(0.95), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).padding(5)
                                .accessibilityLabel("Page \(index + 1) options").accessibilityIdentifier("editor.pageOptions.\(page.id)")
                        }
                        .draggable(page.id.uuidString)
                        .dropDestination(for: String.self) { values, _ in
                            guard let value = values.first,
                                  let fromID = UUID(uuidString: value),
                                  let fromIndex = document.pages.firstIndex(where: { $0.id == fromID }),
                                  let toIndex = document.pages.firstIndex(where: { $0.id == page.id }),
                                  !document.pages[fromIndex].isCover, !page.isCover,
                                  fromIndex != toIndex else { return false }
                            let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
                            store.movePage(documentID: documentID, from: IndexSet(integer: fromIndex), to: destination)
                            return true
                        }
                        .contextMenu { pageActions(page, in: document) }
                    }

                    Menu {
                        Button("Use current paper", systemImage: "doc.badge.plus") { addPage(template: currentPaper.template) }
                        Button("Choose a different design…", systemImage: "square.grid.2x2") { isAddingPage = true }
                    } label: {
                        Label("New page", systemImage: "plus")
                            .font(NotionTheme.bodySmall)
                            .foregroundStyle(EditorPalette.secondaryInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(NotionTheme.rowHover, in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium))
                    }
                    .buttonStyle(NotionRowButtonStyle())
                }
                .padding(.vertical, 2)
            }
        }
        .padding(11)
        .frame(width: 184)
        .background(NotionTheme.sidebar)
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.width < -55 && abs(value.translation.width) > abs(value.translation.height) { togglePageSidebar() }
        })
        .accessibilityHint("Swipe left to hide pages. Drag a page to reorder it.")
    }

    @ViewBuilder
    private func pageActions(_ page: NotyPage, in document: NotyDocument) -> some View {
        NotebookPaperMenus(documentID: documentID, page: page, store: store,
                           prepare: { canvasSessions.flushAll() }, editCover: { isEditingCover = true })
        Section {
            Button(page.isBookmarked ? "Remove bookmark" : "Bookmark", systemImage: "bookmark") {
                store.updatePageBookmark(documentID: documentID, pageID: page.id, isBookmarked: !page.isBookmarked)
            }
            Button("Name bookmark", systemImage: "bookmark.fill") { bookmarkPage = page; bookmarkName = page.bookmarkTitle ?? "" }
            Button("Add page after", systemImage: "plus.rectangle.on.rectangle") { activate(page.id); addPage(template: page.template) }
            Button("Duplicate page", systemImage: "plus.square.on.square") { canvasSessions.flushAll(); duplicatePage(page) }.disabled(page.isCover)
            Button("Move earlier", systemImage: "arrow.up") { movePage(page, in: document, by: -1) }
                .disabled(page.isCover || (document.pages.firstIndex(where: { $0.id == page.id }) ?? 0) <= (document.pages.first?.isCover == true ? 1 : 0))
            Button("Move later", systemImage: "arrow.down") { movePage(page, in: document, by: 1) }
                .disabled(page.isCover || page.id == document.pages.last?.id)
            Button("Arrange pages…", systemImage: "arrow.up.arrow.down") { canvasSessions.flushAll(); isArrangingPages = true }
            Button("Export this page as PDF", systemImage: "square.and.arrow.up") {
                canvasSessions.flushAll()
                do { shareURL = try NotyExportService.exportPDF(documentID: documentID, store: store, selectedPageIDs: [page.id]) }
                catch { exportError = error.localizedDescription }
            }
            Button("Delete page", systemImage: "trash", role: .destructive) { canvasSessions.flushAll(); store.deletePage(documentID: documentID, pageID: page.id) }.disabled(page.isCover)
        }
    }

    private func movePage(_ page: NotyPage, in document: NotyDocument, by offset: Int) {
        guard let index = document.pages.firstIndex(where: { $0.id == page.id }) else { return }
        let destination = index + offset
        guard document.pages.indices.contains(destination) else { return }
        canvasSessions.flushAll()
        store.movePage(documentID: documentID, from: IndexSet(integer: index), to: destination > index ? destination + 1 : destination)
    }

    private func toolbarContents(_ document: NotyDocument, vertical: Bool, compact: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        return layout {
            Button { editingTextBoxID = nil; lassoSelection = nil; canvasController.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!canvasController.canUndo).accessibilityLabel("Undo")
            Button { editingTextBoxID = nil; lassoSelection = nil; canvasController.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!canvasController.canRedo).accessibilityLabel("Redo")
            toolbarDivider(vertical: vertical)
            Button {
                if drawingTool == .ink && inkType != .highlighter { activeToolSettings = .pen }
                else { selectDrawingTool(.ink); inkType = lastPenType }
            } label: { Image(systemName: "pencil.tip") }
                .buttonStyle(NotebookToolButtonStyle(isSelected: drawingTool == .ink && inkType != .highlighter, compact: compact))
                .accessibilityLabel("Pen").accessibilityHint("Tap again for pen type, thickness and color")
                .popover(isPresented: settingsPresented(.pen)) { inkSettingsPopover(highlighter: false) }
            Button {
                if drawingTool == .ink && inkType == .highlighter { activeToolSettings = .highlighter }
                else { if inkType != .highlighter { lastPenType = inkType }; selectDrawingTool(.ink); inkType = .highlighter }
            } label: { Image(systemName: "highlighter") }
                .buttonStyle(NotebookToolButtonStyle(isSelected: drawingTool == .ink && inkType == .highlighter, compact: compact))
                .accessibilityLabel("Highlighter").accessibilityHint("Tap again for highlighter settings")
                .popover(isPresented: settingsPresented(.highlighter)) { inkSettingsPopover(highlighter: true) }
            Button {
                if drawingTool == .eraser { activeToolSettings = .eraser }
                else { selectDrawingTool(.eraser) }
            } label: { Image(systemName: "eraser") }
                .buttonStyle(NotebookToolButtonStyle(isSelected: drawingTool == .eraser, compact: compact))
                .accessibilityLabel("Eraser").accessibilityHint("Tap again for eraser size and mode")
                .popover(isPresented: settingsPresented(.eraser)) { eraserSettingsPopover }
            Button {
                if drawingTool == .lasso { activeToolSettings = .lasso }
                else { selectDrawingTool(.lasso) }
            } label: { Image(systemName: "lasso") }
                .buttonStyle(NotebookToolButtonStyle(isSelected: drawingTool == .lasso, compact: compact))
                .accessibilityLabel("Lasso selection").accessibilityHint("Tap again for selection settings")
                .popover(isPresented: settingsPresented(.lasso)) { lassoSettingsPopover }
            Button {
                if selectedTextBoxID != nil { activeToolSettings = .text }
                else { selectDrawingTool(.hand); addTextBox() }
            } label: { Image(systemName: "textformat") }
                .buttonStyle(NotebookToolButtonStyle(isSelected: selectedTextBoxID != nil, compact: compact))
                .disabled(selectedPage == nil).accessibilityLabel("Text")
                .popover(isPresented: settingsPresented(.text)) { textSettingsPopover }
            Button { activeToolSettings = .photo } label: { Image(systemName: "photo") }
                .buttonStyle(NotebookToolButtonStyle(isSelected: selectedImageID != nil, compact: compact))
                .disabled(selectedPage == nil).accessibilityLabel("Photos")
                .popover(isPresented: settingsPresented(.photo)) { photoSettingsPopover }
            Button {
                if drawingTool == .hand && selectedTextBoxID == nil && selectedImageID == nil { activeToolSettings = .hand }
                else { selectDrawingTool(.hand) }
            } label: { Image(systemName: "hand.draw") }
                .buttonStyle(NotebookToolButtonStyle(isSelected: drawingTool == .hand && selectedTextBoxID == nil && selectedImageID == nil, compact: compact))
                .accessibilityLabel("Pan and select objects")
                .popover(isPresented: settingsPresented(.hand)) {
                    NotebookToolSettings(title: "Navigation") {
                        Toggle("Draw with finger", isOn: $fingerDrawing)
                        Text("Drag to move around the page. Pinch with two fingers to zoom. Tap text or a photo to select it.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.presentationCompactAdaptation(.popover)
                }
            if !compact {
            toolbarDivider(vertical: vertical)
            ForEach(Array(customInkColors.prefix(3)), id: \.self) { colorHex in
                Button { inkColorHex = colorHex } label: {
                    Circle().fill(Color(hex: colorHex)).frame(width: 21, height: 21)
                        .overlay(Circle().stroke(NotionTheme.ink.opacity(0.22), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().stroke(inkColorHex == colorHex ? NotionTheme.ink : .clear, lineWidth: 2))
                        .frame(width: 32, height: 36)
                }.buttonStyle(.plain).accessibilityLabel("\(colorName(for: colorHex)) ink")
                    .accessibilityAddTraits(inkColorHex == colorHex ? .isSelected : [])
            }
            toolbarDivider(vertical: vertical)
            ForEach(widthPresets, id: \.self) { width in
                Button { activeWidth.wrappedValue = width } label: {
                    Circle().fill(NotionTheme.ink).frame(width: min(max(width, 4), 14), height: min(max(width, 4), 14))
                        .frame(width: 26, height: 26)
                        .background(NotionTheme.ink.opacity(abs(activeWidth.wrappedValue - width) < 0.1 ? 0.16 : 0), in: Circle())
                        .overlay(Circle().stroke(abs(activeWidth.wrappedValue - width) < 0.1 ? NotionTheme.ink.opacity(0.75) : .clear, lineWidth: 1.5))
                        .frame(width: 32, height: 36)
                }.buttonStyle(.plain).accessibilityLabel("\(width.formatted()) point thickness")
                    .accessibilityAddTraits(abs(activeWidth.wrappedValue - width) < 0.1 ? .isSelected : [])
            }
            toolbarDivider(vertical: vertical)
            }
            editorOptions(document)
        }
        .buttonStyle(NotebookToolButtonStyle(compact: compact))
    }

    private func settingsPresented(_ settings: EditorToolSettings) -> Binding<Bool> {
        Binding(get: { activeToolSettings == settings }, set: { if !$0 && activeToolSettings == settings { activeToolSettings = nil } })
    }

    private func selectDrawingTool(_ tool: EditorDrawingTool) {
        activeToolSettings = nil
        drawingTool = tool
        isToolPickerVisible = false
        selectedImageID = nil; selectedTextBoxID = nil; editingTextBoxID = nil
    }

    private var activeWidth: Binding<Double> {
        if drawingTool == .eraser { return $eraserWidth }
        return inkType == .highlighter ? $highlighterWidth : $inkWidth
    }

    private var widthPresets: [Double] {
        if drawingTool == .eraser { return [8, 20, 36] }
        return inkType == .highlighter ? [6, 12, 20] : [1, 2.5, 5]
    }

    private func inkSettingsPopover(highlighter: Bool) -> some View {
        NotebookToolSettings(title: highlighter ? "Highlighter" : "Pen") {
            if !highlighter {
                Picker("Pen type", selection: $inkType) {
                    ForEach(EditorInkType.allCases.filter { $0 != .highlighter }) { type in Text(type.label).tag(type) }
                }.pickerStyle(.menu)
                    .onChange(of: inkType) { _, type in if type != .highlighter { lastPenType = type } }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Thickness"); Spacer(); Text("\(activeWidth.wrappedValue, specifier: "%.1f") pt").foregroundStyle(.secondary).monospacedDigit() }
                Slider(value: activeWidth, in: highlighter ? 4...30 : 0.5...14, step: 0.5)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Opacity"); Spacer(); Text("\(Int((highlighter ? highlighterOpacity : inkOpacity) * 100))%").foregroundStyle(.secondary).monospacedDigit() }
                Slider(value: highlighter ? $highlighterOpacity : $inkOpacity, in: 0.15...1, step: 0.05)
            }
            ColorPicker("Color", selection: inkColorSelection, supportsOpacity: false)
            HStack {
                ForEach(customInkColors, id: \.self) { hex in
                    Button { inkColorHex = hex } label: { Circle().fill(Color(hex: hex)).frame(width: 28, height: 28).overlay(Circle().stroke(NotionTheme.borderStrong, lineWidth: 1)) }
                        .buttonStyle(.plain).accessibilityLabel(colorName(for: hex))
                }
            }
            Button("Save color preset", systemImage: "plus.circle") { saveCurrentInkColorPreset() }
        }.tint(NotionTheme.accent).presentationCompactAdaptation(.popover)
    }

    private var eraserSettingsPopover: some View {
        NotebookToolSettings(title: "Eraser") {
            Picker("Erase", selection: $eraseWholeStrokes) {
                Text("Pixels").tag(false); Text("Whole strokes").tag(true)
            }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Size"); Spacer(); Text("\(Int(eraserWidth)) pt").foregroundStyle(.secondary).monospacedDigit() }
                Slider(value: $eraserWidth, in: 4...60, step: 1)
            }.disabled(eraseWholeStrokes)
        }.tint(NotionTheme.accent).presentationCompactAdaptation(.popover)
    }

    private var lassoSettingsPopover: some View {
        NotebookToolSettings(title: "Lasso") {
            Picker("Selection shape", selection: $lassoShapeValue) {
                ForEach(NotyLassoShape.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.segmented)
            Toggle("Handwriting", isOn: $lassoIncludesInk)
            Toggle("Text boxes", isOn: $lassoIncludesText)
            Toggle("Photos", isOn: $lassoIncludesPhotos)
        }.tint(NotionTheme.accent).presentationCompactAdaptation(.popover)
    }

    private var textSettingsPopover: some View {
        NotebookToolSettings(title: "Text") {
            textObjectControls
            Button("Add text box", systemImage: "plus") { activeToolSettings = nil; selectDrawingTool(.hand); addTextBox() }
        }.presentationCompactAdaptation(.popover)
    }

    private var textObjectControls: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                        Section("Lists") {
                            Button("Bullet list", systemImage: "list.bullet") { updateTextBox(page, boxID: textBox.id) { $0.text = $0.text.components(separatedBy: "\n").map { "• " + $0 }.joined(separator: "\n") } }
                            Button("Numbered list", systemImage: "list.number") { updateTextBox(page, boxID: textBox.id) { $0.text = $0.text.components(separatedBy: "\n").enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") } }
                            Button("Checklist", systemImage: "checklist") { updateTextBox(page, boxID: textBox.id) { $0.text = $0.text.components(separatedBy: "\n").map { "☐ " + $0 }.joined(separator: "\n") } }
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
                        Label("Formatting", systemImage: "textformat")
                    }
                    .accessibilityLabel("Text formatting")
                    Button { UIPasteboard.general.string = textBox.text } label: { Label("Copy text", systemImage: "doc.on.doc") }.accessibilityLabel("Copy text")
                    Button { duplicateTextBox(textBox, page: page) } label: { Label("Duplicate text box", systemImage: "plus.square.on.square") }.accessibilityLabel("Duplicate text box")

                    Button {
                        editingTextBoxID = editingTextBoxID == textBox.id ? nil : textBox.id
                    } label: {
                        Label(editingTextBoxID == textBox.id ? "Done editing" : "Edit text", systemImage: editingTextBoxID == textBox.id ? "checkmark" : "square.and.pencil")
                    }
                    .accessibilityLabel(editingTextBoxID == textBox.id ? "Done editing text" : "Edit text")

                    Button(role: .destructive) {
                        updateTextBoxes(page, removing: textBox.id)
                    } label: {
                        Label("Delete text box", systemImage: "trash")
                    }
                    .accessibilityLabel("Delete text box")
                }

        }.buttonStyle(.borderless).labelStyle(.titleAndIcon)
    }

    private var photoSettingsPopover: some View {
        NotebookToolSettings(title: "Photos") {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) { Label("Add from Photos", systemImage: "photo.badge.plus") }
            Button("Image from Files", systemImage: "folder") { activeToolSettings = nil; isShowingImageImporter = true }
            Button("Paste", systemImage: "doc.on.clipboard") { activeToolSettings = nil; pasteObject() }
            photoObjectControls
        }.buttonStyle(.borderless).labelStyle(.titleAndIcon).presentationCompactAdaptation(.popover)
    }

    private var photoObjectControls: some View {
        VStack(alignment: .leading, spacing: 16) {
                if let page = selectedPage, !page.images.isEmpty {
                    Menu {
                        ForEach(Array(page.images.enumerated()), id: \.element.id) { index, image in
                            Button {
                                drawingTool = .hand
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
                        Label("Select photo", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityLabel("Select page image")
                }

                if let page = selectedPage,
                   let selectedImageID,
                   let selectedImage = page.images.first(where: { $0.id == selectedImageID }) {
                    Button {
                        updatePageImage(page, imageID: selectedImage.id) { $0.rotationDegrees -= 90 }
                    } label: {
                        Label("Rotate left", systemImage: "rotate.left")
                    }
                    .accessibilityLabel("Rotate image left")

                    Button {
                        updatePageImage(page, imageID: selectedImage.id) { $0.rotationDegrees += 90 }
                    } label: {
                        Label("Rotate right", systemImage: "rotate.right")
                    }
                    .accessibilityLabel("Rotate image right")
                    Button { activeToolSettings = nil; croppingImage = selectedImage } label: { Label("Crop photo", systemImage: "crop") }.accessibilityLabel("Crop image")
                    Button { copyImage(selectedImage, page: page) } label: { Label("Copy photo", systemImage: "doc.on.doc") }.accessibilityLabel("Copy image")

                    Button(role: .destructive) {
                        objectHistory.updateImages(
                            store: store, undoManager: canvasController.undoManager, documentID: documentID,
                            pageID: page.id,
                            images: page.images.filter { $0.id != selectedImage.id }
                        )
                        self.selectedImageID = nil
                    } label: {
                        Label("Delete photo", systemImage: "trash")
                    }
                    .accessibilityLabel("Delete image")
                }

        }.buttonStyle(.borderless).labelStyle(.titleAndIcon)
    }

    private func editorOptions(_ document: NotyDocument) -> some View {
        Menu {
            Button { canvasController.toggleRuler() } label: {
                Label(canvasController.isRulerActive ? "Hide ruler" : "Show ruler", systemImage: "ruler")
            }
            Toggle("Draw and hold to perfect shapes", isOn: $shapeCorrectionEnabled)
            Toggle("Draw with finger", isOn: $fingerDrawing)
            Menu("Insert shape", systemImage: "square.on.circle") {
                Button("Straight line", systemImage: "line.diagonal") { insertShape(.line) }
                Button("Rectangle", systemImage: "rectangle") { insertShape(.rectangle) }
                Button("Ellipse", systemImage: "circle") { insertShape(.ellipse) }
            }
            if let page = selectedPage {
                Button("Convert handwriting to text", systemImage: "character.book.closed") { convertHandwritingToText(page) }
            }
            Button("Fit page", systemImage: "arrow.up.left.and.arrow.down.right") { setZoom(1) }
                .disabled(document.kind == .whiteboard)
        } label: { Image(systemName: "ellipsis") }
            .accessibilityLabel("Writing options").accessibilityIdentifier("editor.options")
    }

    private var boardCenter: CGPoint? {
        guard document?.kind == .whiteboard, let page = selectedPage else { return nil }
        return CGPoint(x: page.viewportCenterX ?? Double(page.canvasSize.width / 2), y: page.viewportCenterY ?? Double(page.canvasSize.height / 2))
    }
    private var insertionOrigin: CGPoint { boardCenter.map { CGPoint(x: $0.x - 130, y: $0.y - 56) } ?? CGPoint(x: 52, y: 70) }

    private func insertShape(_ shape: EditorShape) {
        canvasController.insertShape(shape, color: inkUIColor, width: inkWidth, canvasSize: selectedPage?.canvasSize ?? CGSize(width: 612, height: 792), center: boardCenter)
    }

    private func toolbarDivider(vertical: Bool) -> some View {
        Rectangle().fill(NotionTheme.ink.opacity(0.14))
            .frame(width: vertical ? 24 : 1, height: vertical ? 1 : 22).padding(vertical ? .vertical : .horizontal, 4)
    }

    private var inkColor: Color { Color(hex: inkColorHex) }
    private var inkUIColor: UIColor { UIColor(hex: inkColorHex).withAlphaComponent(inkOpacity) }
    private var inkSettings: EditorInkSettings {
        EditorInkSettings(type: inkType, color: inkType == .highlighter ? UIColor(hex: inkColorHex).withAlphaComponent(highlighterOpacity) : inkUIColor, width: inkType == .highlighter ? CGFloat(highlighterWidth) : CGFloat(inkWidth), tool: drawingTool, fingerDrawing: fingerDrawing, eraserWidth: CGFloat(eraserWidth), eraseWholeStrokes: eraseWholeStrokes, shapeCorrectionEnabled: shapeCorrectionEnabled)
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
        case "222222", "37352F": "Ink"
        case "C45C55", "D34836": "Red"
        case "326BB8", "2383E2": "Blue"
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
        if document.kind == .whiteboard, let page = selectedPage {
            InfiniteCanvasViewport(canvasSize: page.canvasSize,
                initialCenter: CGPoint(x: page.viewportCenterX ?? Double(page.canvasSize.width / 2), y: page.viewportCenterY ?? Double(page.canvasSize.height / 2)),
                paperColor: UIColor(notyHex: page.paperColorHex),
                panWithTwoFingers: (fingerDrawing && drawingTool != .hand) || drawingTool == .lasso || selectedTextBoxID != nil || selectedImageID != nil,
                onExpand: { expansion in
                    canvasController.flush()
                    guard store.expandWhiteboard(documentID: documentID, pageID: page.id, expansion: expansion) else { return false }
                    canvasController.translateCoordinateOrigin(by: expansion.translation)
                    canvasController.applyDrawing(store.drawing(documentID: documentID, pageID: page.id), pageID: page.id)
                    return true
                },
                onViewportSettled: { center in store.updateWhiteboardViewport(documentID: documentID, pageID: page.id, center: center) }) {
                    editableCanvas(page, sourcePDF: sourcePDF).frame(width: page.canvasSize.width, height: page.canvasSize.height)
                }
                .accessibilityIdentifier("editor.infiniteCanvas")
        } else if !document.pages.isEmpty {
            GeometryReader { geometry in
                let layout = NotyPageFlowLayout(pages: document.pages, viewport: geometry.size, zoom: zoomScale)
                ScrollViewReader { scroll in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(spacing: NotyPageFlowLayout.spacing) {
                            ForEach(document.pages) { page in
                                if let item = layout.items.first(where: { $0.id == page.id }) {
                                    editableCanvas(page, sourcePDF: sourcePDF)
                                        .frame(width: item.size.width, height: item.size.height)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(EditorPalette.border, lineWidth: 0.7))
                                        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
                                        .frame(width: layout.contentWidth)
                                        .id(page.id)
                                }
                            }
                        }
                        .padding(.vertical, NotyPageFlowLayout.inset)
                        .frame(minHeight: geometry.size.height, alignment: .top)
                    }
                    .scrollIndicators(.visible)
                    .onScrollGeometryChange(for: UUID?.self, of: { geometry in
                        layout.pageID(at: geometry.contentOffset.y + geometry.containerSize.height / 2)
                    }) { _, pageID in if let pageID { activate(pageID) } }
                    .onChange(of: pageNavigationRequest) { _, request in
                        if let request { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { scroll.scrollTo(request.pageID, anchor: .center) } }
                    }
                    .onAppear { if let pageID = selectedPage?.id { scroll.scrollTo(pageID, anchor: .center) } }
                    .simultaneousGesture(MagnificationGesture().onChanged { magnification in
                        zoomScale = min(max(zoomBaseScale * magnification, 0.65), 3)
                    }.onEnded { _ in zoomBaseScale = zoomScale })
                }
            }.background(NotionTheme.canvas).accessibilityIdentifier("editor.continuousPages")
        } else { ContentUnavailableView("No pages", systemImage: "doc", description: Text("Add a page to start writing.")) }
    }

    private func editableCanvas(_ page: NotyPage, sourcePDF: PDFDocument?) -> some View {
        let controller = canvasSessions.controller(for: page.id)
        return EditablePageCanvas(documentID: documentID, page: page, store: store, sourcePDF: sourcePDF,
            canvasController: controller, inkSettings: inkSettings, isToolPickerVisible: isToolPickerVisible,
            selectedTextBoxID: $selectedTextBoxID, editingTextBoxID: $editingTextBoxID,
            selectedImageID: $selectedImageID, lassoSelection: $lassoSelection,
            lassoShape: NotyLassoShape(rawValue: lassoShapeValue) ?? .freehand,
            selectionFilter: NotySelectionFilter(handwriting: lassoIncludesInk, text: lassoIncludesText, photos: lassoIncludesPhotos),
            onActivate: { activate(page.id) },
            onContentChanged: { content, action in
                objectHistory.updateContent(store: store, undoManager: controller.undoManager, documentID: documentID, pageID: page.id, content: content, actionName: action) { drawing in controller.applyDrawing(drawing, pageID: page.id) }
            },
            onDrawingChanged: { store.saveDrawing($0, documentID: documentID, pageID: page.id) },
            onTextBoxesChanged: { objectHistory.updateTextBoxes(store: store, undoManager: controller.undoManager, documentID: documentID, pageID: page.id, textBoxes: $0) },
            onImagesChanged: { objectHistory.updateImages(store: store, undoManager: controller.undoManager, documentID: documentID, pageID: page.id, images: $0) })
    }

    private func activate(_ pageID: UUID) {
        guard selectedPageID != pageID else { return }
        canvasController.flush(); canvasController.cancelPreview()
        selectedTextBoxID = nil; editingTextBoxID = nil; selectedImageID = nil; lassoSelection = nil
        selectedPageID = pageID
    }
    private func navigate(to pageID: UUID) {
        activate(pageID)
        pageNavigationRequest = PageNavigationRequest(pageID: pageID)
    }

    private func setZoom(_ scale: CGFloat) {
        zoomScale = min(max(scale, 0.65), 3)
        zoomBaseScale = zoomScale
    }

    private func copyImage(_ image: NotyPageImage, page: NotyPage) {
        UIPasteboard.general.image = store.pageImage(documentID: documentID, pageID: page.id, image: image)
    }
    private func pasteObject() {
        guard let page = selectedPage else { return }
        canvasController.flush()
        do {
            if let payload = try NotySelectionClipboard.read() {
                let current = NotyPageContent(page: page, drawing: store.drawing(documentID: documentID, pageID: page.id))
                let result = try NotySelectionClipboard.inserting(payload, into: current, at: boardCenter.map { CGPoint(x: $0.x - 150, y: $0.y - 80) } ?? CGPoint(x: 32, y: 32), paper: page.canvasSize, store: store, documentID: documentID, pageID: page.id)
                objectHistory.updateContent(store: store, undoManager: canvasController.undoManager, documentID: documentID, pageID: page.id, content: result.content, actionName: "Paste selection") { drawing in canvasController.applyDrawing(drawing, pageID: page.id) }
                drawingTool = .lasso; isToolPickerVisible = false; selectedTextBoxID = nil; selectedImageID = nil; editingTextBoxID = nil
                lassoSelection = result.selection
                return
            }
        } catch { imageImportError = error.localizedDescription; return }
        if let image = UIPasteboard.general.image, let data = image.pngData() {
            do { selectedImageID = try objectHistory.addImage(store: store, undoManager: canvasController.undoManager, data: data, documentID: documentID, pageID: page.id).id; drawingTool = .hand }
            catch { imageImportError = error.localizedDescription }
        } else if let text = UIPasteboard.general.string {
            let box = NotyTextBox(text: text, x: Double(insertionOrigin.x), y: Double(insertionOrigin.y), width: min(300, page.canvasSize.width - 80), height: 160, fontSize: 20)
            objectHistory.updateTextBoxes(store: store, undoManager: canvasController.undoManager, documentID: documentID, pageID: page.id, textBoxes: page.textBoxes + [box])
            selectedTextBoxID = box.id; editingTextBoxID = box.id
        }
    }
    private func duplicateTextBox(_ box: NotyTextBox, page: NotyPage) {
        var copy = box; copy.id = UUID(); copy.x = min(copy.x + 20, page.canvasSize.width - copy.width); copy.y = min(copy.y + 20, page.canvasSize.height - copy.height)
        objectHistory.updateTextBoxes(store: store, undoManager: canvasController.undoManager, documentID: documentID, pageID: page.id, textBoxes: page.textBoxes + [copy])
        selectedTextBoxID = copy.id; editingTextBoxID = nil
    }

    private func selectInitialPage() {
        objectHistory.onChange = { canvasController.refreshUndoState() }
        store.ensureNotebookCover(documentID: documentID)
        if selectedPageID == nil {
            if horizontalSizeClass == .compact { isShowingThumbnails = false }
            if let pageID = document?.pages.first(where: { $0.id == initialPageID })?.id ?? document?.pages.first?.id { navigate(to: pageID) }
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
        canvasController.flush()
        navigate(to: document.pages[nextIndex].id)
        selectedTextBoxID = nil
        editingTextBoxID = nil
    }

    private func addPage(template: NotyPageTemplate, format: NotyPage? = nil) {
        canvasController.flush()
        if let page = store.addPage(documentID: documentID, after: selectedPage?.id, template: template, format: format) {
            navigate(to: page.id)
        }
        selectedTextBoxID = nil
        selectedImageID = nil
    }

    private func duplicatePage(_ page: NotyPage) {
        guard let copy = store.duplicatePage(documentID: documentID, pageID: page.id) else { return }
        navigate(to: copy.id)
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
            text: "",
            x: Double(insertionOrigin.x) + Double(index % 3) * 24,
            y: Double(insertionOrigin.y) + Double(index % 4) * 34,
            width: 260,
            height: 112,
            fontSize: 20
        )
        var boxes = page.textBoxes
        boxes.append(box)
        objectHistory.updateTextBoxes(store: store, undoManager: canvasController.undoManager, documentID: documentID, pageID: page.id, textBoxes: boxes)
        selectedTextBoxID = box.id
        editingTextBoxID = box.id
        selectedImageID = nil
        isToolPickerVisible = false
    }

    private func updateTextBoxes(_ page: NotyPage, removing id: UUID) {
        objectHistory.updateTextBoxes(store: store, undoManager: canvasController.undoManager, documentID: documentID, pageID: page.id, textBoxes: page.textBoxes.filter { $0.id != id })
        selectedTextBoxID = nil
        editingTextBoxID = nil
    }

    private func updateTextBox(_ page: NotyPage, boxID: UUID, mutation: (inout NotyTextBox) -> Void) {
        var boxes = page.textBoxes
        guard let index = boxes.firstIndex(where: { $0.id == boxID }) else { return }
        mutation(&boxes[index])
        objectHistory.updateTextBoxes(store: store, undoManager: canvasController.undoManager, documentID: documentID, pageID: page.id, textBoxes: boxes)
    }

    private func updatePageImage(_ page: NotyPage, imageID: UUID, mutation: (inout NotyPageImage) -> Void) {
        var images = page.images
        guard let index = images.firstIndex(where: { $0.id == imageID }) else { return }
        mutation(&images[index])
        objectHistory.updateImages(store: store, undoManager: canvasController.undoManager, documentID: documentID, pageID: page.id, images: images)
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
            x: Double(insertionOrigin.x),
            y: Double(insertionOrigin.y),
            width: max(120, min(540, Double(canvasSize.width) - 72)),
            height: max(80, min(420, min(Double(canvasSize.height) - 72, Double(lines) * 28 + 24))),
            fontSize: 18
        )
        objectHistory.updateTextBoxes(store: store, undoManager: canvasController.undoManager, documentID: documentID, pageID: page.id, textBoxes: page.textBoxes + [box])
        selectedTextBoxID = box.id
        editingTextBoxID = nil
    }

    private func exportPDF(selectedPageIDs: Set<UUID>? = nil) {
        canvasSessions.flushAll()
        do {
            shareURL = try NotyExportService.exportPDF(documentID: documentID, store: store, selectedPageIDs: selectedPageIDs)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportPageImage() {
        canvasController.flush()
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
                    store: store,
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
                    Image(uiImage: drawing.notyImage(from: CGRect(origin: .zero, size: canvasSize), scale: min(2, 4_096 / max(canvasSize.width, canvasSize.height))))
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
            .padding(.horizontal, 9 * box.contentInsetScale)
            .padding(.vertical, 8 * box.contentInsetScale)
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
    @Binding var lassoSelection: NotyPageSelection?
    let lassoShape: NotyLassoShape
    let selectionFilter: NotySelectionFilter
    let onActivate: () -> Void
    let onContentChanged: (NotyPageContent, String) -> Void
    let onDrawingChanged: (PKDrawing) -> Void
    let onTextBoxesChanged: ([NotyTextBox]) -> Void
    let onImagesChanged: ([NotyPageImage]) -> Void
    @State private var previewContent: NotyPageContent?

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = page.canvasSize
            let scale = proxy.size.width / canvasSize.width
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if store.documents.first(where: { $0.id == documentID })?.kind == .whiteboard {
                        WhiteboardPaperSurface(template: page.template, colorHex: page.paperColorHex)
                            .frame(width: canvasSize.width, height: canvasSize.height)
                    } else {
                    PageBackground(
                        documentID: documentID,
                        page: page,
                        store: store,
                        sourcePDF: sourcePDF,
                        imageSize: CGSize(width: canvasSize.width * 3, height: canvasSize.height * 3)
                    )
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    }

                    ForEach(previewContent?.images ?? page.images) { pageImage in
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
                        drawing: previewContent?.drawing ?? store.drawing(documentID: documentID, pageID: page.id),
                        pageID: page.id,
                        canvasSize: canvasSize,
                        controller: canvasController,
                        isInfinite: store.documents.first(where: { $0.id == documentID })?.kind == .whiteboard,
                        coordinateOrigin: page.canvasOffset,
                        inkSettings: inkSettings,
                        isToolPickerVisible: isToolPickerVisible,
                        onActivate: onActivate,
                        onDrawingChanged: onDrawingChanged
                    )
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .id(page.id)

                    if inkSettings.tool == .hand {
                        ForEach(page.images) { image in
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .frame(width: image.width, height: image.height)
                                .rotationEffect(.degrees(image.rotationDegrees))
                                .position(x: image.x + image.width / 2, y: image.y + image.height / 2)
                                .onTapGesture { onActivate(); selectedImageID = image.id; selectedTextBoxID = nil; editingTextBoxID = nil }
                                .accessibilityLabel("Select photo")
                        }
                    }
                    ForEach(previewContent?.textBoxes ?? page.textBoxes) { box in
                        EditableTextBox(
                            box: box,
                            scale: 1,
                            isSelected: selectedTextBoxID == box.id,
                            isEditing: editingTextBoxID == box.id,
                            onSelect: {
                                onActivate(); selectedTextBoxID = box.id
                                selectedImageID = nil
                                if editingTextBoxID != box.id { editingTextBoxID = nil }
                            },
                            onEdit: {
                                onActivate(); selectedTextBoxID = box.id; selectedImageID = nil; editingTextBoxID = box.id
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
                        .allowsHitTesting(inkSettings.tool == .hand || editingTextBoxID == box.id)
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
                                let maxWidth = min(canvasSize.width - CGFloat(updated[index].x), (canvasSize.height - CGFloat(updated[index].y)) * aspect)
                                let width = min(max(size.width, 30), maxWidth)
                                let height = width / aspect
                                updated[index].width = Double(width)
                                updated[index].height = Double(height)
                                onImagesChanged(updated)
                            }
                        )
                    }
                    if inkSettings.tool == .lasso {
                        PageLassoOverlay(paper: canvasSize, scale: scale, shape: lassoShape, filter: selectionFilter,
                                         store: store, documentID: documentID, pageID: page.id, selection: $lassoSelection,
                                         prepare: {
                            onActivate(); canvasController.flush()
                            let current = store.documents.first(where: { $0.id == documentID })?.pages.first(where: { $0.id == page.id }) ?? page
                            return NotyPageContent(page: current, drawing: store.drawing(documentID: documentID, pageID: page.id))
                        }, preview: { content in
                            previewContent = content
                            if let content { canvasController.previewDrawing(content.drawing) }
                            else { canvasController.cancelPreview() }
                        }, commit: onContentChanged)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .scaleEffect(scale, anchor: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background(EditorPalette.paper)
        }
        .aspectRatio(page.canvasSize.width / page.canvasSize.height, contentMode: .fit)
    }
}

private struct PencilCanvasView: UIViewRepresentable {
    let drawing: PKDrawing
    let pageID: UUID
    let canvasSize: CGSize
    let controller: InkCanvasController
    let isInfinite: Bool
    let coordinateOrigin: CGPoint
    let inkSettings: EditorInkSettings
    let isToolPickerVisible: Bool
    let onActivate: () -> Void
    let onDrawingChanged: (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onActivate: onActivate, onDrawingChanged: onDrawingChanged)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView(frame: .zero)
        canvas.overrideUserInterfaceStyle = .light
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = inkSettings.fingerDrawing ? .anyInput : .pencilOnly
        canvas.isUserInteractionEnabled = inkSettings.tool != .hand && inkSettings.tool != .lasso
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.contentSize = canvasSize
        canvas.tool = inkSettings.makeTool
        canvas.delegate = context.coordinator
        context.coordinator.inkSettings = inkSettings
        let shapeHold = context.coordinator.shapeHold
        shapeHold.allowedTouchTypes = inkSettings.fingerDrawing ? [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)] : [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        shapeHold.isEnabled = inkSettings.shapeCorrectionEnabled && inkSettings.tool == .ink
        shapeHold.onBegin = { [weak coordinator = context.coordinator, weak canvas] in
            coordinator?.strokeOriginal = canvas?.drawing
        }
        shapeHold.onRecognize = { [weak coordinator = context.coordinator, weak canvas] shape in
            guard let coordinator, let canvas, let original = coordinator.strokeOriginal,
                  let tool = canvas.tool as? PKInkingTool, !canvas.isRulerActive else { return }
            coordinator.pendingSave?.cancel(); coordinator.pendingSave = nil
            coordinator.isApplyingExternalDrawing = true
            coordinator.controller?.completeHeldShape(shape, original: original, tool: tool)
            coordinator.isApplyingExternalDrawing = false
        }
        canvas.addGestureRecognizer(shapeHold)
        context.coordinator.toolPicker.addObserver(canvas)
        context.coordinator.toolPicker.setVisible(isToolPickerVisible, forFirstResponder: canvas)
        context.coordinator.controller = controller
        controller.isInfinite = isInfinite; controller.coordinateOrigin = coordinateOrigin
        controller.attach(canvas, pageID: pageID, onDrawingChanged: onDrawingChanged)
        controller.applyExternalDrawing = { [weak coordinator = context.coordinator, weak canvas] drawing in
            guard let coordinator, let canvas else { return }
            coordinator.pendingSave?.cancel(); coordinator.pendingSave = nil
            coordinator.isApplyingExternalDrawing = true
            canvas.undoManager?.disableUndoRegistration()
            canvas.drawing = drawing
            canvas.undoManager?.enableUndoRegistration()
            coordinator.isApplyingExternalDrawing = false
        }
        controller.flushPendingSave = { [weak coordinator = context.coordinator, weak canvas] in
            guard let coordinator, let canvas else { return }
            coordinator.pendingSave?.cancel(); coordinator.pendingSave = nil
            coordinator.onDrawingChanged(coordinator.controller?.drawingForPersistence ?? canvas.drawing)
        }
        canvas.becomeFirstResponder()
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.contentSize = canvasSize
        canvas.drawingPolicy = inkSettings.fingerDrawing ? .anyInput : .pencilOnly
        canvas.isUserInteractionEnabled = inkSettings.tool != .hand && inkSettings.tool != .lasso
        context.coordinator.onActivate = onActivate
        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.controller = controller
        controller.isInfinite = isInfinite; controller.coordinateOrigin = coordinateOrigin
        controller.attach(canvas, pageID: pageID, onDrawingChanged: onDrawingChanged)
        context.coordinator.shapeHold.isEnabled = inkSettings.shapeCorrectionEnabled && inkSettings.tool == .ink && !canvas.isRulerActive
        context.coordinator.shapeHold.allowedTouchTypes = inkSettings.fingerDrawing ? [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)] : [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        context.coordinator.toolPicker.setVisible(isToolPickerVisible, forFirstResponder: canvas)
        if context.coordinator.inkSettings != inkSettings {
            canvas.tool = inkSettings.makeTool
            context.coordinator.inkSettings = inkSettings
        }
        guard !controller.isPreviewing else { return }
        let currentData = canvas.drawing.dataRepresentation()
        let newData = drawing.dataRepresentation()
        if context.coordinator.pendingSave == nil && currentData != newData {
            context.coordinator.isApplyingExternalDrawing = true
            canvas.drawing = drawing
            context.coordinator.isApplyingExternalDrawing = false
        }
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.pendingSave?.cancel()
        coordinator.shapeHold.isEnabled = false
        canvas.removeGestureRecognizer(coordinator.shapeHold)
        coordinator.onDrawingChanged(coordinator.controller?.drawingForPersistence ?? canvas.drawing)
        coordinator.toolPicker.removeObserver(canvas)
        coordinator.toolPicker.setVisible(false, forFirstResponder: canvas)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onDrawingChanged: (PKDrawing) -> Void
        let toolPicker = PKToolPicker()
        let shapeHold = NotyShapeHoldGestureRecognizer()
        var strokeOriginal: PKDrawing?
        weak var controller: InkCanvasController?
        var inkSettings: EditorInkSettings?
        var pendingSave: Task<Void, Never>?
        var isApplyingExternalDrawing = false

        var onActivate: () -> Void
        init(onActivate: @escaping () -> Void, onDrawingChanged: @escaping (PKDrawing) -> Void) {
            self.onActivate = onActivate; self.onDrawingChanged = onDrawingChanged
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { onActivate(); controller?.beginStroke() }


        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingExternalDrawing, controller?.isPreviewing != true else { return }
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
            guard !isApplyingExternalDrawing else { return }
            pendingSave?.cancel()
            pendingSave = nil
            controller?.endStroke()
            onDrawingChanged(controller?.drawingForPersistence ?? canvasView.drawing)
            controller?.refreshUndoState()
        }
    }
}

private struct PageNavigationRequest: Equatable {
    let pageID: UUID
    private let nonce = UUID()
}

@MainActor
private final class NotebookCanvasSessions: ObservableObject {
    private var controllers: [UUID: InkCanvasController] = [:]
    private var observers: [UUID: AnyCancellable] = [:]
    private let fallback = InkCanvasController()
    func controller(for pageID: UUID?) -> InkCanvasController {
        guard let pageID else { return fallback }
        if let controller = controllers[pageID] { return controller }
        let controller = InkCanvasController()
        controllers[pageID] = controller
        observers[pageID] = controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return controller
    }
    func flushAll() { controllers.values.forEach { $0.flush() } }
}

@MainActor
private final class InkCanvasController: ObservableObject {
    @Published private(set) var undoState = 0
    @Published private(set) var undoRevision = 0
    weak var canvasView: PKCanvasView?
    var onDrawingChanged: ((PKDrawing) -> Void)?
    private weak var observedUndoManager: UndoManager?
    private var undoObservers: [NSObjectProtocol] = []
    var flushPendingSave: (() -> Void)?
    var applyExternalDrawing: ((PKDrawing) -> Void)?
    private var previewOriginal: PKDrawing?
    private var pageID: UUID?
    private var rulerIsVisible = false
    var isInfinite = false
    var coordinateOrigin = CGPoint.zero
    private let boardUndoManager = UndoManager()
    private var strokeBeforeDrawing: PKDrawing?
    var isPreviewing: Bool { previewOriginal != nil }
    var drawingForPersistence: PKDrawing? { previewOriginal ?? canvasView?.drawing }
    func flush() { flushPendingSave?() }

    func previewDrawing(_ drawing: PKDrawing) {
        if previewOriginal == nil { flush(); previewOriginal = canvasView?.drawing }
        applyExternalDrawing?(drawing)
    }
    func cancelPreview() {
        guard let original = previewOriginal else { return }
        applyExternalDrawing?(original)
        previewOriginal = nil
    }
    func applyDrawing(_ drawing: PKDrawing, pageID: UUID) {
        guard self.pageID == pageID else { return }
        cancelPreview()
        applyExternalDrawing?(drawing)
        refreshUndoState()
    }

    var undoManager: UndoManager? { isInfinite ? boardUndoManager : canvasView?.undoManager }

    var canUndo: Bool {
        _ = undoState
        return undoManager?.canUndo == true
    }
    var canRedo: Bool {
        _ = undoState
        return undoManager?.canRedo == true
    }
    var isRulerActive: Bool { canvasView?.isRulerActive == true }

    func attach(_ canvas: PKCanvasView, pageID: UUID, onDrawingChanged: @escaping (PKDrawing) -> Void) {
        if canvasView !== canvas { cancelPreview() }
        canvasView = canvas
        canvas.isRulerActive = rulerIsVisible
        self.pageID = pageID
        self.onDrawingChanged = onDrawingChanged
        if let manager = undoManager, observedUndoManager !== manager {
            undoObservers.forEach(NotificationCenter.default.removeObserver)
            observedUndoManager = manager
            undoObservers = [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map { name in
                NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        await Task.yield()
                        if name == .NSUndoManagerDidUndoChange || name == .NSUndoManagerDidRedoChange { self?.undoRevision &+= 1 }
                        self?.refreshUndoState()
                    }
                }
            }
        }
    }

    deinit { undoObservers.forEach(NotificationCenter.default.removeObserver) }

    func undo() {
        cancelPreview()
        undoManager?.undo()
        refreshUndoState()
    }

    func redo() {
        cancelPreview()
        undoManager?.redo()
        refreshUndoState()
    }

    func toggleRuler() {
        guard let canvasView else { return }
        rulerIsVisible.toggle()
        canvasView.isRulerActive = rulerIsVisible
        refreshUndoState()
    }

    func completeHeldShape(_ shape: NotyRecognizedShape, original: PKDrawing, tool: PKInkingTool) {
        guard let canvas = canvasView else { return }
        canvas.undoManager?.disableUndoRegistration()
        canvas.drawingGestureRecognizer.isEnabled = false
        canvas.drawing = PKDrawing(strokes: original.strokes + [shape.stroke(ink: PKInk(tool.inkType, color: tool.color), width: tool.width)])
        canvas.drawingGestureRecognizer.isEnabled = true
        canvas.undoManager?.enableUndoRegistration()
        strokeBeforeDrawing = nil
        registerDrawingUndo(on: canvas, restoring: original)
        undoManager?.setActionName("Perfect shape")
        onDrawingChanged?(canvas.drawing)
        refreshUndoState()
    }

    func translateCoordinateOrigin(by transform: CGAffineTransform) {
        coordinateOrigin.x += transform.tx; coordinateOrigin.y += transform.ty
    }
    func beginStroke() { if isInfinite { strokeBeforeDrawing = canvasView?.drawing } }
    func endStroke() {
        guard isInfinite, let original = strokeBeforeDrawing, let canvas = canvasView else { return }
        strokeBeforeDrawing = nil
        if original.dataRepresentation() != canvas.drawing.dataRepresentation() {
            registerDrawingUndo(on: canvas, restoring: original)
            undoManager?.setActionName("Ink")
        }
        canvas.undoManager?.removeAllActions()
    }

    func insertShape(_ shape: EditorShape, color: UIColor, width: Double, canvasSize: CGSize, center: CGPoint? = nil) {
        guard let canvas = canvasView else { return }
        let size = center == nil ? canvasSize : CGSize(width: 612, height: 792)
        let points = shape.controlPoints(in: size).map { point in
            guard let center else { return point }
            return CGPoint(x: point.x + center.x - size.width / 2, y: point.y + center.y - size.height / 2)
        }
        let kind: NotyRecognizedShape.Kind = switch shape {
        case .line: .line
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        }
        let stroke = NotyRecognizedShape(kind: kind, points: points)
            .stroke(ink: PKInk(.pen, color: color), width: width)
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
        let origin = isInfinite ? coordinateOrigin : .zero
        let worldDrawing = drawing.transformed(using: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        undoManager?.registerUndo(withTarget: canvas) { [weak self] target in
            guard let self else { return }
            self.registerDrawingUndo(on: target, restoring: target.drawing)
            let currentOrigin = self.isInfinite ? self.coordinateOrigin : .zero
            target.drawing = worldDrawing.transformed(using: CGAffineTransform(translationX: currentOrigin.x, y: currentOrigin.y))
            self.onDrawingChanged?(target.drawing)
            self.refreshUndoState()
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
    var tool: EditorDrawingTool = .ink
    var fingerDrawing = false
    var eraserWidth: CGFloat = 20
    var eraseWholeStrokes = false
    var shapeCorrectionEnabled = true

    static func == (lhs: EditorInkSettings, rhs: EditorInkSettings) -> Bool {
        lhs.type == rhs.type && lhs.color.isEqual(rhs.color) && lhs.width == rhs.width && lhs.tool == rhs.tool && lhs.fingerDrawing == rhs.fingerDrawing && lhs.eraserWidth == rhs.eraserWidth && lhs.eraseWholeStrokes == rhs.eraseWholeStrokes && lhs.shapeCorrectionEnabled == rhs.shapeCorrectionEnabled
    }

    var makeTool: any PKTool {
        switch tool {
        case .ink, .hand: PKInkingTool(type.inkType, color: color, width: width)
        case .eraser: eraseWholeStrokes ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: eraserWidth)
        case .lasso: PKLassoTool()
        }
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
    let store: NotyStore
    let sourcePDF: PDFDocument?
    let imageSize: CGSize

    var body: some View {
        ZStack {
            Color(hex: page.paperColorHex)
            if page.isCover, let document = store.documents.first(where: { $0.id == documentID }) {
                NotebookCoverView(title: document.title, cover: document.displayCover, image: store.coverImage(for: document), pageSize: page.canvasSize)
            } else if let sourcePageIndex = page.sourcePageIndex, let sourcePDF {
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
            let factor = min(1, 4_096 / max(imageSize.width, imageSize.height))
            snapshot = sourcePage.thumbnail(of: CGSize(width: imageSize.width * factor, height: imageSize.height * factor), for: .mediaBox)
        }
        .accessibilityHidden(true)
    }
}

private struct PageTemplateView: View {
    let template: NotyPageTemplate
    let paperColorHex: String
    var body: some View { PaperTemplateSurface(template: template, paperColorHex: paperColorHex) }
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

struct PageTextEditor: UIViewRepresentable {
    @Binding var text: String
    let box: NotyTextBox
    let scale: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeUIView(context: Context) -> UITextView {
        let view = FocusingTextView()
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        view.textContainerInset = UIEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
        view.textContainer.lineFragmentPadding = 0
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        let size = max(1, box.fontSize * Double(scale))
        let inset = box.contentInsetScale * Double(scale)
        view.textContainerInset = UIEdgeInsets(top: 8 * inset, left: 9 * inset, bottom: 8 * inset, right: 9 * inset)
        var descriptor = box.fontName.map { UIFontDescriptor().withFamily($0) } ?? UIFont.systemFont(ofSize: size).fontDescriptor
        var traits = descriptor.symbolicTraits
        if box.isBold { traits.insert(.traitBold) }
        if box.isItalic { traits.insert(.traitItalic) }
        descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
        let font = UIFont(descriptor: descriptor, size: size)
        let color = UIColor(notyHex: box.colorHex)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = box.alignment == .leading ? .left : box.alignment == .center ? .center : .right
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph, .underlineStyle: box.isUnderlined ? NSUnderlineStyle.single.rawValue : 0]
        let old = context.coordinator.style
        let styleChanged = old?.fontName != box.fontName || old?.fontSize != box.fontSize || old?.isBold != box.isBold || old?.isItalic != box.isItalic || old?.isUnderlined != box.isUnderlined || old?.colorHex != box.colorHex || old?.alignment != box.alignment || context.coordinator.scale != scale
        if view.markedTextRange == nil && (view.text != text || styleChanged) {
            let selection = view.selectedRange
            view.attributedText = NSAttributedString(string: text, attributes: attributes)
            let length = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location)))
            context.coordinator.style = box
            context.coordinator.scale = scale
        }
        if styleChanged { view.typingAttributes = attributes }
    }
    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        view.resignFirstResponder(); view.delegate = nil
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var style: NotyTextBox?
        var scale: CGFloat?
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ textView: UITextView) { text.wrappedValue = textView.text }
    }
    private final class FocusingTextView: UITextView {
        private var needsInitialFocus = true
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, needsInitialFocus {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window != nil, self.needsInitialFocus else { return }
                    self.needsInitialFocus = !self.becomeFirstResponder()
                }
            }
        }
    }
}

private struct EditableTextBox: View {
    let box: NotyTextBox
    let scale: CGFloat
    let isSelected: Bool
    let isEditing: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onTextChanged: (String) -> Void
    let onMove: (CGPoint) -> Void
    let onResize: (CGSize) -> Void

    @State private var text = ""
    @State private var dragOffset = CGSize.zero
    @State private var dragOrigin = CGPoint.zero
    @State private var resizeOrigin: CGSize?
    @State private var isResizing = false

    private var styledFont: Font {
        let size = max(1, CGFloat(box.fontSize) * scale)
        var font = box.fontName.map { Font.custom($0, size: size) } ?? Font.system(size: size)
        if box.isBold { font = font.weight(.bold) }
        if box.isItalic { font = font.italic() }
        return font
    }

    var body: some View {
        Group {
            if isEditing {
                PageTextEditor(text: $text, box: box, scale: scale)
                    .onChange(of: text) { _, newValue in onTextChanged(newValue) }
            } else {
                Text(box.text.isEmpty ? " " : box.text)
                    .font(styledFont)
                    .underline(box.isUnderlined)
                    .foregroundStyle(Color(hex: box.colorHex))
                    .multilineTextAlignment(box.alignment.textAlignment)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: box.alignment.frameAlignment)
                    .padding(.horizontal, 9 * scale * box.contentInsetScale)
                    .padding(.vertical, 8 * scale * box.contentInsetScale)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onEdit)
                    .onTapGesture(perform: onSelect)
            }
        }
        .background {
            if isSelected || isEditing {
                RoundedRectangle(cornerRadius: 6 * scale)
                    .fill(EditorPalette.accent.opacity(0.035))
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
        .onChange(of: box.text) { _, newText in
            if text != newText { text = newText }
        }
        .onAppear {
            text = box.text
        }
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(box.text.isEmpty ? "Text box" : box.text)
        .accessibilityHint(isEditing ? "Edit text" : "Drag to move. Double-tap to edit.")
        .accessibilityAction(named: "Edit text", onEdit)
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

struct PageThumbnail: View {
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
                    PageBackground(documentID: documentID, page: page, store: store, sourcePDF: sourcePDF, imageSize: CGSize(width: 360, height: 466))
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
                        Image(uiImage: drawing.notyImage(from: CGRect(origin: .zero, size: page.canvasSize), scale: min(0.35, 512 / max(page.canvasSize.width, page.canvasSize.height))))
                            .resizable()
                            .scaledToFill()
                    }
                    GeometryReader { proxy in
                        let scale = proxy.size.width / page.canvasSize.width
                        ZStack(alignment: .topLeading) {
                            ForEach(page.textBoxes) { PresentedTextBox(box: $0) }
                        }
                        .frame(width: page.canvasSize.width, height: page.canvasSize.height)
                        .scaleEffect(scale, anchor: .topLeading)
                    }.allowsHitTesting(false)
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
                .shadow(color: Color.black.opacity(0.025), radius: 1, x: 0, y: 1)
                Text("Page \(number)")
                    .font(isSelected ? NotionTheme.font(11, weight: .medium) : NotionTheme.captionSmall)
                    .foregroundStyle(isSelected ? EditorPalette.ink : EditorPalette.secondaryInk)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(page.isCover ? "Notebook cover, page \(number)" : "Page \(number)")
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
            .frame(minWidth: 44, minHeight: 44)
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
        case .note, .book: "Notebook"
        case .pdf: "PDF document"
        case .whiteboard: "Whiteboard"
        }
    }

    var editorSymbolName: String {
        switch self {
        case .note, .book: "book.closed"
        case .pdf: "doc.richtext"
        case .whiteboard: "rectangle.and.pencil.and.ellipsis"
        }
    }
}

private extension NotyPageTemplate {
    var editorLabel: String { title }
    var symbolName: String { icon }
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

private enum EditorDrawingTool { case ink, eraser, lasso, hand }
private enum EditorToolSettings { case pen, highlighter, eraser, lasso, text, photo, hand }

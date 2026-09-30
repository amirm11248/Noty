import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

struct LibraryView: View {
    var store: NotyStore
    var oneDrive: OneDriveService

    @Environment(\.scenePhase) private var scenePhase
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selection: LibrarySelection = .all
    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var editorPath: [UUID] = []
    @State private var searchText = ""
    @State private var activeSheet: LibrarySheetRequest?
    @State private var deleteTarget: DeleteTarget?
    @State private var isImporting = false
    @State private var isImportingPhotos = false
    @State private var importPhotoItems: [PhotosPickerItem] = []
    @State private var isScanningDocument = false
    @State private var syncDebounce: Task<Void, Never>?
    @State private var syncDebounceID: UUID?
    @State private var backgroundSyncTask: LibraryBackgroundTask?
    @State private var alertMessage: String?
    @State private var searchResults: [NotySearchResult] = []
    @State private var account = NotyAccountService()
    @AppStorage("noty.library.favoriteDocumentIDs") private var favoriteIDsValue = ""
    @AppStorage("noty.library.recentDocumentIDs") private var recentIDsValue = ""
    @AppStorage("noty.library.sortOrder") private var sortOrderValue = LibrarySortOrder.edited.rawValue

    private var selectedFolderID: UUID? {
        guard case .folder(let id) = selection else { return nil }
        return id
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationTitle("")
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $activeSheet) { request in
            sheet(for: request.destination)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [
                .pdf,
                .image,
                UTType("com.microsoft.word.doc") ?? .data,
                UTType("org.openxmlformats.wordprocessingml.document") ?? .data
            ],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
        .photosPicker(
            isPresented: $isImportingPhotos,
            selection: $importPhotoItems,
            maxSelectionCount: 50,
            matching: .images
        )
        .onChange(of: importPhotoItems.count) { _, count in
            guard count > 0 else { return }
            importSelectedPhotos()
        }
        .sheet(isPresented: $isScanningDocument) {
            DocumentScannerSheet(
                onScan: { images in
                    isScanningDocument = false
                    importImagesAsNotebook(images, title: "Scanned Document", openWhenDone: true)
                },
                onCancel: {
                    isScanningDocument = false
                },
                onFailure: { error in
                    isScanningDocument = false
                    alertMessage = error.localizedDescription
                }
            )
            .ignoresSafeArea()
        }
        .confirmationDialog(
            deletePrompt,
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: performDelete)
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteMessage)
        }
        .alert(
            "Library",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .onChange(of: documentRevisionSignature) { _, _ in
            refreshSearchResults()
            scheduleOneDriveSync()
            scheduleBackgroundCloudRetry()
        }
        .onChange(of: folderRevisionSignature) { _, _ in
            refreshSearchResults()
            scheduleBackgroundCloudRetry()
        }
        .onChange(of: searchText) { _, _ in
            refreshSearchResults()
        }
        .onChange(of: editorPath) { _, path in
            withAnimation(.easeInOut(duration: 0.2)) {
                columnVisibility = path.isEmpty ? .all : .detailOnly
            }
            if path.isEmpty, oneDrive.isConnected {
                Task { await oneDrive.syncAllPDFs(store: store) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                refreshSearchResults()
                Task { await account.bootstrap(force: true) }
                Task { await syncCloudMirrors() }
            case .background:
                flushCloudMirrorsBeforeSuspension()
            default:
                break
            }
        }
        .task {
            refreshSearchResults()
            await account.bootstrap()
            await syncCloudMirrors()
            scheduleBackgroundCloudRetry()
        }
        .onDisappear {
            guard syncDebounceID != nil else { return }
            syncDebounce?.cancel()
            syncDebounce = nil
            syncDebounceID = nil
            if oneDrive.isConnected {
                Task { await oneDrive.syncAllPDFs(store: store) }
            }
        }
    }

    private var sidebar: some View {
        List {
            Section {
                Button {
                    selection = .all
                } label: {
                    sidebarDestination("Library", symbol: "house", count: store.documents.count)
                }
                .buttonStyle(.plain)
                .notionSidebarRow(isSelected: selection == .all)

                Button { selection = .recents } label: {
                    sidebarDestination("Recents", symbol: "clock", count: recentDocuments.count)
                }
                .buttonStyle(.plain)
                .notionSidebarRow(isSelected: selection == .recents)

                Button { selection = .favorites } label: {
                    sidebarDestination("Favorites", symbol: "star", count: favoriteDocuments.count)
                }
                .buttonStyle(.plain)
                .notionSidebarRow(isSelected: selection == .favorites)
            }

            Section {
                if store.folders.isEmpty {
                    Text("No folders yet")
                        .font(NotionTheme.bodySmall)
                        .foregroundStyle(NotionTheme.inkTertiary)
                        .padding(.leading, 4)
                } else {
                    ForEach(folderOutline, id: \.folder.id) { row in
                        VStack(spacing: 0) {
                            folderSidebarRow(row)

                            if expandedFolderIDs.contains(row.folder.id) {
                                ForEach(sidebarDocuments(in: row.folder.id)) { document in
                                    sidebarDocumentRow(document, depth: row.depth + 1)
                                }
                            }
                        }
                    }
                }
            } header: {
                NotionSectionLabel(text: "Folders")
            }

            Section {
                Button {
                    selection = .trash
                    searchText = ""
                } label: {
                    sidebarDestination("Trash", symbol: "trash", count: store.trashItems.count)
                }
                .buttonStyle(.plain)
                .notionSidebarRow(isSelected: selection == .trash)

                Button { present(.settings) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13))
                            .foregroundStyle(NotionTheme.inkSecondary)
                            .frame(width: 18)
                        Text("Settings")
                            .font(NotionTheme.body)
                            .foregroundStyle(NotionTheme.ink)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: NotionTheme.sidebarRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .notionSidebarRow()
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(NotionTheme.sidebar)
        .foregroundStyle(NotionTheme.ink)
        .tint(NotionTheme.accent)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(NotionTheme.ink)
                        Text("N")
                            .font(NotionTheme.font(11, weight: .bold))
                            .foregroundStyle(NotionTheme.canvas)
                    }
                    .frame(width: 22, height: 22)

                    Text("Noty")
                        .font(NotionTheme.font(14, weight: .semibold))
                        .foregroundStyle(NotionTheme.ink)

                    Spacer(minLength: 6)

                    if store.iCloudMirrorFolderURL != nil {
                        Button {
                            Task { await store.syncICloudMirror() }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(NotionIconButtonStyle())
                        .accessibilityLabel("Sync now")
                    }
                }

                NotionSearchField(text: $searchText, placeholder: "Search")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(NotionTheme.sidebar)
        }
    }

    private var detail: some View {
        NavigationStack(path: $editorPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader
                        .padding(.bottom, 28)

                    if selection == .trash {
                        if visibleTrashItems.isEmpty {
                            emptyState
                        } else {
                            trashList
                        }
                    } else {
                        if store.lastPersistenceError?.isEmpty == false {
                            persistenceWarning(store.lastPersistenceError ?? "")
                                .padding(.bottom, 14)
                        }

                        if store.iCloudMirrorFolderURL == nil {
                            iCloudBackupStatus
                                .padding(.bottom, 18)
                        } else {
                            iCloudBackupStatus
                                .padding(.bottom, 12)
                        }
                        if oneDrive.isConnected || oneDrive.lastError != nil {
                            oneDriveBackupStatus
                                .padding(.bottom, 12)
                        }

                        if !visibleFolders.isEmpty {
                            folderList
                                .padding(.bottom, 28)
                        }
                        if !visibleDocuments.isEmpty {
                            documentList
                        }
                        if visibleFolders.isEmpty && visibleDocuments.isEmpty {
                            emptyState
                        }
                    }
                }
                .padding(.horizontal, 56)
                .padding(.top, 34)
                .padding(.bottom, 52)
                .frame(maxWidth: NotionTheme.pageMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(NotionTheme.canvas)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(NotionTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if selection == .trash {
                        if !store.trashItems.isEmpty {
                            Button(role: .destructive) {
                                deleteTarget = .emptyTrash
                            } label: {
                                Label("Empty Trash", systemImage: "trash.slash")
                                    .font(NotionTheme.control)
                            }
                        }
                    } else {
                        Menu {
                            Button("New notebook", systemImage: "book.closed") {
                                createNotebook()
                            }
                            Button("New folder", systemImage: "folder.badge.plus") {
                                present(.name(.newFolder(parentID: selectedFolderID)))
                            }

                            Divider()

                            Button("Import from Files", systemImage: "folder") {
                                isImporting = true
                            }
                            Button("Import Photos", systemImage: "photo.on.rectangle.angled") {
                                isImportingPhotos = true
                            }
                            Button("Scan Document", systemImage: "doc.viewfinder") {
                                isScanningDocument = true
                            }
                            .disabled(!VNDocumentCameraViewController.isSupported)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("New")
                                    .font(NotionTheme.control)
                            }
                            .foregroundStyle(NotionTheme.ink)
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .background(NotionTheme.rowHover, in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium))
                        }
                        .accessibilityLabel("New item")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { documentID in
                DocumentEditorView(documentID: documentID, store: store)
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !(selection == .all && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                HStack(spacing: 5) {
                    Button("Library") {
                        selection = .all
                        searchText = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NotionTheme.inkTertiary)

                    ForEach(ancestorFolders) { folder in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(NotionTheme.inkTertiary)
                        Button(folder.name) {
                            selection = .folder(folder.id)
                            searchText = ""
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(NotionTheme.inkTertiary)
                    }

                    if !ancestorFolders.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(NotionTheme.inkTertiary)
                    }
                }
                .font(NotionTheme.caption)
                .lineLimit(1)
                .padding(.bottom, 4)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(currentTitle)
                    .font(NotionTheme.pageTitle)
                    .tracking(-0.75)
                    .foregroundStyle(NotionTheme.ink)
                Spacer(minLength: 8)
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("\(visibleDocuments.count) results")
                        .font(NotionTheme.caption)
                        .foregroundStyle(NotionTheme.inkTertiary)
                } else {
                    sortMenu
                }
            }

            Text(folderDescription)
                .font(NotionTheme.bodySmall)
                .foregroundStyle(NotionTheme.inkSecondary)
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySortOrder.allCases) { order in
                Button {
                    sortOrderValue = order.rawValue
                } label: {
                    if sortOrder == order {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                Text(sortOrder.title)
            }
            .font(NotionTheme.font(12, weight: .medium))
            .foregroundStyle(NotionTheme.inkSecondary)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(emptyTitle)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(NotionTheme.ink)
            Text(emptyDescription)
                .font(.system(size: 13))
                .foregroundStyle(NotionTheme.inkSecondary)
            if searchText.isEmpty && selection == .all {
                Text("Use New in the top-right to create a notebook, folder, or import content.")
                    .font(NotionTheme.caption)
                    .foregroundStyle(NotionTheme.inkTertiary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 28)
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return "No results" }
        if selection == .favorites { return "No favorites yet" }
        if selection == .recents { return "No recent pages" }
        if selection == .trash { return "Trash is empty" }
        return "Nothing here yet"
    }

    private var emptyDescription: String {
        if !searchText.isEmpty { return "Try another title, folder, notebook, or document text." }
        if selection == .favorites { return "Favorite pages will appear here." }
        if selection == .recents { return "Pages you open will appear here." }
        if selection == .trash { return "Deleted documents stay here until you restore or permanently delete them." }
        return "Create a notebook or import a PDF, Word file, photo, or scan."
    }

    private var iCloudBackupStatus: some View {
        Group {
            if store.iCloudMirrorFolderURL == nil {
                Button {
                    present(.settings)
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: isICloudSyncError ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                            .font(.system(size: 14))
                            .foregroundStyle(isICloudSyncError ? NotionTheme.danger : NotionTheme.inkSecondary)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                isICloudSyncError
                                    ? "Restore folder sync access"
                                    : (account.sharedFolderURL == nil ? "Sync your library with a folder" : "Account workspace found")
                            )
                                .font(NotionTheme.font(13, weight: .medium))
                                .foregroundStyle(NotionTheme.ink)
                            Text(
                                isICloudSyncError
                                    ? displayICloudMirrorStatus(store.syncStatus)
                                    : (account.sharedFolderURL == nil
                                        ? "Choose the same iCloud Drive folder on each device. Sign in to remember its setup across devices."
                                        : "Your Noty account has a saved iCloud workspace link. Open Settings to connect this device.")
                            )
                                .font(NotionTheme.caption)
                                .foregroundStyle(isICloudSyncError ? NotionTheme.danger : NotionTheme.inkSecondary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NotionTheme.inkTertiary)
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: iCloudStatusSymbol)
                        .font(.system(size: 14))
                        .foregroundStyle(isICloudSyncError ? NotionTheme.danger : NotionTheme.inkSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync folder · \(store.iCloudMirrorFolderURL?.lastPathComponent ?? "Files folder")")
                            .font(NotionTheme.font(13, weight: .medium))
                            .foregroundStyle(NotionTheme.ink)
                        Text(displayICloudMirrorStatus(store.syncStatus))
                            .font(NotionTheme.caption)
                            .foregroundStyle(isICloudSyncError ? NotionTheme.danger : NotionTheme.inkSecondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 4)
                    Button {
                        Task { await store.syncICloudMirror() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(NotionIconButtonStyle())
                    .accessibilityLabel("Sync folder now")
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(NotionTheme.hairline).frame(height: 1)
        }
    }

    private var isICloudSyncError: Bool {
        let status = store.syncStatus.lowercased()
        return ["error", "failed", "could not", "unavailable", "not available", "expired", "needs to be renewed"]
            .contains(where: { status.contains($0) })
    }

    private var iCloudStatusSymbol: String {
        if isICloudSyncError { return "exclamationmark.triangle" }
        let status = store.syncStatus.lowercased()
        if ["checking", "next", "selected", "ready"].contains(where: { status.contains($0) }) {
            return "arrow.up.circle"
        }
        return "checkmark.circle"
    }

    private var oneDriveBackupStatus: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: oneDrive.lastError == nil ? "externaldrive" : "exclamationmark.icloud")
                .font(.system(size: 14))
                .foregroundStyle(oneDrive.lastError == nil ? NotionTheme.inkSecondary : NotionTheme.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(oneDrive.mirrorFolderName.map { "Selected Files folder · \($0)" } ?? "OneDrive folder needs attention")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NotionTheme.ink)
                Text(oneDrive.lastError ?? oneDrive.syncStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(oneDrive.lastError == nil ? NotionTheme.inkSecondary : NotionTheme.danger)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(NotionTheme.hairline).frame(height: 1)
        }
    }

    private func persistenceWarning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(NotionTheme.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text("Noty could not save a local change")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NotionTheme.ink)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(NotionTheme.danger)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NotionTheme.danger.opacity(0.05))
    }

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 4) {
            NotionSectionLabel(text: "Folders")
                .padding(.bottom, 3)

            ForEach(visibleFolders) { folder in
                Button {
                    selection = .folder(folder.id)
                    searchText = ""
                    expandAncestors(of: folder.id)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(NotionTheme.inkSecondary)
                            .frame(width: 22)

                        Text(folder.name)
                            .font(NotionTheme.font(14, weight: .medium))
                            .foregroundStyle(NotionTheme.ink)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text("\(folderItemCount(folder.id))")
                            .font(NotionTheme.caption)
                            .foregroundStyle(NotionTheme.inkTertiary)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(NotionTheme.inkTertiary)
                    }
                    .padding(.horizontal, 7)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NotionRowButtonStyle())
                .contextMenu {
                    Button("Rename", systemImage: "pencil") {
                        present(.name(.renameFolder(folder.id)))
                    }
                    Button("New subfolder", systemImage: "folder.badge.plus") {
                        present(.name(.newFolder(parentID: folder.id)))
                    }
                    Button("Delete folder", systemImage: "trash", role: .destructive) {
                        deleteTarget = .folder(folder.id)
                    }
                }
            }
        }
    }

    private var documentList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                NotionSectionLabel(text: "Documents")
                Spacer()
                Text("\(visibleDocuments.count)")
                    .font(NotionTheme.caption)
                    .foregroundStyle(NotionTheme.inkTertiary)
            }
            .padding(.bottom, 3)

            ForEach(visibleDocuments) { document in
                HStack(spacing: 4) {
                    NavigationLink(value: document.id) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(NotionTheme.rowHover)
                                Image(systemName: documentSymbol(document.kind))
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(NotionTheme.inkSecondary)
                            }
                            .frame(width: 30, height: 30)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title)
                                    .font(NotionTheme.font(14, weight: .medium))
                                    .foregroundStyle(NotionTheme.ink)
                                    .lineLimit(1)

                                if let caption = searchCaption(for: document) {
                                    Text(caption)
                                        .font(NotionTheme.caption)
                                        .foregroundStyle(NotionTheme.inkTertiary)
                                        .lineLimit(1)
                                } else {
                                    Text("\(documentKindLabel(document.kind)) · \(document.pages.count) \(document.pages.count == 1 ? "page" : "pages") · Edited \(document.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(NotionTheme.caption)
                                        .foregroundStyle(NotionTheme.inkTertiary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 10)
                        }
                        .padding(.horizontal, 7)
                        .frame(minHeight: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NotionRowButtonStyle())
                    .simultaneousGesture(TapGesture().onEnded { recordRecent(document.id) })
                    .contextMenu {
                        Button(isFavorite(document.id) ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") {
                            toggleFavorite(document.id)
                        }
                        Button("Rename", systemImage: "pencil") {
                            present(.name(.renameDocument(document.id)))
                        }
                        Button("Move to folder", systemImage: "folder") {
                            present(.moveDocument(document.id))
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deleteTarget = .document(document.id)
                        }
                    }

                    Button {
                        toggleFavorite(document.id)
                    } label: {
                        Image(systemName: isFavorite(document.id) ? "star.fill" : "star")
                            .font(.system(size: 12))
                            .foregroundStyle(isFavorite(document.id) ? NotionTheme.inkSecondary : NotionTheme.inkTertiary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NotionIconButtonStyle())
                    .accessibilityLabel(isFavorite(document.id) ? "Remove from Favorites" : "Add to Favorites")
                }
            }
        }
    }

    private var currentFolder: NotyFolder? {
        guard let selectedFolderID else { return nil }
        return store.folders.first { $0.id == selectedFolderID }
    }

    private var currentTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Search results" }
        switch selection {
        case .all: return "Library"
        case .recents: return "Recents"
        case .favorites: return "Favorites"
        case .trash: return "Trash"
        case .folder: return currentFolder?.name ?? "Folder"
        }
    }

    private var folderDescription: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Titles, folders, typed text, handwriting, and PDF text"
        }
        switch selection {
        case .all:
            return "Your notebooks and imported documents"
        case .recents:
            return "Pages you have opened recently"
        case .favorites:
            return "Pages you have saved for quick access"
        case .trash:
            return "Restore deleted documents or remove them permanently"
        case .folder:
            return "Pages and folders in this location"
        }
    }

    private var visibleFolders: [NotyFolder] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return store.folders
                .filter { $0.name.localizedCaseInsensitiveContains(query) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        guard selection == .all || selectedFolderID != nil else { return [] }
        return store.folders
            .filter { $0.parentID == selectedFolderID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var visibleDocuments: [NotyDocument] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [NotyDocument]
        if !query.isEmpty {
            let matchingIDs = Set(searchResults.map(\.documentID))
            candidates = store.documents.filter { matchingIDs.contains($0.id) }
        } else {
            switch selection {
            case .all:
                candidates = store.documents
            case .recents:
                let recentPages = recentDocuments
                return sortOrder == .edited ? recentPages : sortDocuments(recentPages)
            case .favorites:
                candidates = favoriteDocuments
            case .trash:
                candidates = []
            case .folder:
                candidates = store.documents.filter { $0.folderID == selectedFolderID }
            }
        }
        return sortDocuments(candidates)
    }

    private var visibleTrashItems: [NotyTrashedDocument] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = query.isEmpty
            ? store.trashItems
            : store.trashItems.filter { $0.document.title.localizedCaseInsensitiveContains(query) }
        return items.sorted { $0.deletedAt > $1.deletedAt }
    }

    private var recentDocuments: [NotyDocument] {
        let byID = Dictionary(uniqueKeysWithValues: store.documents.map { ($0.id, $0) })
        return recentIDs.compactMap { byID[$0] }
    }

    private var favoriteDocuments: [NotyDocument] {
        let ids = favoriteIDs
        return sortDocuments(store.documents.filter { ids.contains($0.id) })
    }

    private var favoriteIDs: Set<UUID> {
        Set(favoriteIDsValue.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private var recentIDs: [UUID] {
        recentIDsValue.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }

    private var sortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: sortOrderValue) ?? .edited
    }

    private var ancestorFolders: [NotyFolder] {
        guard let currentFolder else { return [] }
        var ancestors: [NotyFolder] = []
        var nextID = currentFolder.parentID
        var visited: Set<UUID> = [currentFolder.id]
        while let id = nextID, visited.insert(id).inserted,
              let parent = store.folders.first(where: { $0.id == id }) {
            ancestors.insert(parent, at: 0)
            nextID = parent.parentID
        }
        return ancestors
    }

    private var folderOutline: [FolderOutlineRow] {
        var result: [FolderOutlineRow] = []
        var visited = Set<UUID>()

        func appendChildren(of parentID: UUID?, depth: Int) {
            let children = store.folders
                .filter { $0.parentID == parentID }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for folder in children where !visited.contains(folder.id) {
                visited.insert(folder.id)
                result.append(FolderOutlineRow(folder: folder, depth: depth))
                if expandedFolderIDs.contains(folder.id) {
                    appendChildren(of: folder.id, depth: depth + 1)
                }
            }
        }

        appendChildren(of: nil, depth: 0)
        return result
    }

    private var trashList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                NotionSectionLabel(text: "Deleted documents")
                Spacer()
                Text("\(visibleTrashItems.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(NotionTheme.inkTertiary)
            }
            .padding(.bottom, 2)

            ForEach(visibleTrashItems) { item in
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(NotionTheme.rowHover)
                        Image(systemName: documentSymbol(item.document.kind))
                            .font(.system(size: 13))
                            .foregroundStyle(NotionTheme.inkSecondary)
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.document.title)
                            .font(NotionTheme.font(14, weight: .medium))
                            .foregroundStyle(NotionTheme.ink)
                            .lineLimit(1)
                        Text("Deleted \(item.deletedAt.formatted(date: .abbreviated, time: .shortened)) · \(item.document.pages.count) \(item.document.pages.count == 1 ? "page" : "pages")")
                            .font(NotionTheme.caption)
                            .foregroundStyle(NotionTheme.inkTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Restore") {
                        store.restoreTrashedDocument(id: item.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    Button(role: .destructive) {
                        deleteTarget = .trashedDocument(item.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Permanently delete \(item.document.title)")
                }
                .frame(minHeight: 46)
                .contextMenu {
                    Button("Restore", systemImage: "arrow.uturn.backward") {
                        store.restoreTrashedDocument(id: item.id)
                    }
                    Button("Delete permanently", systemImage: "trash", role: .destructive) {
                        deleteTarget = .trashedDocument(item.id)
                    }
                }
                Rectangle().fill(NotionTheme.hairline).frame(height: 1)
            }
        }
    }

    private var documentRevisionSignature: String {
        store.documents
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }
            .joined(separator: "|")
    }

    private var folderRevisionSignature: String {
        store.folders
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString):\($0.parentID?.uuidString ?? "root"): \($0.name)" }
            .joined(separator: "|")
    }

    private var deletePrompt: String {
        switch deleteTarget {
        case .folder: "Remove this folder?"
        case .document: "Move this document to Trash?"
        case .trashedDocument: "Permanently delete this document?"
        case .emptyTrash: "Empty Trash?"
        case nil: "Delete?"
        }
    }

    private var deleteMessage: String {
        switch deleteTarget {
        case .folder: "Its documents and subfolders will move to its parent folder or the library."
        case .document: "You can restore it later from Trash."
        case .trashedDocument: "This cannot be undone."
        case .emptyTrash: "Every document in Trash will be permanently deleted. This cannot be undone."
        case nil: ""
        }
    }

    private func hasChildren(_ folderID: UUID) -> Bool {
        store.folders.contains { $0.parentID == folderID }
            || store.documents.contains { $0.folderID == folderID }
    }

    private func sidebarDocuments(in folderID: UUID) -> [NotyDocument] {
        store.documents
            .filter { $0.folderID == folderID }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func sidebarDocumentRow(_ document: NotyDocument, depth: Int) -> some View {
        Button {
            openEditor(document.id)
        } label: {
            HStack(spacing: 8) {
                Color.clear.frame(width: 20, height: 1)

                Image(systemName: documentSymbol(document.kind))
                    .font(.system(size: 12))
                    .foregroundStyle(NotionTheme.inkSecondary)
                    .frame(width: 16)

                Text(document.title)
                    .font(NotionTheme.font(12))
                    .foregroundStyle(NotionTheme.ink)
                    .lineLimit(1)

                Spacer(minLength: 3)
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 13)
        .notionSidebarRow()
        .contextMenu {
            Button(isFavorite(document.id) ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") {
                toggleFavorite(document.id)
            }
            Button("Rename", systemImage: "pencil") {
                present(.name(.renameDocument(document.id)))
            }
            Button("Move", systemImage: "folder") {
                present(.moveDocument(document.id))
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                deleteTarget = .document(document.id)
            }
        }
    }

    private func sidebarDestination(_ title: String, symbol: String, count: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(NotionTheme.inkSecondary)
                .frame(width: 18)
            Text(title)
                .font(NotionTheme.body)
                .foregroundStyle(NotionTheme.ink)
            Spacer(minLength: 4)
            if count > 0 {
                Text(count.formatted())
                    .font(NotionTheme.captionSmall)
                    .foregroundStyle(NotionTheme.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: NotionTheme.sidebarRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func folderSidebarRow(_ row: FolderOutlineRow) -> some View {
        HStack(spacing: 2) {
            if hasChildren(row.folder.id) {
                Button {
                    if expandedFolderIDs.contains(row.folder.id) {
                        expandedFolderIDs.remove(row.folder.id)
                    } else {
                        expandedFolderIDs.insert(row.folder.id)
                    }
                } label: {
                    Image(systemName: expandedFolderIDs.contains(row.folder.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NotionTheme.inkTertiary)
                        .frame(width: 20, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expandedFolderIDs.contains(row.folder.id) ? "Collapse folder" : "Expand folder")
            } else {
                Color.clear.frame(width: 20, height: 30)
            }

            Button {
                selection = .folder(row.folder.id)
                expandAncestors(of: row.folder.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: hasChildren(row.folder.id) ? "folder.fill" : "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(NotionTheme.inkSecondary)
                    Text(row.folder.name)
                        .font(NotionTheme.font(13))
                        .foregroundStyle(NotionTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    let count = store.documents.filter { $0.folderID == row.folder.id }.count
                    if count > 0 {
                        Text(count.formatted())
                            .font(NotionTheme.captionSmall)
                            .foregroundStyle(NotionTheme.inkTertiary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(row.depth) * 13)
        .notionSidebarRow(isSelected: selectedFolderID == row.folder.id)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                present(.name(.renameFolder(row.folder.id)))
            }
            Button("Delete folder", systemImage: "trash", role: .destructive) {
                deleteTarget = .folder(row.folder.id)
            }
        }
    }

    private func expandAncestors(of folderID: UUID) {
        var nextID = store.folders.first(where: { $0.id == folderID })?.parentID
        var visited: Set<UUID> = [folderID]
        while let id = nextID, visited.insert(id).inserted,
              let parent = store.folders.first(where: { $0.id == id }) {
            expandedFolderIDs.insert(id)
            nextID = parent.parentID
        }
    }

    private func refreshSearchResults() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = query.isEmpty ? [] : store.search(query: query)
    }

    private func searchCaption(for document: NotyDocument) -> String? {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let result = searchResults.first(where: { $0.documentID == document.id && $0.pageID != nil }),
              let pageID = result.pageID else {
            return nil
        }
        let pageNumber = document.pages.firstIndex(where: { $0.id == pageID }).map { $0 + 1 }
        let pagePrefix = pageNumber.map { "Page \($0) · " } ?? ""
        return pagePrefix + result.snippet
    }

    private func folderItemCount(_ folderID: UUID) -> Int {
        store.documents.filter { $0.folderID == folderID }.count
            + store.folders.filter { $0.parentID == folderID }.count
    }

    private func sortDocuments(_ documents: [NotyDocument]) -> [NotyDocument] {
        switch sortOrder {
        case .edited:
            documents.sorted { $0.updatedAt > $1.updatedAt }
        case .title:
            documents.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .created:
            documents.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func isFavorite(_ documentID: UUID) -> Bool {
        favoriteIDs.contains(documentID)
    }

    private func toggleFavorite(_ documentID: UUID) {
        var ids = favoriteIDs
        if ids.contains(documentID) { ids.remove(documentID) }
        else { ids.insert(documentID) }
        favoriteIDsValue = ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    private func recordRecent(_ documentID: UUID) {
        var ids = recentIDs.filter { $0 != documentID }
        ids.insert(documentID, at: 0)
        recentIDsValue = ids.prefix(30).map(\.uuidString).joined(separator: ",")
    }

    private func documentSymbol(_ kind: NotyDocumentKind) -> String {
        switch kind {
        case .note, .book: "book.closed"
        case .pdf: "doc.richtext"
        }
    }

    private func documentKindLabel(_ kind: NotyDocumentKind) -> String {
        switch kind {
        case .note, .book: "Notebook"
        case .pdf: "PDF"
        }
    }

    private func createNotebook() {
        let document = store.createDocument(title: "Untitled Notebook", kind: .book, folderID: selectedFolderID)
        activeSheet = nil
        openEditor(document.id)
    }

    private func openEditor(_ documentID: UUID) {
        recordRecent(documentID)
        editorPath = [documentID]
    }

    private func present(_ destination: LibrarySheetRequest.Destination) {
        activeSheet = LibrarySheetRequest(destination: destination)
    }

    @ViewBuilder
    private func sheet(for destination: LibrarySheetRequest.Destination) -> some View {
        switch destination {
        case .name(let purpose):
            switch purpose {
            case .newFolder(let parentID):
                NameEntrySheet(title: "New folder", placeholder: "Folder name", initialValue: "") { name in
                    store.createFolder(name: name, parentID: parentID)
                }
            case .renameFolder(let folderID):
                NameEntrySheet(
                    title: "Rename folder",
                    placeholder: "Folder name",
                    initialValue: store.folders.first { $0.id == folderID }?.name ?? ""
                ) { name in
                    store.renameFolder(id: folderID, name: name)
                }
            case .renameDocument(let documentID):
                NameEntrySheet(
                    title: "Rename document",
                    placeholder: "Document title",
                    initialValue: store.documents.first { $0.id == documentID }?.title ?? ""
                ) { name in
                    store.renameDocument(id: documentID, title: name)
                }
            }
        case .moveDocument(let documentID):
            MoveDocumentSheet(
                folders: store.folders,
                currentFolderID: store.documents.first { $0.id == documentID }?.folderID
            ) { folderID in
                store.moveDocument(id: documentID, to: folderID)
            }
        case .settings:
            NavigationStack {
                LibrarySettingsView(store: store, oneDrive: oneDrive, account: account)
            }
        }
    }

    private func performDelete() {
        switch deleteTarget {
        case .folder(let folderID):
            store.deleteFolder(id: folderID)
            if selectedFolderID == folderID { selection = .all }
        case .document(let documentID):
            store.deleteDocument(id: documentID)
        case .trashedDocument(let documentID):
            store.permanentlyDeleteTrashedDocument(id: documentID)
        case .emptyTrash:
            store.emptyTrash()
        case nil:
            break
        }
        deleteTarget = nil
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled {
                alertMessage = error.localizedDescription
            }
        case .success(let urls):
            Task {
                var importErrors: [String] = []
                var importNotices: [String] = []
                for url in urls {
                    let didStartAccessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if didStartAccessing { url.stopAccessingSecurityScopedResource() }
                    }
                    do {
                        if let type = UTType(filenameExtension: url.pathExtension),
                           type.conforms(to: .image) {
                            let data = try Data(contentsOf: url)
                            guard let image = UIImage(data: data) else {
                                throw NotyStoreError.invalidImage
                            }
                            importImagesAsNotebook(
                                [image],
                                title: url.deletingPathExtension().lastPathComponent,
                                openWhenDone: false
                            )
                        } else {
                            _ = try await store.importDocument(from: url, folderID: selectedFolderID, converter: nil)
                            if let message = store.lastOperationMessage {
                                importNotices.append("\(url.lastPathComponent): \(message)")
                            }
                        }
                    } catch {
                        importErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                let operationMessages = importErrors + importNotices
                if !operationMessages.isEmpty {
                    alertMessage = operationMessages.joined(separator: "\n")
                }
                if oneDrive.isConnected {
                    await oneDrive.syncAllPDFs(store: store)
                }
            }
        }
    }

    private func importSelectedPhotos() {
        let items = importPhotoItems
        importPhotoItems = []
        guard !items.isEmpty else { return }

        Task { @MainActor in
            var images: [UIImage] = []
            var failures = 0

            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        failures += 1
                        continue
                    }
                    images.append(image)
                } catch {
                    failures += 1
                }
            }

            guard !images.isEmpty else {
                alertMessage = "Noty couldn’t read the selected photos."
                return
            }

            importImagesAsNotebook(images, title: images.count == 1 ? "Imported Photo" : "Photo Import", openWhenDone: true)
            if failures > 0 {
                alertMessage = "\(failures) selected photo\(failures == 1 ? "" : "s") could not be imported."
            }
        }
    }

    private func importImagesAsNotebook(_ images: [UIImage], title: String, openWhenDone: Bool) {
        guard !images.isEmpty else { return }

        let document = store.createDocument(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported Notebook" : title,
            kind: .book,
            folderID: selectedFolderID
        )

        guard var pageID = document.pages.first?.id else {
            alertMessage = "Noty couldn’t create a page for the import."
            return
        }

        var failedCount = 0

        for (index, image) in images.enumerated() {
            if index > 0 {
                store.addPage(documentID: document.id, after: pageID, template: .blank)
                guard let updatedDocument = store.documents.first(where: { $0.id == document.id }),
                      let nextPageID = updatedDocument.pages.last?.id else {
                    failedCount += 1
                    continue
                }
                pageID = nextPageID
            }

            do {
                try addImportedImage(image, documentID: document.id, pageID: pageID)
            } catch {
                failedCount += 1
            }
        }

        if failedCount == images.count {
            store.deleteDocument(id: document.id)
            alertMessage = "Noty couldn’t import these images."
            return
        }

        if failedCount > 0 {
            alertMessage = "\(failedCount) image\(failedCount == 1 ? "" : "s") could not be imported."
        }

        if openWhenDone {
            openEditor(document.id)
        }
    }

    private func addImportedImage(_ image: UIImage, documentID: UUID, pageID: UUID) throws {
        let maxPixelDimension: CGFloat = 2400
        let longestSide = max(image.size.width, image.size.height)
        let scale = longestSide > maxPixelDimension ? maxPixelDimension / longestSide : 1
        let normalizedSize = CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )

        let renderer = UIGraphicsImageRenderer(size: normalizedSize)
        let normalizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: normalizedSize))
        }
        guard let data = normalizedImage.jpegData(compressionQuality: 0.92) ?? normalizedImage.pngData() else {
            throw NotyStoreError.invalidImage
        }

        let added = try store.addPageImage(data: data, documentID: documentID, pageID: pageID)

        guard let page = store.documents
            .first(where: { $0.id == documentID })?
            .pages.first(where: { $0.id == pageID }) else { return }

        let margin: CGFloat = 24
        let availableWidth = max(80, page.canvasSize.width - margin * 2)
        let availableHeight = max(80, page.canvasSize.height - margin * 2)
        let imageAspect = max(normalizedSize.width / max(normalizedSize.height, 1), 0.01)

        var width = availableWidth
        var height = width / imageAspect
        if height > availableHeight {
            height = availableHeight
            width = height * imageAspect
        }

        var pageImages = page.images
        guard let index = pageImages.firstIndex(where: { $0.id == added.id }) else { return }
        pageImages[index].x = Double((page.canvasSize.width - width) / 2)
        pageImages[index].y = Double((page.canvasSize.height - height) / 2)
        pageImages[index].width = Double(width)
        pageImages[index].height = Double(height)
        store.updatePageImages(documentID: documentID, pageID: pageID, images: pageImages)
    }

    private func scheduleOneDriveSync() {
        guard oneDrive.isConnected else { return }
        syncDebounce?.cancel()
        let scheduleID = UUID()
        syncDebounceID = scheduleID
        syncDebounce = Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled, syncDebounceID == scheduleID else { return }
            syncDebounce = nil
            syncDebounceID = nil
            await oneDrive.syncAllPDFs(store: store)
        }
    }

    private func syncCloudMirrors() async {
        if oneDrive.isConnected {
            await oneDrive.syncAllPDFs(store: store)
        }
        if store.iCloudMirrorFolderURL != nil {
            await store.syncICloudMirror()
        }
    }

    private func scheduleBackgroundCloudRetry() {
        NotyBackgroundSyncScheduler.scheduleIfNeeded(
            hasWork: store.hasICloudMirror || oneDrive.isConnected
        )
    }

    private func flushCloudMirrorsBeforeSuspension() {
        scheduleBackgroundCloudRetry()
        syncDebounce?.cancel()
        syncDebounce = nil
        syncDebounceID = nil
        let task = LibraryBackgroundTask()
        task.begin()
        backgroundSyncTask = task
        Task {
            await syncCloudMirrors()
            task.end()
            if backgroundSyncTask === task {
                backgroundSyncTask = nil
            }
        }
    }
}

private struct DocumentScannerSheet: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    let onCancel: () -> Void
    let onFailure: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) { }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        let onCancel: () -> Void
        let onFailure: (Error) -> Void

        init(
            onScan: @escaping ([UIImage]) -> Void,
            onCancel: @escaping () -> Void,
            onFailure: @escaping (Error) -> Void
        ) {
            self.onScan = onScan
            self.onCancel = onCancel
            self.onFailure = onFailure
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            onScan(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            onFailure(error)
        }
    }
}

@MainActor
private final class LibraryBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Noty Cloud Mirror") { [weak self] in
            Task { @MainActor [weak self] in
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

private struct FolderOutlineRow {
    let folder: NotyFolder
    let depth: Int
}

private enum LibrarySelection: Hashable {
    case all
    case recents
    case favorites
    case trash
    case folder(UUID)
}

private enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case edited
    case title
    case created

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edited: "Last edited"
        case .title: "Title"
        case .created: "Date created"
        }
    }
}

private enum DeleteTarget {
    case folder(UUID)
    case document(UUID)
    case trashedDocument(UUID)
    case emptyTrash
}

private enum FolderPickerDestination {
    case syncFolder
    case oneDrive
}

private struct LibrarySheetRequest: Identifiable {
    enum Destination {
        enum NamePurpose {
            case newFolder(parentID: UUID?)
            case renameFolder(UUID)
            case renameDocument(UUID)
        }

        case name(NamePurpose)
        case moveDocument(UUID)
        case settings
    }

    let id = UUID()
    let destination: Destination

    init(destination: Destination) {
        self.destination = destination
    }
}

private struct NameEntrySheet: View {
    let title: String
    let placeholder: String
    let initialValue: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var name: String

    init(title: String, placeholder: String, initialValue: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.initialValue = initialValue
        self.onSave = onSave
        _name = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(NotionTheme.inkSecondary)

                Spacer()

                Text(title)
                    .font(NotionTheme.font(14, weight: .semibold))
                    .foregroundStyle(NotionTheme.ink)

                Spacer()

                Button("Save", action: save)
                    .font(NotionTheme.font(13, weight: .semibold))
                    .foregroundStyle(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NotionTheme.inkTertiary : NotionTheme.accent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)

            Rectangle().fill(NotionTheme.hairline).frame(height: 1)

            TextField(placeholder, text: $name)
                .font(NotionTheme.body)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(NotionTheme.rowHover, in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium))
                .padding(18)
        }
        .frame(width: 420)
        .background(NotionTheme.canvas)
        .presentationSizing(.fitted)
        .task { isFocused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

private struct MoveDocumentSheet: View {
    let folders: [NotyFolder]
    let currentFolderID: UUID?
    let onMove: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss

    private var orderedFolders: [MoveFolderRow] {
        var result: [MoveFolderRow] = []
        var visited = Set<UUID>()

        func appendChildren(of parentID: UUID?, depth: Int) {
            let children = folders
                .filter { $0.parentID == parentID }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for folder in children where !visited.contains(folder.id) {
                visited.insert(folder.id)
                result.append(MoveFolderRow(folder: folder, depth: depth))
                appendChildren(of: folder.id, depth: depth + 1)
            }
        }

        appendChildren(of: nil, depth: 0)
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onMove(nil)
                    dismiss()
                } label: {
                    HStack {
                        Label("Library", systemImage: "square.grid.2x2")
                        Spacer()
                        if currentFolderID == nil { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                ForEach(orderedFolders) { row in
                    Button {
                        onMove(row.folder.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(row.folder.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if currentFolderID == row.folder.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .padding(.leading, CGFloat(row.depth) * 14)
                    }
                }
            }
            .font(NotionTheme.body)
            .buttonStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(NotionTheme.canvas)
            .tint(NotionTheme.accent)
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationSizing(.form)
    }
}

private struct MoveFolderRow: Identifiable {
    let folder: NotyFolder
    let depth: Int
    var id: UUID { folder.id }
}

private struct LibrarySettingsView: View {
    var store: NotyStore
    var oneDrive: OneDriveService
    var account: NotyAccountService

    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingFolder = false
    @State private var folderPickerDestination: FolderPickerDestination?
    @State private var errorMessage: String?
    @State private var sharedFolderLinkDraft = ""
    @State private var accountEmail = ""
    @State private var accountPassword = ""

    var body: some View {
        Form {
            Section {
                if account.isAuthenticated {
                    LabeledContent("Signed in", value: account.email ?? "Noty account")
                    Text(account.status)
                        .font(NotionTheme.caption)
                        .foregroundStyle(.secondary)
                    if let lastError = account.lastError {
                        Text(lastError)
                            .font(NotionTheme.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Button("Refresh account data", systemImage: "arrow.clockwise") {
                        Task { await account.refreshProfile() }
                    }
                    Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task {
                            await account.signOut()
                            sharedFolderLinkDraft = ""
                            accountPassword = ""
                        }
                    }
                } else {
                    TextField("Email", text: $accountEmail)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $accountPassword)
                        .textContentType(.password)
                    HStack {
                        Button("Sign in") {
                            signIn()
                        }
                        .disabled(account.isWorking || accountEmail.isEmpty || accountPassword.isEmpty)

                        Button("Create account") {
                            createAccount()
                        }
                        .disabled(account.isWorking || accountEmail.isEmpty || accountPassword.isEmpty)
                    }
                    if account.isWorking {
                        ProgressView()
                    }
                    Text(account.lastError ?? account.status)
                        .font(NotionTheme.caption)
                        .foregroundStyle(account.lastError == nil ? NotionTheme.inkSecondary : NotionTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Noty Account")
            } footer: {
                Text("Your account is backed by Supabase Auth + Postgres. Noty stores only workspace metadata here, such as the iCloud sharing link and folder name. Notes remain in your selected sync folder.")
            }

            if let persistenceError = store.lastPersistenceError, !persistenceError.isEmpty {
                Section("Local storage") {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A change could not be saved")
                                .font(NotionTheme.font(13, weight: .semibold))
                            Text(persistenceError)
                                .font(NotionTheme.caption)
                                .textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                LabeledContent("Connected folder", value: store.iCloudMirrorFolderURL?.lastPathComponent ?? "Not connected")

                Text("Use the same writable folder on every device. Noty keeps an editable library in that folder and merges newer changes back into the local library.")
                    .font(NotionTheme.caption)
                    .foregroundStyle(.secondary)

                Button(store.iCloudMirrorFolderURL == nil ? "Choose sync folder" : "Choose another sync folder", systemImage: "folder.badge.plus") {
                    presentFolderPicker(.syncFolder)
                }

                if store.iCloudMirrorFolderURL != nil {
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await store.syncICloudMirror() }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder status")
                        .font(NotionTheme.bodySmall)
                        .foregroundStyle(.secondary)
                    Text(displayICloudMirrorStatus(store.syncStatus))
                        .font(NotionTheme.caption)
                        .foregroundStyle(isICloudStatusError ? NotionTheme.danger : NotionTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Divider()

                Text("Optional shared folder link")
                    .font(NotionTheme.font(13, weight: .semibold))

                TextField("https://www.icloud.com/…", text: $sharedFolderLinkDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Button("Save link to my Noty account", systemImage: "person.crop.circle.badge.checkmark") {
                    saveSharedFolderLink()
                }
                .disabled(!account.isAuthenticated || account.isWorking)

                if let sharedURL = account.sharedFolderURL {
                    Button("Open saved shared-folder link", systemImage: "link") {
                        UIApplication.shared.open(sharedURL, options: [:], completionHandler: nil)
                    }

                    ShareLink(item: sharedURL) {
                        Label("Share folder link", systemImage: "square.and.arrow.up")
                    }

                    Button("Remove saved link from my account", systemImage: "trash", role: .destructive) {
                        forgetSharedFolderLink()
                    }
                }

                if account.isAuthenticated {
                    Button("Refresh link from my account", systemImage: "arrow.clockwise") {
                        refreshSharedFolderLink()
                    }
                }

                Text(account.status)
                    .font(NotionTheme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Sync with Folder")
            } footer: {
                Text("Sign in to the same Noty account on another device and the saved workspace link/folder name comes from the backend automatically. iOS still requires each Apple device to approve the Files folder once. Prefer “People You Choose”; an “Anyone with the link” editable share can be modified by anyone who gets that URL.")
            }

            Section {
                LabeledContent("Selected Files folder", value: oneDrive.mirrorFolderName ?? "Not selected")
                Text(oneDrive.syncStatus)
                    .font(NotionTheme.caption)
                    .foregroundStyle(.secondary)
                if let lastError = oneDrive.lastError {
                    Text(lastError)
                        .font(NotionTheme.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Button(oneDrive.mirrorFolderName != nil ? "Choose another folder" : "Choose OneDrive folder in Files", systemImage: "folder.badge.plus") {
                    presentFolderPicker(.oneDrive)
                }
                if oneDrive.mirrorFolderName != nil {
                    Button("Sync PDFs now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await oneDrive.syncAllPDFs(store: store) }
                    }
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                        oneDrive.disconnect()
                        NotyBackgroundSyncScheduler.scheduleIfNeeded(hasWork: store.hasICloudMirror)
                    }
                }
                Text("Sign in with Microsoft in the official OneDrive app, then select its writable folder in Files. Noty saves PDF copies after edits while it is open and when you return to it. Deleted Noty pages keep their saved PDF copies here. The selected Files provider may upload them later.")
                    .font(NotionTheme.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("OneDrive")
            } footer: {
                Text("Noty stores permission for the selected Files folder and does not handle your Microsoft account credentials. Disconnecting removes permission but leaves saved copies in place. The selected location may be provided by another Files provider.")
            }
        }
        .font(NotionTheme.bodySmall)
        .scrollContentBackground(.hidden)
        .background(NotionTheme.canvas)
        .tint(NotionTheme.accent)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(NotionTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch folderPickerDestination {
            case .syncFolder:
                configureSyncFolder(result)
            case .oneDrive:
                configureOneDriveFolder(result)
            case nil:
                break
            }
            folderPickerDestination = nil
        }
        .alert(
            "Noty",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await account.bootstrap()
            if accountEmail.isEmpty { accountEmail = account.email ?? "" }
            if sharedFolderLinkDraft.isEmpty, let syncedLink = account.sharedFolderLink {
                sharedFolderLinkDraft = syncedLink
            }
        }
    }

    private func presentFolderPicker(_ destination: FolderPickerDestination) {
        folderPickerDestination = destination
        isChoosingFolder = true
    }

    private var isICloudStatusError: Bool {
        let status = store.syncStatus.lowercased()
        return ["error", "failed", "could not", "unavailable", "not available", "expired", "needs to be renewed"]
            .contains(where: { status.contains($0) })
    }

    private func configureSyncFolder(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled { errorMessage = error.localizedDescription }
        case .success(let urls):
            guard let folderURL = urls.first else { return }
            let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing { folderURL.stopAccessingSecurityScopedResource() }
            }
            do {
                try store.configureICloudMirror(folderURL: folderURL)
                NotyBackgroundSyncScheduler.scheduleIfNeeded(hasWork: true)
                Task {
                    await store.syncICloudMirror()
                    if account.isAuthenticated {
                        try? await account.saveSyncProfile(
                            sharedFolderLink: account.sharedFolderLink,
                            folderDisplayName: folderURL.lastPathComponent
                        )
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveSharedFolderLink() {
        Task {
            do {
                try await account.saveSyncProfile(
                    sharedFolderLink: sharedFolderLinkDraft,
                    folderDisplayName: store.iCloudMirrorFolderURL?.lastPathComponent
                )
                sharedFolderLinkDraft = account.sharedFolderLink ?? ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshSharedFolderLink() {
        Task {
            await account.refreshProfile()
            if let syncedLink = account.sharedFolderLink {
                sharedFolderLinkDraft = syncedLink
            }
        }
    }

    private func forgetSharedFolderLink() {
        Task {
            do {
                try await account.clearSharedFolderLink()
                sharedFolderLinkDraft = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func signIn() {
        Task {
            do {
                try await account.signIn(email: accountEmail, password: accountPassword)
                accountPassword = ""
                sharedFolderLinkDraft = account.sharedFolderLink ?? ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func createAccount() {
        Task {
            do {
                try await account.signUp(email: accountEmail, password: accountPassword)
                accountPassword = ""
                sharedFolderLinkDraft = account.sharedFolderLink ?? ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func configureOneDriveFolder(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled { errorMessage = error.localizedDescription }
        case .success(let urls):
            guard let folderURL = urls.first else { return }
            do {
                try oneDrive.configureMirrorFolder(folderURL: folderURL)
                NotyBackgroundSyncScheduler.scheduleIfNeeded(hasWork: true)
                Task { await oneDrive.syncAllPDFs(store: store) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct DocumentPreview: View {
    let document: NotyDocument

    private var isBook: Bool { document.kind == .book }

    private var previewText: String? {
        let text = document.pages.first?.textBoxes.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isBook {
                Text("BOOK")
                    .font(.system(size: 5.5, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(NotionTheme.inkTertiary)
                Spacer(minLength: 2)
                Text(document.title)
                    .font(.system(size: 7.5, weight: .medium, design: .serif))
                    .foregroundStyle(NotionTheme.inkSecondary)
                    .lineLimit(4)
                    .minimumScaleFactor(0.75)
                Rectangle()
                    .fill(NotionTheme.inkTertiary.opacity(0.65))
                    .frame(width: 12, height: 1)
            } else {
                HStack(spacing: 2) {
                    Image(systemName: document.kind == .pdf ? "doc.richtext" : "doc.text")
                        .font(.system(size: 6, weight: .medium))
                    Text(document.kind == .pdf ? "PDF" : "NOTE")
                        .font(.system(size: 5, weight: .semibold))
                        .tracking(0.45)
                }
                .foregroundStyle(NotionTheme.inkTertiary)
                if let previewText {
                    Text(previewText)
                        .font(.system(size: 5.5))
                        .foregroundStyle(NotionTheme.inkSecondary)
                        .lineLimit(6)
                        .minimumScaleFactor(0.7)
                } else {
                    Spacer(minLength: 1)
                    ForEach(0..<4) { index in
                        Rectangle()
                            .fill(NotionTheme.templateLine)
                            .frame(height: 1)
                            .padding(.trailing, index == 3 ? 8 : 0)
                    }
                    Spacer(minLength: 1)
                }
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isBook ? NotionTheme.sidebar : NotionTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(NotionTheme.hairline, lineWidth: 0.75)
        }
        .accessibilityHidden(true)
    }
}

/// Keep provider wording neutral: folder sync can point to iCloud Drive or
/// another writable Files provider.
private func displayICloudMirrorStatus(_ status: String) -> String {
    let legacyPrefix = "Saved to the selected iCloud Drive folder at "
    let folderPrefix = "Saved to the selected sync folder at "
    let prefix = status.hasPrefix(folderPrefix) ? folderPrefix : legacyPrefix
    guard status.hasPrefix(prefix) else { return status }
    let timestamp = status.dropFirst(prefix.count).components(separatedBy: ";").first ?? ""
    return "Library synced with the selected Files folder at \(timestamp). Its provider controls any cloud upload."
}

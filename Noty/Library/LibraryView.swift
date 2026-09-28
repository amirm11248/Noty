import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var syncDebounce: Task<Void, Never>?
    @State private var syncDebounceID: UUID?
    @State private var backgroundSyncTask: LibraryBackgroundTask?
    @State private var alertMessage: String?
    @State private var searchResults: [NotySearchResult] = []
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
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("New folder", systemImage: "folder.badge.plus") {
                                present(.name(.newFolder(parentID: selectedFolderID)))
                            }
                            Button("New note", systemImage: "square.and.pencil") {
                                createDocument(.note)
                            }
                            Button("New book", systemImage: "books.vertical") {
                                createDocument(.book)
                            }
                            Divider()
                            Button("Import from Files", systemImage: "square.and.arrow.down") {
                                isImporting = true
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Create or import")
                    }
                }
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
                UTType("com.microsoft.word.doc") ?? .data,
                UTType("org.openxmlformats.wordprocessingml.document") ?? .data
            ],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
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
                Task { await syncCloudMirrors() }
            case .background:
                flushCloudMirrorsBeforeSuspension()
            default:
                break
            }
        }
        .task {
            refreshSearchResults()
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
                    sidebarDestination("Library", symbol: "square.grid.2x2", count: store.documents.count)
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

                Button {
                    selection = .trash
                    searchText = ""
                } label: {
                    sidebarDestination("Trash", symbol: "trash", count: store.trashItems.count)
                }
                .buttonStyle(.plain)
                .notionSidebarRow(isSelected: selection == .trash)
            } header: {
                NotionSectionLabel(text: "Workspace")
            }

            Section {
                if store.folders.isEmpty {
                    Text("Folders appear here")
                        .font(.system(size: 13))
                        .foregroundStyle(NotionTheme.inkTertiary)
                } else {
                    ForEach(folderOutline, id: \.folder.id) { row in
                        folderSidebarRow(row)
                    }
                }
            } header: {
                NotionSectionLabel(text: "Folders")
            }

            Section {
                Button { present(.settings) } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(NotionTheme.inkSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(NotionTheme.sidebar)
        .foregroundStyle(NotionTheme.ink)
        .tint(NotionTheme.accent)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(NotionTheme.inkSecondary)
                Text("noty")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(NotionTheme.ink)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .background(NotionTheme.sidebar)
        }
    }

    private var detail: some View {
        NavigationStack(path: $editorPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader
                        .padding(.bottom, 26)

                    if selection == .trash {
                        if visibleTrashItems.isEmpty {
                            emptyState
                        } else {
                            trashList
                        }
                    } else {
                        if store.lastPersistenceError?.isEmpty == false {
                            persistenceWarning(store.lastPersistenceError ?? "")
                                .padding(.bottom, 12)
                        }

                        if store.iCloudMirrorFolderURL == nil {
                            iCloudBackupStatus
                                .padding(.bottom, 20)
                        } else {
                            iCloudBackupStatus
                                .padding(.bottom, 14)
                        }
                        if oneDrive.isConnected || oneDrive.lastError != nil {
                            oneDriveBackupStatus
                                .padding(.bottom, 14)
                        }

                        if !visibleFolders.isEmpty {
                            folderList
                                .padding(.bottom, 24)
                        }
                        if !visibleDocuments.isEmpty {
                            documentList
                        }
                        if visibleFolders.isEmpty && visibleDocuments.isEmpty {
                            emptyState
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 38)
                .padding(.bottom, 40)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(NotionTheme.canvas)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search library")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if selection == .trash {
                        if !store.trashItems.isEmpty {
                            Button(role: .destructive) {
                                deleteTarget = .emptyTrash
                            } label: {
                                Label("Empty Trash", systemImage: "trash.slash")
                            }
                        }
                    } else {
                        Button {
                            isImporting = true
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .help("Import PDF or Office documents from Files")

                        Menu {
                            Button("New note", systemImage: "square.and.pencil") {
                                createDocument(.note)
                            }
                            Button("New book", systemImage: "books.vertical") {
                                createDocument(.book)
                            }
                            Button("New folder", systemImage: "folder.badge.plus") {
                                present(.name(.newFolder(parentID: selectedFolderID)))
                            }
                            Divider()
                            Button("Settings", systemImage: "gearshape") {
                                present(.settings)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More library actions")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { documentID in
                DocumentEditorView(documentID: documentID, store: store)
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !(selection == .all && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                HStack(spacing: 5) {
                    Button("Library") { selection = .all }
                        .buttonStyle(.plain)
                        .foregroundStyle(NotionTheme.inkTertiary)
                    ForEach(ancestorFolders) { folder in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(NotionTheme.inkTertiary)
                        Button(folder.name) { selection = .folder(folder.id) }
                            .buttonStyle(.plain)
                            .foregroundStyle(NotionTheme.inkTertiary)
                    }
                    if !ancestorFolders.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(NotionTheme.inkTertiary)
                    }
                }
                .font(.system(size: 12))
                .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(currentTitle)
                    .font(NotionTheme.pageTitle)
                    .tracking(-0.6)
                    .foregroundStyle(NotionTheme.ink)
                Spacer(minLength: 8)
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("\(visibleDocuments.count) results")
                        .font(.system(size: 12))
                        .foregroundStyle(NotionTheme.inkTertiary)
                } else {
                    sortMenu
                }
            }

            Text(folderDescription)
                .font(.system(size: 14))
                .foregroundStyle(NotionTheme.inkSecondary)

            Rectangle()
                .fill(NotionTheme.hairline)
                .frame(height: 1)
                .padding(.top, 10)
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
            .font(.system(size: 12, weight: .medium))
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
                Button("Create a note") { createDocument(.note) }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NotionTheme.ink)
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
        if !searchText.isEmpty { return "Try another title, folder, or note text." }
        if selection == .favorites { return "Favorite pages will appear here." }
        if selection == .recents { return "Pages you open will appear here." }
        if selection == .trash { return "Deleted documents stay here until you restore or permanently delete them." }
        return "Create a note or book, or import a PDF from Files."
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
                            Text(isICloudSyncError ? "Restore folder sync access" : "Sync your library with a folder")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(NotionTheme.ink)
                            Text(isICloudSyncError ? displayICloudMirrorStatus(store.syncStatus) : "Choose the same iCloud Drive folder on each device. Noty merges changes automatically.")
                                .font(.system(size: 12))
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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(NotionTheme.ink)
                        Text(displayICloudMirrorStatus(store.syncStatus))
                            .font(.system(size: 12))
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
        VStack(alignment: .leading, spacing: 6) {
            NotionSectionLabel(text: "Folders")
                .padding(.bottom, 2)
            ForEach(visibleFolders) { folder in
                Button {
                    selection = .folder(folder.id)
                    searchText = ""
                    expandAncestors(of: folder.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.system(size: 15))
                            .foregroundStyle(NotionTheme.inkSecondary)
                            .frame(width: 22)
                        Text(folder.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(NotionTheme.ink)
                        Spacer()
                        Text("\(folderItemCount(folder.id))")
                            .font(.system(size: 12))
                            .foregroundStyle(NotionTheme.inkTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NotionTheme.inkTertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                Rectangle().fill(NotionTheme.hairline).frame(height: 1)
            }
        }
    }

    private var documentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                NotionSectionLabel(text: "Pages")
                Spacer()
                Text("\(visibleDocuments.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(NotionTheme.inkTertiary)
            }
            .padding(.bottom, 2)

            ForEach(visibleDocuments) { document in
                HStack(spacing: 8) {
                    NavigationLink(value: document.id) {
                        HStack(spacing: 11) {
                            DocumentPreview(document: document)
                                .frame(width: 42, height: 56)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(document.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(NotionTheme.ink)
                                    .lineLimit(1)
                                if let caption = searchCaption(for: document) {
                                    Text(caption)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(NotionTheme.inkTertiary)
                                        .lineLimit(1)
                                } else {
                                    HStack(spacing: 5) {
                                        Text(documentKindLabel(document.kind))
                                        Text("·")
                                        Text("\(document.pages.count) \(document.pages.count == 1 ? "page" : "pages")")
                                        Text("·")
                                        Text("Edited \(document.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                    }
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(NotionTheme.inkTertiary)
                                    .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 10)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(NotionTheme.inkTertiary.opacity(0.75))
                        }
                        .frame(minHeight: 62)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                            .font(.system(size: 13))
                            .foregroundStyle(isFavorite(document.id) ? NotionTheme.inkSecondary : NotionTheme.inkTertiary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorite(document.id) ? "Remove from Favorites" : "Add to Favorites")
                }
                Rectangle().fill(NotionTheme.hairline).frame(height: 1)
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
            return "Titles, folders, typed notes, handwriting, and PDF text"
        }
        switch selection {
        case .all:
            return "Your notes, books, and imported PDFs"
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
                    DocumentPreview(document: item.document)
                        .frame(width: 42, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.document.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(NotionTheme.ink)
                            .lineLimit(1)
                        Text("Deleted \(item.deletedAt.formatted(date: .abbreviated, time: .shortened)) · \(item.document.pages.count) \(item.document.pages.count == 1 ? "page" : "pages")")
                            .font(.system(size: 11.5))
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
                .frame(minHeight: 64)
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
    }

    private func sidebarDestination(_ title: String, symbol: String, count: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(NotionTheme.inkSecondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(NotionTheme.ink)
            Spacer(minLength: 4)
            Text(count.formatted())
                .font(.system(size: 11))
                .foregroundStyle(NotionTheme.inkTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
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
                        .font(.system(size: 13.5))
                        .foregroundStyle(NotionTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    let count = store.documents.filter { $0.folderID == row.folder.id }.count
                    if count > 0 {
                        Text(count.formatted())
                            .font(.system(size: 11))
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
            Button("New subfolder", systemImage: "folder.badge.plus") {
                present(.name(.newFolder(parentID: row.folder.id)))
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
        case .note: "doc.text"
        case .book: "book"
        case .pdf: "doc.richtext"
        }
    }

    private func documentKindLabel(_ kind: NotyDocumentKind) -> String {
        switch kind {
        case .note: "Note"
        case .book: "Book"
        case .pdf: "PDF"
        }
    }

    private func createDocument(_ kind: NotyDocumentKind) {
        let title = kind == .book ? "Untitled Book" : "Untitled Note"
        let document = store.createDocument(title: title, kind: kind, folderID: selectedFolderID)
        // New documents are immediately ready to open in the editor.
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
                LibrarySettingsView(store: store, oneDrive: oneDrive)
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
                        _ = try await store.importDocument(from: url, folderID: selectedFolderID, converter: nil)
                        if let message = store.lastOperationMessage {
                            importNotices.append("\(url.lastPathComponent): \(message)")
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
        NavigationStack {
            Form {
                TextField(placeholder, text: $name)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { isFocused = true }
        }
        .presentationDetents([.medium])
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
            .buttonStyle(.plain)
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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

    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingFolder = false
    @State private var folderPickerDestination: FolderPickerDestination?
    @State private var errorMessage: String?
    @State private var folderSyncProfile = FolderSyncProfileStore()
    @State private var sharedFolderLinkDraft = ""

    var body: some View {
        Form {
            if let persistenceError = store.lastPersistenceError, !persistenceError.isEmpty {
                Section("Local storage") {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A change could not be saved")
                                .font(.subheadline.weight(.semibold))
                            Text(persistenceError)
                                .font(.footnote)
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
                    .font(.footnote)
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
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(displayICloudMirrorStatus(store.syncStatus))
                        .font(.footnote)
                        .foregroundStyle(isICloudStatusError ? NotionTheme.danger : NotionTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Divider()

                Text("Shared folder link")
                    .font(.subheadline.weight(.semibold))

                TextField("https://www.icloud.com/…", text: $sharedFolderLinkDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Button("Save link for my Apple devices", systemImage: "key.icloud") {
                    saveSharedFolderLink()
                }
                .disabled(sharedFolderLinkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let sharedURL = folderSyncProfile.sharedFolderURL {
                    Button("Open saved shared-folder link", systemImage: "link") {
                        UIApplication.shared.open(sharedURL, options: [:], completionHandler: nil)
                    }

                    ShareLink(item: sharedURL) {
                        Label("Share folder link", systemImage: "square.and.arrow.up")
                    }

                    Button("Forget saved link on my devices", systemImage: "trash", role: .destructive) {
                        forgetSharedFolderLink()
                    }
                }

                Button("Check iCloud Keychain for a link", systemImage: "arrow.clockwise") {
                    refreshSharedFolderLink()
                }

                Text(folderSyncProfile.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Sync with Folder")
            } footer: {
                Text("For the smoothest setup, make an iCloud Drive folder shared as “Anyone with the link” and “Can make changes”, paste that link here once, then choose the folder. iCloud Keychain can carry the link to your other Apple devices. iOS still requires each device to approve Files access once.")
            }

            Section {
                LabeledContent("Selected Files folder", value: oneDrive.mirrorFolderName ?? "Not selected")
                Text(oneDrive.syncStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let lastError = oneDrive.lastError {
                    Text(lastError)
                        .font(.footnote)
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("OneDrive")
            } footer: {
                Text("Noty stores permission for the selected Files folder and does not handle your Microsoft account credentials. Disconnecting removes permission but leaves saved copies in place. The selected location may be provided by another Files provider.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
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
            "Folder access",
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
            folderSyncProfile.refresh()
            if sharedFolderLinkDraft.isEmpty, let syncedLink = folderSyncProfile.sharedFolderLink {
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
                Task { await store.syncICloudMirror() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveSharedFolderLink() {
        do {
            try folderSyncProfile.saveSharedFolderLink(sharedFolderLinkDraft)
            sharedFolderLinkDraft = folderSyncProfile.sharedFolderLink ?? sharedFolderLinkDraft
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshSharedFolderLink() {
        folderSyncProfile.refresh()
        if let syncedLink = folderSyncProfile.sharedFolderLink {
            sharedFolderLinkDraft = syncedLink
        }
    }

    private func forgetSharedFolderLink() {
        do {
            try folderSyncProfile.forgetSharedFolderLinkEverywhere()
            sharedFolderLinkDraft = ""
        } catch {
            errorMessage = error.localizedDescription
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

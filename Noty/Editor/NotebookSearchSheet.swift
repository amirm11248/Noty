import SwiftUI

struct NotebookSearchSheet: View {
    let documentID: UUID
    let store: NotyStore
    let onSelectPage: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var results: [NotySearchResult] { store.search(query: query).filter { $0.documentID == documentID } }
    var body: some View {
        NavigationStack {
            List {
                if store.isIndexingHandwriting {
                    HStack(spacing: 8) { ProgressView(); Text("Indexing handwriting…").font(.caption).foregroundStyle(.secondary) }
                }
                if let error = store.handwritingIndexError {
                    HStack { Text(error).font(.caption); Button("Retry") { store.ensureHandwritingSearchIndex(documentID: documentID) } }
                }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("Find in this notebook", systemImage: "magnifyingglass", description: Text("Search typed notes, handwriting, and PDF text."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(results) { result in
                        Button {
                            if let id = result.pageID { onSelectPage(id) }
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(pageTitle(result)).font(.headline)
                                Text(result.snippet).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.searchable(text: $query, prompt: "Search this notebook")
                .navigationTitle("Find in notebook").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { store.ensureHandwritingSearchIndex(documentID: documentID) }
    }
    private func pageTitle(_ result: NotySearchResult) -> String {
        guard let pageID = result.pageID,
              let index = store.documents.first(where: { $0.id == documentID })?.pages.firstIndex(where: { $0.id == pageID }) else { return "Notebook" }
        return "Page \(index + 1)"
    }
}

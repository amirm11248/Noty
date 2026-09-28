import Foundation

struct NotySearchResult: Identifiable, Hashable {
    let documentID: UUID
    let pageID: UUID?
    let documentTitle: String
    let snippet: String

    var id: String {
        "\(documentID.uuidString):\(pageID?.uuidString ?? "document"): \(snippet)"
    }
}

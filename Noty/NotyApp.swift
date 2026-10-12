import SwiftUI
import UIKit

@main
struct NotyApp: App {
    @State private var store = NotyStore()
    @State private var importAlertTitle = "Import"
    @State private var importAlertMessage: String?

    init() {
        NotyLocalStorage.removeLegacySettings()
        // Register the Inter resources before SwiftUI resolves shared theme fonts.
        NotionFontRegistrar.registerInter()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(store: store)
                .onOpenURL { url in
                    Task {
                        do {
                            _ = try await store.importDocument(from: url, folderID: nil, converter: nil)
                            if let message = store.lastOperationMessage {
                                importAlertTitle = "Import details"
                                importAlertMessage = message
                            }
                        } catch {
                            importAlertTitle = "Import failed"
                            importAlertMessage = error.localizedDescription
                        }
                    }
                }
                .alert(importAlertTitle, isPresented: Binding(
                    get: { importAlertMessage != nil },
                    set: { if !$0 { importAlertMessage = nil } }
                )) {
                    Button("OK") { importAlertMessage = nil }
                } message: {
                    Text(importAlertMessage ?? "The document could not be opened.")
                }
        }
    }
}

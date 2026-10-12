import PDFKit
import PencilKit
import Security
import UIKit
import XCTest
import WebKit
@testable import Noty

final class NotyLocalStorageTests: XCTestCase {
    func testUpgradeDiscardsLegacyCredentialsAndFolderSettings() throws {
        let suite = "NotyLocalOnlySettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("old bookmark".utf8), forKey: "noty.onedrive.folder.bookmark")
        defaults.set(["old-document": "old.pdf"], forKey: "noty.onedrive.mirrored-files.fixture")
        defaults.set("bottom", forKey: "noty.editor.toolbarDock")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.malik.noty.auth",
            kSecAttrAccount as String: "local-only-migration-fixture",
            kSecUseDataProtectionKeychain as String: true
        ]
        defer { SecItemDelete(query as CFDictionary) }
        var item = query
        item[kSecValueData as String] = Data("obsolete session fixture".utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)

        NotyLocalStorage.removeLegacySettings(defaults: defaults)
        XCTAssertNil(defaults.data(forKey: "noty.onedrive.folder.bookmark"))
        XCTAssertNil(defaults.dictionary(forKey: "noty.onedrive.mirrored-files.fixture"))
        XCTAssertEqual(defaults.string(forKey: "noty.editor.toolbarDock"), "bottom")
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
    }

    func testAppDeclaresNoMicrophonePermissionBackgroundTasksOrCollectedData() throws {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription"))
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes"))
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"))
        let privacyURL = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let privacy = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: privacyURL), format: nil) as? [String: Any])
        XCTAssertEqual((privacy["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(privacy["NSPrivacyTracking"] as? Bool, false)
    }

    @MainActor
    func testLibrarySearchFindsFolderNamePDFTextAndTypedAnnotation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotySearchQA-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NotyStore(storageDirectoryURL: root)
        store.createFolder(name: "Mathematics", parentID: nil)
        let folderID = try XCTUnwrap(store.folders.first?.id)
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "noty-qa", withExtension: "pdf", subdirectory: "Fixtures"
        ) ?? Bundle(for: Self.self).url(forResource: "noty-qa", withExtension: "pdf"))
        let document = try await store.importDocument(from: fixtureURL, folderID: folderID)
        defer { try? FileManager.default.removeItem(at: store.userImportsDirectoryURL(documentID: document.id)) }
        let pageID = try XCTUnwrap(document.pages.first?.id)
        store.updateTextBoxes(documentID: document.id, pageID: pageID, textBoxes: [
            NotyTextBox(text: "Quadratic formula annotation")
        ])

        XCTAssertTrue(store.search(query: "Mathematics").contains { $0.documentID == document.id })
        XCTAssertTrue(store.search(query: "Noty conversion check").contains { $0.pageID == pageID })
        XCTAssertTrue(store.search(query: "Quadratic formula").contains { $0.pageID == pageID })
    }

    @MainActor
    func testExistingLocalLibraryReopensWithoutRestoringLegacyFolderGrant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotyLocalOnly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let sentinel = external.appendingPathComponent("sentinel.txt")
        try Data("Keep this external file unchanged".utf8).write(to: sentinel)

        let original = NotyStore(storageDirectoryURL: library)
        let document = original.createDocument(title: "Local notebook", kind: .note, folderID: nil)
        let pageID = try XCTUnwrap(document.pages.first?.id)
        let boxes = [NotyTextBox(text: "Saved locally before the upgrade")]
        original.updateTextBoxes(documentID: document.id, pageID: pageID, textBoxes: boxes)
        let bookmark = try external.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        let bookmarkURL = library.appendingPathComponent("icloud-folder.bookmark")
        try bookmark.write(to: bookmarkURL)

        let reopened = NotyStore(storageDirectoryURL: library)
        XCTAssertNil(reopened.lastPersistenceError)
        XCTAssertEqual(reopened.documents.first?.pages.first?.textBoxes, boxes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookmarkURL.path))
        reopened.renameDocument(id: document.id, title: "Still local")
        // Allow the former automatic mirror debounce to elapse.
        try await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), ["sentinel.txt"])
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "Keep this external file unchanged")
        XCTAssertEqual(NotyStore(storageDirectoryURL: library).documents.first?.title, "Still local")
    }

    @MainActor
    func testLibraryAndAllExportTypesStayLocalAndAreExcludedFromBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotyLocalExport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        let document = store.createDocument(title: "Offline exports", kind: .note, folderID: nil)
        let pageID = try XCTUnwrap(document.pages.first?.id)
        let exports = try [
            NotyExportService.exportPDF(documentID: document.id, store: store),
            NotyExportService.exportPageImage(documentID: document.id, pageID: pageID, store: store)
        ]
        defer { for url in exports { try? FileManager.default.removeItem(at: url) } }
        let documents = try NotyLocalStorage.documentsDirectory()
        for url in exports {
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.deletingLastPathComponent(), documents.appendingPathComponent("Noty Exports", isDirectory: true))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let support = try NotyLocalStorage.applicationSupportDirectory()
        for directory in [root, support, documents, exports[0].deletingLastPathComponent()] {
            XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
    }

    func testLegacyRecordingMetadataDoesNotPreventNotebookOrTrashDecoding() throws {
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let document = NotyDocument(
            title: "Notebook from an older version",
            pages: [NotyPage(textBoxes: [NotyTextBox(text: "Keep these notes")])],
            createdAt: savedAt,
            updatedAt: savedAt,
            studyCards: [NotyStudyCard(question: "Question", answer: "Answer")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var legacyDocument = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any])
        legacyDocument["audioClips"] = [[
            "id": UUID().uuidString,
            "title": "Former recording",
            "fileName": "legacy.m4a",
            "duration": 10,
            "createdAt": savedAt.timeIntervalSince1970 * 1_000,
            "pageID": try XCTUnwrap(document.pages.first?.id).uuidString
        ]]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let reopened = try decoder.decode(NotyDocument.self, from: JSONSerialization.data(withJSONObject: legacyDocument))
        XCTAssertEqual(reopened, document)

        let legacyTrash: [String: Any] = [
            "document": legacyDocument,
            "deletedAt": savedAt.timeIntervalSince1970 * 1_000,
            "recoveryDirectoryName": "legacy-trash"
        ]
        let item = try decoder.decode(NotyTrashedDocument.self, from: JSONSerialization.data(withJSONObject: legacyTrash))
        XCTAssertEqual(item.document, document)
        XCTAssertEqual(item.recoveryDirectoryName, "legacy-trash")
        let savedDocument = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(reopened)) as? [String: Any])
        XCTAssertNil(savedDocument["audioClips"], "New saves must no longer contain recording metadata.")
    }

    @MainActor
    func testRemoteImportIsRejectedBeforeCreatingAnyDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotyRemoteImport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotyStore(storageDirectoryURL: root)
        do {
            _ = try await store.importDocument(from: XCTUnwrap(URL(string: "https://example.invalid/note.pdf")), folderID: nil)
            XCTFail("Remote URLs must be rejected before reading any bytes.")
        } catch NotyStoreError.localFileRequired {
            XCTAssertTrue(store.documents.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @MainActor
    func testWordRendererBlocksExternalResourcesWhileAllowingEmbeddedImages() async throws {
        let handler = LocalOnlyResourceProbe()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "noty-probe")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: configuration)
        let navigation = LocalOnlyNavigationObserver()
        webView.navigationDelegate = navigation
        try await navigation.load(html: DOCXPreviewPDFSession.html, in: webView)
        let result = try await webView.callAsyncJavaScript("""
            const imageLoaded = src => new Promise(resolve => {
              const image = new Image();
              image.onload = () => resolve(true);
              image.onerror = () => resolve(false);
              image.src = src;
              document.body.appendChild(image);
            });
            const remote = await imageLoaded('noty-probe://external/image.png');
            const embedded = await imageLoaded('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII=');
            let requestBlocked = false;
            try { await fetch('noty-probe://external/data'); } catch { requestBlocked = true; }
            return {remote, embedded, requestBlocked};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Bool]
        XCTAssertEqual(result?["remote"], false)
        XCTAssertEqual(result?["embedded"], true)
        XCTAssertEqual(result?["requestBlocked"], true)
        XCTAssertEqual(handler.requests, 0, "The policy must block requests before reaching a provider.")
    }
}

@MainActor
private final class LocalOnlyResourceProbe: NSObject, WKURLSchemeHandler {
    var requests = 0
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        requests += 1
        urlSchemeTask.didFailWithError(CocoaError(.fileReadNoSuchFile))
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { }
}

@MainActor
private final class LocalOnlyNavigationObserver: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

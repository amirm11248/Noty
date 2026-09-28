import Foundation
import Observation
import Security

/// Mirrors rendered PDFs into a folder the user selected from Files. Selecting
/// a OneDrive location works through the OneDrive File Provider, so the user
/// signs in with Microsoft's own app and Noty never handles credentials.
@MainActor
@Observable
final class OneDriveService {
    private(set) var isConnected = false
    private(set) var mirrorFolderName: String?
    private(set) var syncStatus = "Choose a OneDrive folder in Files to connect."
    private(set) var lastError: String?

    @ObservationIgnored private var mirrorFolderURL: URL?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var syncRequestedAgain = false

    private let bookmarkKey = "noty.onedrive.folder.bookmark"
    private let fileMapKeyPrefix = "noty.onedrive.mirrored-files."
    private let revisionsKeyPrefix = "noty.onedrive.document-revisions."

    init() {
        restoreFolderBookmark()
    }

    /// Keeps the API expected by the app root. The Files folder picker is
    /// presented by LibraryView; this method validates the persisted grant.
    func connect() async throws {
        guard let url = resolvedFolderURL() else {
            throw OneDriveError.folderSelectionRequired
        }
        try withFolderAccess(url) { _ in }
        isConnected = true
        mirrorFolderName = url.lastPathComponent
        syncStatus = "Folder selected: \(url.lastPathComponent)."
        lastError = nil
    }

    /// Persists the security-scoped folder selected through the Files picker.
    func configureMirrorFolder(folderURL: URL) throws {
        var accessError: Error?
        let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let values = try folderURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw OneDriveError.notAFolder
            }
            let bookmark = try Self.persistentFolderBookmark(for: folderURL)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            mirrorFolderURL = folderURL
            mirrorFolderName = folderURL.lastPathComponent
            isConnected = true
            lastError = nil
            syncStatus = "Folder selected: \(folderURL.lastPathComponent)."

        } catch {
            accessError = error
        }

        if let accessError {
            lastError = accessError.localizedDescription
            syncStatus = "Could not use the selected OneDrive folder."
            isConnected = false
            throw accessError
        }
    }

    /// Disconnecting removes Noty's saved folder grant. Files already written
    /// to OneDrive remain there.
    func disconnect() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        mirrorFolderURL = nil
        mirrorFolderName = nil
        isConnected = false
        lastError = nil
        syncStatus = "Choose a OneDrive folder in Files to connect."
    }

    /// Exports each note, book, and imported PDF to a stable PDF in the
    /// selected File Provider folder. Calls during a sync request one final
    /// pass so edits made during rendering are not missed.
    func syncAllPDFs(store: NotyStore) async {
        if isSyncing {
            syncRequestedAgain = true
            return
        }

        isSyncing = true
        repeat {
            syncRequestedAgain = false
            await performSync(store: store)
        } while syncRequestedAgain
        isSyncing = false
    }

    private func performSync(store: NotyStore) async {
        guard let folderURL = resolvedFolderURL() else {
            isConnected = false
            syncStatus = "Choose or re-select a OneDrive folder in Files."
            return
        }

        syncStatus = "Saving PDF copies to the selected Files folder…"
        lastError = nil
        isConnected = true
        mirrorFolderName = folderURL.lastPathComponent

        do {
            var syncErrors: [String] = []
            var syncedCount = 0
            var skippedCount = 0
            var hadRetainedCopies = false
            let documents = store.documents
            let documentIDs = Set(documents.map { $0.id.uuidString })
            let fileMapKey = folderMetadataKey(prefix: fileMapKeyPrefix, folderURL: folderURL)
            let revisionsKey = folderMetadataKey(prefix: revisionsKeyPrefix, folderURL: folderURL)
            var fileMap = UserDefaults.standard.dictionary(forKey: fileMapKey) as? [String: String] ?? [:]
            var revisions = UserDefaults.standard.dictionary(forKey: revisionsKey) as? [String: Double] ?? [:]

            try withFolderAccess(folderURL) { accessibleFolder in
                for document in documents {
                    let key = document.id.uuidString
                    let revision = document.updatedAt.timeIntervalSince1970

                    do {
                        let previousFileName = fileMap[key]
                        let fileName = Self.fileName(for: document)
                        let destination = accessibleFolder.appendingPathComponent(fileName, isDirectory: false)
                        let fileExists = FileManager.default.fileExists(atPath: destination.path)
                        if fileExists, revisions[key] == revision, previousFileName == fileName {
                            skippedCount += 1
                            continue
                        }

                        let renderedPDF = try NotyExportService.exportPDFForSync(
                            documentID: document.id,
                            store: store
                        )
                        let pdfData = try Data(contentsOf: renderedPDF)
                        try Self.coordinatedWrite(pdfData, to: destination)

                        var oldFileRemoved = true
                        if let oldName = previousFileName, oldName != fileName {
                            let oldURL = accessibleFolder.appendingPathComponent(oldName, isDirectory: false)
                            do {
                                try Self.coordinatedDelete(oldURL)
                            } catch {
                                oldFileRemoved = false
                                syncErrors.append("Could not remove the previous copy of \(document.title): \(error.localizedDescription)")
                            }
                        }
                        if oldFileRemoved {
                            fileMap[key] = fileName
                        }
                        revisions[key] = revision
                        syncedCount += 1
                    } catch {
                        syncErrors.append("\(document.title): \(error.localizedDescription)")
                    }
                }

                // Retire tracking for documents that have been deleted from
                // the library, but keep their exported PDFs as recoverable
                // copies in the user's Files folder.
                let obsoleteEntries = fileMap.filter { !documentIDs.contains($0.key) }
                hadRetainedCopies = !obsoleteEntries.isEmpty
                for (documentID, _) in obsoleteEntries {
                    fileMap.removeValue(forKey: documentID)
                    revisions.removeValue(forKey: documentID)
                }
            }

            UserDefaults.standard.set(fileMap, forKey: fileMapKey)
            UserDefaults.standard.set(revisions, forKey: revisionsKey)
            if syncErrors.isEmpty {
                lastError = nil
                if documents.isEmpty {
                    syncStatus = hadRetainedCopies
                        ? "No current documents. Previously saved PDF copies remain in the selected folder."
                        : "Folder selected. No PDFs to save yet; folder write access has not been tested."
                } else {
                    syncStatus = "PDF copies saved to selected folder · \(syncedCount) updated, \(skippedCount) unchanged."
                }
            } else {
                lastError = syncErrors.joined(separator: "\n")
                syncStatus = "Saved \(syncedCount) PDF cop\(syncedCount == 1 ? "y" : "ies") to the selected folder; \(syncErrors.count) had error\(syncErrors.count == 1 ? "" : "s")."
            }
            isConnected = true
        } catch {
            let description = Self.friendlyDescription(for: error)
            lastError = description
            syncStatus = description
            // A write/network failure does not revoke the saved Files grant.
            // Keep the folder selected so the user can retry manually.
            isConnected = mirrorFolderURL != nil
        }
    }

    private func resolvedFolderURL() -> URL? {
        if let mirrorFolderURL {
            return mirrorFolderURL
        }
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }

        do {
            let resolved = try Self.resolvePersistentFolderBookmark(bookmark)
            let url = resolved.url
            mirrorFolderURL = url
            mirrorFolderName = url.lastPathComponent
            if resolved.isStale {
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let refreshedBookmark = try Self.persistentFolderBookmark(for: url)
                UserDefaults.standard.set(refreshedBookmark, forKey: bookmarkKey)
            }
            return url
        } catch {
            mirrorFolderURL = nil
            mirrorFolderName = nil
            isConnected = false
            lastError = "Selected Files folder access expired. Re-select the folder in Files."
            syncStatus = lastError ?? "OneDrive folder access expired."
            return nil
        }
    }

    private func restoreFolderBookmark() {
        guard let url = resolvedFolderURL() else { return }
        mirrorFolderName = url.lastPathComponent
        isConnected = true
        syncStatus = "Folder selected: \(url.lastPathComponent)."
    }

    private func withFolderAccess<T>(_ folderURL: URL, body: (URL) throws -> T) throws -> T {
        let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try folderURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw OneDriveError.notAFolder
        }
        return try body(folderURL)
    }

    private func folderMetadataKey(prefix: String, folderURL: URL) -> String {
        prefix + folderURL.standardizedFileURL.path
    }

    /// On iOS, persist the directory-picker grant as a minimal bookmark so a
    /// File Provider folder (including OneDrive) can be reopened after relaunch.
    private static func persistentFolderBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func resolvePersistentFolderBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private static func coordinatedDelete(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var deletionError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                deletionError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let deletionError { throw deletionError }
    }

    private static func fileName(for document: NotyDocument) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let cleaned = document.title
            .components(separatedBy: disallowed)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))
        return "\(title) · \(document.id.uuidString.prefix(8)).pdf"
    }

    private static func friendlyDescription(for error: Error) -> String {
        if let error = error as? OneDriveError {
            return error.localizedDescription
        }
        return "The selected Files folder could not be reached. Re-select it if access expired. \(error.localizedDescription)"
    }
}

private enum OneDriveError: LocalizedError {
    case folderSelectionRequired
    case notAFolder

    var errorDescription: String? {
        switch self {
        case .folderSelectionRequired:
            return "Choose a writable OneDrive folder in Files to connect."
        case .notAFolder:
            return "The selected location is not a folder. Choose a OneDrive folder in Files."
        }
    }
}



// MARK: - Noty account backend

/// Real account + backend profile service.
///
/// Authentication is handled by Supabase Auth. Only the public/anonymous
/// client key is bundled in the app; every profile request also carries the
/// signed-in user's JWT, and Postgres Row Level Security restricts rows to
/// auth.uid() == user_id.
///
/// The backend stores discovery metadata (currently the iCloud sharing URL and
/// selected folder name), never the iOS security-scoped directory bookmark.
/// Apple intentionally makes that Files permission local to each device.
@MainActor
@Observable
final class NotyAccountService {
    private(set) var isAuthenticated = false
    private(set) var email: String?
    private(set) var sharedFolderLink: String?
    private(set) var folderDisplayName: String?
    private(set) var status = "Sign in to sync your workspace setup across devices."
    private(set) var lastError: String?
    private(set) var isWorking = false

    @ObservationIgnored private var session: StoredSession?
    @ObservationIgnored private var didBootstrap = false

    private static let backendURL = URL(string: "https://diwtlxvlpiyeownljjpz.supabase.co")!
    // Supabase publishable/anon client keys are public application identifiers.
    // Authorization is enforced by the user's JWT + database RLS, never by this key.
    private static let publicClientKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRpd3RseHZscGl5ZW93bmxqanB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTc2MzMzNDMsImV4cCI6MjA3MzMzOTM0M30.A-c0ylufHucKDTuxt5ykiVHjl03cPSzDwYomdaweyNk"
    private let keychainService = "com.malik.noty.auth"
    private let keychainAccount = "supabase-session"

    init() {
        session = loadStoredSession()
        if let session {
            email = session.email
            isAuthenticated = true
            status = "Restoring your Noty account…"
        }
    }

    var sharedFolderURL: URL? {
        guard let sharedFolderLink else { return nil }
        return URL(string: sharedFolderLink)
    }

    func bootstrap(force: Bool = false) async {
        if didBootstrap && !force { return }
        didBootstrap = true
        guard session != nil else {
            isAuthenticated = false
            status = "Sign in to sync your workspace setup across devices."
            return
        }

        await run {
            try await refreshSession()
            try await loadSyncProfile()
            status = "Signed in as \(email ?? "Noty user")."
        }
    }

    func signIn(email rawEmail: String, password: String) async throws {
        let normalizedEmail = try Self.normalizedEmail(rawEmail)
        try Self.validatePassword(password)
        try await runThrowing {
            let body: [String: Any] = ["email": normalizedEmail, "password": password]
            let data = try await authRequest(
                path: "/auth/v1/token?grant_type=password",
                method: "POST",
                jsonBody: body
            )
            let newSession = try Self.decodeAuthSession(data, fallbackEmail: normalizedEmail)
            try persist(newSession)
            session = newSession
            email = newSession.email
            isAuthenticated = true
            try await loadSyncProfile()
            status = "Signed in as \(newSession.email)."
        }
    }

    func signUp(email rawEmail: String, password: String) async throws {
        let normalizedEmail = try Self.normalizedEmail(rawEmail)
        try Self.validatePassword(password)
        try await runThrowing {
            let body: [String: Any] = ["email": normalizedEmail, "password": password]
            let data = try await authRequest(path: "/auth/v1/signup", method: "POST", jsonBody: body)

            if let newSession = try? Self.decodeAuthSession(data, fallbackEmail: normalizedEmail) {
                try persist(newSession)
                session = newSession
                email = newSession.email
                isAuthenticated = true
                try await loadSyncProfile()
                status = "Account created and signed in as \(newSession.email)."
            } else {
                clearLocalSession()
                email = normalizedEmail
                status = "Account created. Check \(normalizedEmail) for the confirmation email, then sign in."
            }
        }
    }

    func signOut() async {
        isWorking = true
        defer { isWorking = false }

        if let accessToken = session?.accessToken {
            var request = baseRequest(path: "/auth/v1/logout", method: "POST")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
        clearLocalSession()
        sharedFolderLink = nil
        folderDisplayName = nil
        status = "Signed out. Your local notes and selected Files folder remain on this device."
        lastError = nil
    }

    func refreshProfile() async {
        guard isAuthenticated else { return }
        await run {
            try await loadSyncProfile()
            status = "Account sync settings refreshed."
        }
    }

    /// Saves account-level discovery metadata in Postgres. Passing an empty link
    /// clears it, which is useful when a user wants to keep the workspace private.
    func saveSyncProfile(sharedFolderLink rawLink: String?, folderDisplayName rawFolderName: String?) async throws {
        guard let session else { throw NotyAccountError.notSignedIn }
        let normalizedLink = try Self.normalizedSharedFolderLink(rawLink)
        let folderName = rawFolderName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        try await runThrowing {
            let body: [String: Any] = [
                "user_id": session.userID,
                "icloud_share_url": normalizedLink ?? NSNull(),
                "folder_display_name": folderName ?? NSNull(),
                "sync_mode": "folder",
                "updated_at": ISO8601DateFormatter().string(from: .now)
            ]
            var request = baseRequest(
                path: "/rest/v1/noty_sync_profiles?on_conflict=user_id",
                method: "POST"
            )
            request.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let data = try await authorizedData(request)
            let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            if let row = rows?.first {
                applyProfile(row)
            } else {
                sharedFolderLink = normalizedLink
                folderDisplayName = folderName
            }
            status = "Workspace setup saved to your Noty account."
        }
    }

    func clearSharedFolderLink() async throws {
        try await saveSyncProfile(sharedFolderLink: nil, folderDisplayName: folderDisplayName)
    }

    private func loadSyncProfile() async throws {
        guard let session else { throw NotyAccountError.notSignedIn }
        let encodedUserID = session.userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session.userID
        let path = "/rest/v1/noty_sync_profiles?select=user_id,icloud_share_url,folder_display_name,sync_mode,updated_at&user_id=eq.\(encodedUserID)&limit=1"
        let request = baseRequest(path: path, method: "GET")
        let data = try await authorizedData(request)
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        if let row = rows.first {
            applyProfile(row)
        } else {
            sharedFolderLink = nil
            folderDisplayName = nil
        }
    }

    private func applyProfile(_ row: [String: Any]) {
        sharedFolderLink = (row["icloud_share_url"] as? String)?.nilIfEmpty
        folderDisplayName = (row["folder_display_name"] as? String)?.nilIfEmpty
    }

    private func refreshSession() async throws {
        guard let existing = session else { throw NotyAccountError.notSignedIn }
        let data = try await authRequest(
            path: "/auth/v1/token?grant_type=refresh_token",
            method: "POST",
            jsonBody: ["refresh_token": existing.refreshToken]
        )
        let refreshed = try Self.decodeAuthSession(data, fallbackEmail: existing.email)
        try persist(refreshed)
        session = refreshed
        email = refreshed.email
        isAuthenticated = true
    }

    private func authorizedData(_ originalRequest: URLRequest) async throws -> Data {
        guard var session else { throw NotyAccountError.notSignedIn }

        var request = originalRequest
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotyAccountError.invalidResponse }

        if http.statusCode == 401 {
            try await refreshSession()
            guard let refreshed = self.session else { throw NotyAccountError.notSignedIn }
            session = refreshed
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: request)
            guard let retryHTTP = response as? HTTPURLResponse else { throw NotyAccountError.invalidResponse }
            guard (200..<300).contains(retryHTTP.statusCode) else {
                throw NotyAccountError.server(Self.serverMessage(data: data, statusCode: retryHTTP.statusCode))
            }
            return data
        }

        guard (200..<300).contains(http.statusCode) else {
            throw NotyAccountError.server(Self.serverMessage(data: data, statusCode: http.statusCode))
        }
        return data
    }

    private func authRequest(path: String, method: String, jsonBody: [String: Any]) async throws -> Data {
        var request = baseRequest(path: path, method: method)
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotyAccountError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw NotyAccountError.server(Self.serverMessage(data: data, statusCode: http.statusCode))
        }
        return data
    }

    private func baseRequest(path: String, method: String) -> URLRequest {
        let url = URL(string: path, relativeTo: Self.backendURL)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue(Self.publicClientKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func run(_ operation: () async throws -> Void) async {
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            lastError = error.localizedDescription
            status = "Account sync needs attention."
        }
    }

    private func runThrowing(_ operation: () async throws -> Void) async throws {
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            lastError = error.localizedDescription
            status = "Account sync needs attention."
            throw error
        }
    }

    private func persist(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else {
                throw NotyAccountError.keychain(Self.keychainMessage(result))
            }
        } else if update != errSecSuccess {
            throw NotyAccountError.keychain(Self.keychainMessage(update))
        }
    }

    private func loadStoredSession() -> StoredSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    private func clearLocalSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
        session = nil
        email = nil
        isAuthenticated = false
    }

    private struct StoredSession: Codable {
        var accessToken: String
        var refreshToken: String
        var userID: String
        var email: String
    }

    private static func decodeAuthSession(_ data: Data, fallbackEmail: String) throws -> StoredSession {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotyAccountError.invalidResponse
        }

        let sessionObject = (root["session"] as? [String: Any]) ?? root
        guard
            let accessToken = sessionObject["access_token"] as? String,
            !accessToken.isEmpty,
            let refreshToken = sessionObject["refresh_token"] as? String,
            !refreshToken.isEmpty
        else {
            throw NotyAccountError.emailConfirmationRequired
        }

        let user = (sessionObject["user"] as? [String: Any]) ?? (root["user"] as? [String: Any])
        guard let userID = user?["id"] as? String, !userID.isEmpty else {
            throw NotyAccountError.invalidResponse
        }
        let email = (user?["email"] as? String)?.nilIfEmpty ?? fallbackEmail
        return StoredSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userID: userID,
            email: email
        )
    }

    private static func normalizedEmail(_ raw: String) throws -> String {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.contains("."), email.count <= 254 else {
            throw NotyAccountError.invalidEmail
        }
        return email
    }

    private static func validatePassword(_ password: String) throws {
        guard password.count >= 8 else { throw NotyAccountError.weakPassword }
    }

    private static func normalizedSharedFolderLink(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "https",
            url.host != nil
        else {
            throw NotyAccountError.invalidFolderLink
        }
        return url.absoluteString
    }

    private static func serverMessage(data: Data, statusCode: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["msg", "message", "error_description", "error"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
        }
        return "Backend request failed (HTTP \(statusCode))."
    }

    private static func keychainMessage(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

private enum NotyAccountError: LocalizedError {
    case notSignedIn
    case invalidEmail
    case weakPassword
    case invalidFolderLink
    case invalidResponse
    case emailConfirmationRequired
    case server(String)
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to your Noty account first."
        case .invalidEmail:
            return "Enter a valid email address."
        case .weakPassword:
            return "Use a password with at least 8 characters."
        case .invalidFolderLink:
            return "Enter a valid HTTPS iCloud/shared-folder link."
        case .invalidResponse:
            return "Noty's account server returned an invalid response."
        case .emailConfirmationRequired:
            return "Check your email to confirm the account, then sign in."
        case .server(let message):
            return message
        case .keychain(let message):
            return "Noty could not save your sign-in securely: \(message)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

import Foundation
import Security

/// All app-owned documents stay in the device's sandbox and out of system backups.
enum NotyLocalStorage {
    static func prepareDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var directory = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    static func documentsDirectory() throws -> URL {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        try prepareDirectory(at: directory)
        return directory
    }

    static func applicationSupportDirectory() throws -> URL {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Cover legacy export caches outside the current Noty library as well.
        try prepareDirectory(at: directory)
        return directory
    }

    /// Discard credentials and folder grants left by an older installed version.
    /// This only touches local settings; it never contacts a server or opens a provider.
    static func removeLegacySettings(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("noty.onedrive.") {
            defaults.removeObject(forKey: key)
        }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.malik.noty.auth",
            kSecUseDataProtectionKeychain as String: true
        ] as CFDictionary)
    }
}

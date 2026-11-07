import Foundation

/// File-system locations for disposable cache files only.
/// Canonical app records are stored by AppDatabase; preferences by
/// AppPreferences; secrets by KeychainStore.
enum AppDataStore {
    static func cachesDirectory(named name: String) throws -> URL {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

import Foundation

/// The single persistence gateway for app-owned data.
///
/// Existing storage keys and file names are intentionally preserved so this
/// layer can be introduced without resetting any user's library or settings.
/// Feature stores should use this API instead of accessing UserDefaults or
/// encoding JSON files independently.
enum AppDataStore {
    static func data(forKey key: String) -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    static func string(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func date(forKey key: String) -> Date? {
        UserDefaults.standard.object(forKey: key) as? Date
    }

    static func set(_ value: Any?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func removeValue(forKey key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func encode<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, forKey: key)
    }

    /// Loads a durable dataset from Application Support, migrating its legacy UserDefaults value once.
    static func loadPersistent<Value: Codable>(
        _ type: Value.Type,
        fileName: String,
        legacyKey: String
    ) -> Value? {
        guard let url = try? applicationSupportURL(directory: "data", fileName: fileName) else {
            return decode(type, forKey: legacyKey)
        }
        if let saved = readJSON(type, from: url) { return saved }
        guard let legacy = decode(type, forKey: legacyKey) else { return nil }
        if writeJSON(legacy, to: url) {
            removeValue(forKey: legacyKey)
        }
        return legacy
    }

    @discardableResult
    static func savePersistent<Value: Encodable>(_ value: Value, fileName: String) -> Bool {
        guard let url = try? applicationSupportURL(directory: "data", fileName: fileName) else { return false }
        return writeJSON(value, to: url)
    }

    static func readJSON<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func applicationSupportURL(directory name: String, fileName: String) throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = base.appendingPathComponent("itchPocket", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    static func cachesDirectory(named name: String) throws -> URL {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func cachesURL(directory name: String, fileName: String) throws -> URL {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = base.appendingPathComponent("itchPocket", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }
}

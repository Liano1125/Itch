import Foundation

/// Small access layer for non-sensitive user preferences. Durable app data
/// belongs in SwiftData; credentials belong in Keychain; rebuildable files
/// belong in Caches.
enum AppPreferences {
    static func string(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func set(_ value: String?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

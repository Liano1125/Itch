import Foundation
import CryptoKit

actor TranslationCache {
    static let shared = TranslationCache()

    struct Entry: Codable {
        let translation: String
        let sourceText: String
        let scope: String
        let target: String
        let updatedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var hasLoaded = false
    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("itchPocket", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("translation-cache-v1.json")
    }()

    func translation(for key: String) -> Entry? {
        loadIfNeeded()
        return entries[key]
    }

    func latest(scope: String, target: String) -> Entry? {
        loadIfNeeded()
        return entries.values
            .filter { $0.scope == scope && $0.target == target }
            .max { $0.updatedAt < $1.updatedAt }
    }

    func store(_ translation: String, source: String, scope: String, target: String, for key: String) {
        loadIfNeeded()
        entries[key] = Entry(
            translation: translation,
            sourceText: source,
            scope: scope,
            target: target,
            updatedAt: Date()
        )
        if entries.count > 1200 {
            let retained = entries.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(1000)
            entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
        save()
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum TranslationCacheKey {
    static func make(scope: String, source: String, target: String) -> String {
        let input = "\(scope)|\(target)|\(source)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

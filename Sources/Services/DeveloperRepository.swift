import Foundation
import SwiftData

/// Canonical persistence boundary for itch.io developer identities and shared
/// creator profile metadata. Game records refer to developers by stable ID.
struct StoredDeveloper: Equatable {
    let id: String
    let name: String
    let profileURL: String?
    let patreonURL: String?
    let discordURL: String?
    let avatarURL: String?
    let avatarSource: String?
    let avatarResolvedAt: Date?
    let updatedAt: Date
}

@MainActor
final class DeveloperRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func developer(id: String) throws -> StoredDeveloper? {
        let developerID = id
        let descriptor = FetchDescriptor<DBDeveloper>(
            predicate: #Predicate { $0.id == developerID }
        )
        return try database.repositoryContext.fetch(descriptor).first.map(Self.snapshot)
    }

    func loadByID() throws -> [String: StoredDeveloper] {
        let rows = try database.repositoryContext.fetch(FetchDescriptor<DBDeveloper>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, Self.snapshot($0)) })
    }

    /// Updates only supplied identity fields. Nil optional values preserve
    /// existing profile metadata, matching the former AppDatabase behavior.
    func upsertIdentity(
        id: String,
        name: String,
        profileURL: String? = nil,
        patreonURL: String? = nil,
        discordURL: String? = nil,
        save: Bool = true
    ) throws {
        let context = database.repositoryContext
        let developerID = id
        let descriptor = FetchDescriptor<DBDeveloper>(
            predicate: #Predicate { $0.id == developerID }
        )
        let item = try context.fetch(descriptor).first ?? DBDeveloper(id: id, name: name)
        var changed = item.modelContext == nil
        if item.modelContext == nil { context.insert(item) }
        if !name.isEmpty && item.name != name { item.name = name; changed = true }
        if let profileURL, item.profileURL != profileURL { item.profileURL = profileURL; changed = true }
        if let patreonURL, item.patreonURL != patreonURL { item.patreonURL = patreonURL; changed = true }
        if let discordURL, item.discordURL != discordURL { item.discordURL = discordURL; changed = true }
        if changed { item.updatedAt = .now }
        if save { try database.save() }
    }

    /// Persists a Patreon creator URL verified from the canonical primary author's profile.
    /// Passing nil is intentionally unsupported so transient scrape failures never erase identity.
    func setPatreonURL(id: String, url: String, save: Bool = true) throws {
        let context = database.repositoryContext
        let developerID = id
        let descriptor = FetchDescriptor<DBDeveloper>(
            predicate: #Predicate { $0.id == developerID }
        )
        guard let item = try context.fetch(descriptor).first else { return }
        guard item.patreonURL != url else { return }
        item.patreonURL = url
        item.updatedAt = .now
        if save { try database.save() }
    }

    /// Updates the shared avatar cache. Pass resolvedAt to record a completed
    /// resolution attempt; omit it when changing profile presentation only.
    func setAvatar(
        id: String,
        url: String?,
        source: String?,
        resolvedAt: Date? = nil,
        save: Bool = true
    ) throws {
        let context = database.repositoryContext
        let developerID = id
        let descriptor = FetchDescriptor<DBDeveloper>(
            predicate: #Predicate { $0.id == developerID }
        )
        guard let item = try context.fetch(descriptor).first else { return }
        let changed = item.avatarURL != url || item.avatarSource != source
        item.avatarURL = url
        item.avatarSource = source
        if let resolvedAt { item.avatarResolvedAt = resolvedAt }
        if changed { item.updatedAt = .now }
        if save { try database.save() }
    }

    func invalidateAvatarCaches(save: Bool = true) throws {
        let developers = try database.repositoryContext.fetch(FetchDescriptor<DBDeveloper>())
        for developer in developers {
            developer.avatarURL = nil
            developer.avatarSource = nil
            developer.avatarResolvedAt = nil
        }
        if save { try database.save() }
    }

    nonisolated static func canonicalID(for rawURL: String) -> String {
        // Normalize the scheme before parsing so Foundation accepts mixed-case
        // inputs such as HTTPS://... while preserving case-sensitive path data.
        let normalizedInput: String
        if let separator = rawURL.range(of: "://") {
            normalizedInput = rawURL[..<separator.lowerBound].lowercased()
                + rawURL[separator.lowerBound...]
        } else {
            normalizedInput = rawURL
        }

        guard var components = URLComponents(string: normalizedInput) else {
            return rawURL.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? rawURL.lowercased()
    }

    private static func snapshot(_ row: DBDeveloper) -> StoredDeveloper {
        StoredDeveloper(
            id: row.id,
            name: row.name,
            profileURL: row.profileURL,
            patreonURL: row.patreonURL,
            discordURL: row.discordURL,
            avatarURL: row.avatarURL,
            avatarSource: row.avatarSource,
            avatarResolvedAt: row.avatarResolvedAt,
            updatedAt: row.updatedAt
        )
    }
}

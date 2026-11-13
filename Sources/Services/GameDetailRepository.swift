import Foundation
import SwiftData

/// The detail cache still uses DBGame's legacy columns in this phase.
/// GameRepository owns those columns; this repository owns detail semantics
/// and the associated fetch-status AppState keys.
@MainActor
final class GameDetailRepository {
    static let shared = GameDetailRepository(database: .shared)

    private let database: AppDatabase
    private let gameRepository: GameRepository
    private let appStateRepository: AppStateRepository
    private let saveChanges: () throws -> Void

    private let fetchDatePrefix = "gameDetail.lastSuccessfulFetch."
    private let fetchStatusPrefix = "gameDetail.fetchStatus."
    private let legacyPrefetchDatePrefix = "detailPrefetch.lastSuccess."

    init(database: AppDatabase, saveChanges: (() throws -> Void)? = nil) {
        self.database = database
        self.gameRepository = GameRepository(database: database)
        self.appStateRepository = AppStateRepository(database: database)
        self.saveChanges = saveChanges ?? { try database.save() }
    }

    func detail(for gameID: String) throws -> GameDetailRecord? {
        let row = try fetchDetailRow(gameID: gameID)
        let gameExists = try gameRepository.game(id: gameID) != nil
        guard row != nil || gameExists else { return nil }
        let statusValue = try appStateRepository.state(for: fetchStatusPrefix + gameID)?.stringValue
        let currentFetchDate = try appStateRepository.state(for: fetchDatePrefix + gameID)?.dateValue
        let legacyFetchDate = try appStateRepository.state(for: legacyPrefetchDatePrefix + gameID)?.dateValue

        return GameDetailRecord(
            description: row?.descriptionText,
            galleryURLs: row?.galleryURLs ?? [],
            discoveryTags: Self.decodeTags(row?.discoveryTagsData) ?? [],
            fetchedAt: row?.fetchedAt ?? currentFetchDate ?? legacyFetchDate,
            fetchStatus: GameDetailFetchStatus(rawValue: statusValue ?? "") ?? (row?.isComplete == true ? .complete : .unknown)
        )
    }

    nonisolated static func resolvedDeveloperName(
        incoming: String?,
        existing: String?,
        library: String?
    ) -> String? {
        func usable(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.caseInsensitiveCompare("itch.io 开发者") != .orderedSame else {
                return nil
            }
            return trimmed
        }
        return usable(incoming) ?? usable(existing) ?? usable(library)
    }

    func discoveryTags(for gameID: String) throws -> [LibraryDiscoveryTag]? {
        guard let row = try fetchDetailRow(gameID: gameID) else { return nil }
        return Self.decodeTags(row.discoveryTagsData)
    }

    func applyPartialUpdate(
        _ update: GameDetailPartialUpdate,
        for gameID: String,
        save shouldSave: Bool = true
    ) throws {
        guard try gameRepository.game(id: gameID) != nil else { return }
        let statusKey = fetchStatusPrefix + gameID
        let stateSnapshots = try captureStates(for: [statusKey])
        let existingRow = try fetchDetailRow(gameID: gameID)
        let row = existingRow ?? DBGameDetail(gameID: gameID)
        if existingRow == nil { database.repositoryContext.insert(row) }
        let original = DetailSnapshot(row)

        do {
            row.descriptionText = GameDetailPersistencePolicy.resolvedValue(
                existing: row.descriptionText,
                incoming: update.description,
                mode: .partial
            )
            if let galleryURLs = GameDetailPersistencePolicy.resolvedValue(
                existing: Optional(row.galleryURLs),
                incoming: update.galleryURLs,
                mode: .partial
            ) {
                row.galleryURLs = galleryURLs
            }
            let existingTags = Self.decodeTags(row.discoveryTagsData)
            if let discoveryTags = GameDetailPersistencePolicy.resolvedValue(
                existing: existingTags,
                incoming: update.discoveryTags,
                mode: .partial
            ) {
                row.discoveryTagsData = try JSONEncoder().encode(discoveryTags)
            }

            if update.description != nil || update.galleryURLs != nil || update.discoveryTags != nil {
                let existingStatus = try appStateRepository.state(for: statusKey)?.stringValue
                if existingStatus == nil {
                    try appStateRepository.setString(GameDetailFetchStatus.partial.rawValue, for: statusKey, clearOtherValues: true, save: false)
                }
            }
            if shouldSave { try commit() }
        } catch {
            if existingRow == nil {
                database.repositoryContext.delete(row)
            } else {
                original.restore(to: row)
            }
            restoreStates(stateSnapshots)
            throw error
        }
    }

    @discardableResult
    func applyPageSnapshot(
        _ snapshot: GameDetailPageSnapshot,
        for gameID: String,
        fetchedAt: Date = .now
    ) throws -> GameDetailFetchStatus {
        guard try gameRepository.game(id: gameID) != nil else { return .unknown }

        let statusKey = fetchStatusPrefix + gameID
        let dateKey = fetchDatePrefix + gameID
        let stateSnapshots = try captureStates(for: [statusKey, dateKey])
        let existingRow = try fetchDetailRow(gameID: gameID)
        let row = existingRow ?? DBGameDetail(gameID: gameID)
        if existingRow == nil { database.repositoryContext.insert(row) }
        let original = DetailSnapshot(row)

        do {
            if snapshot.descriptionResolved { row.descriptionText = snapshot.description }
            if snapshot.galleryResolved { row.galleryURLs = snapshot.galleryURLs }
            if snapshot.tagsResolved {
                row.discoveryTagsData = try JSONEncoder().encode(snapshot.discoveryTags)
            }
            if snapshot.isComplete {
                row.fetchedAt = fetchedAt
                row.isComplete = true
            }

            if snapshot.isComplete {
                try appStateRepository.setDate(fetchedAt, for: dateKey, clearOtherValues: true, save: false)
                try appStateRepository.setString(GameDetailFetchStatus.complete.rawValue, for: statusKey, clearOtherValues: true, save: false)
            } else {
                let existingStatus = try appStateRepository.state(for: statusKey)?.stringValue
                if existingStatus == nil || existingStatus == GameDetailFetchStatus.unknown.rawValue {
                    try appStateRepository.setString(GameDetailFetchStatus.partial.rawValue, for: statusKey, clearOtherValues: true, save: false)
                }
            }

            try commit()
            return snapshot.isComplete ? .complete : .partial
        } catch {
            if existingRow == nil {
                database.repositoryContext.delete(row)
            } else {
                original.restore(to: row)
            }
            restoreStates(stateSnapshots)
            throw error
        }
    }

    private func fetchDetailRow(gameID: String) throws -> DBGameDetail? {
        let descriptor = FetchDescriptor<DBGameDetail>(
            predicate: #Predicate { $0.gameID == gameID }
        )
        return try database.repositoryContext.fetch(descriptor).first
    }

    private static func decodeTags(_ data: Data?) -> [LibraryDiscoveryTag]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([LibraryDiscoveryTag].self, from: data)
    }

    private func commit() throws { try saveChanges() }

    private struct DetailSnapshot {
        let descriptionText: String?
        let galleryURLs: [String]
        let discoveryTagsData: Data?
        let fetchedAt: Date?
        let isComplete: Bool

        init(_ row: DBGameDetail) {
            descriptionText = row.descriptionText
            galleryURLs = row.galleryURLs
            discoveryTagsData = row.discoveryTagsData
            fetchedAt = row.fetchedAt
            isComplete = row.isComplete
        }

        func restore(to row: DBGameDetail) {
            row.descriptionText = descriptionText
            row.galleryURLs = galleryURLs
            row.discoveryTagsData = discoveryTagsData
            row.fetchedAt = fetchedAt
            row.isComplete = isComplete
        }
    }

    private struct StateSnapshot {
        let key: String
        let state: StoredAppState?
    }

    private func captureStates(for keys: [String]) throws -> [StateSnapshot] {
        try keys.map { key in
            StateSnapshot(key: key, state: try appStateRepository.state(for: key))
        }
    }

    private func restoreStates(_ snapshots: [StateSnapshot]) {
        for snapshot in snapshots {
            try? appStateRepository.restore(snapshot.state, for: snapshot.key)
        }
    }
}
struct GameDetailRecord {
    let description: String?
    let galleryURLs: [String]
    let discoveryTags: [LibraryDiscoveryTag]
    let fetchedAt: Date?
    let fetchStatus: GameDetailFetchStatus
}

enum GameDetailFetchStatus: String, Equatable {
    case unknown
    case partial
    case complete
}

struct GameDetailPartialUpdate {
    var description: String? = nil
    var galleryURLs: [String]? = nil
    var discoveryTags: [LibraryDiscoveryTag]? = nil
}

struct GameDetailPageSnapshot {
    let description: String?
    let descriptionResolved: Bool
    let galleryURLs: [String]
    let galleryResolved: Bool
    let discoveryTags: [LibraryDiscoveryTag]
    let tagsResolved: Bool

    var isComplete: Bool {
        GameDetailSnapshotPolicy.hasRequiredDescription(descriptionResolved: descriptionResolved)
    }
}

enum GameDescriptionContentPolicy {
    /// Keeps the game-facing introduction while omitting common itch.io auxiliary
    /// sections such as author promotion, installation help, translation notices,
    /// featured mods, and comment/security notices.
    static func cleaned(_ source: String?) -> String? {
        guard let source else { return nil }
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)
        let excludedHeadings: Set<String> = [
            "about me", "关于我",
            "android installation", "android install", "安卓安装", "安卓安装指南",
            "about translations", "translations", "translation", "关于翻译", "关于翻译声明",
            "featured mods", "featured mod", "精选模组", "精选插件",
            "comments section", "comments", "评论区", "评论",
            "support the game", "support development", "支持开发", "支持游戏",
            "credits", "鸣谢"
        ]
        let includedHeadings: Set<String> = [
            "welcome", "plot", "story", "synopsis", "overview",
            "about the game", "the game", "gameplay", "features",
            "description", "剧情", "故事", "游戏介绍", "游戏简介",
            "玩法", "游戏特色", "简介"
        ]
        let allSectionHeadings = excludedHeadings.union(includedHeadings)

        func normalizedHeading(_ line: String) -> String {
            line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":："))
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
        }

        var output: [String] = []
        var skippingSection = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                if !skippingSection, output.last != "" { output.append("") }
                continue
            }

            let compact = line.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
            if compact.count >= 4 && compact.allSatisfy({ $0 == "_" || $0 == "-" || $0 == "—" || $0 == "–" || $0 == "=" }) {
                continue
            }

            let heading = normalizedHeading(line)
            if allSectionHeadings.contains(heading) {
                skippingSection = excludedHeadings.contains(heading)
                if !skippingSection { output.append(line) }
                continue
            }

            if !skippingSection {
                // Drop a leading creator-support link row, but preserve actual
                // description text that merely mentions these services later.
                let upper = line.uppercased()
                if output.isEmpty,
                   upper.contains("PATREON"),
                   (upper.contains("SUBSCRIBESTAR") || upper.contains("SUBSCRIBE STAR")) {
                    continue
                }
                output.append(line)
            }
        }

        let result = output.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? source.trimmingCharacters(in: .whitespacesAndNewlines) : result
    }
}

enum GameDetailSnapshotPolicy {
    static func resolvedValue<Value>(
        existing: Value?,
        incoming: Value?,
        isResolved: Bool
    ) -> Value? {
        isResolved ? incoming : existing
    }

    /// A successfully parsed game description is the required detail payload.
    /// Gallery and discovery tags are optional on itch.io and must not keep an
    /// otherwise valid page in the partial/retry state when those sections are absent.
    static func hasRequiredDescription(descriptionResolved: Bool) -> Bool {
        descriptionResolved
    }
}

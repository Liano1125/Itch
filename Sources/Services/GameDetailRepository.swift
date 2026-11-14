import Foundation
import SwiftData

enum GameDeveloperReferencePolicy {
    static func resolvedID(
        candidateID: String?,
        hasUsableName: Bool,
        existingDeveloperExists: Bool
    ) -> String? {
        guard let candidateID,
              !candidateID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return hasUsableName || existingDeveloperExists ? candidateID : nil
    }
}


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
    /// Keeps the player-facing introduction while removing page furniture and
    /// auxiliary sections commonly mixed into creator-authored descriptions.
    /// Unknown headings and paragraphs remain visible so unusual game pages do
    /// not lose story or gameplay information just because their wording differs.
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
            "support the game", "support development", "support the project",
            "support the creator", "support us", "支持开发", "支持游戏",
            "credits", "鸣谢",
            "changelog", "change log", "version history", "update history",
            "updates", "latest updates", "devlog", "development log", "更新日志", "更新记录",
            "download", "downloads", "download instructions", "get the game",
            "files", "system requirements", "requirements", "installation",
            "controls", "faq", "known issues", "not planned content",
            "planned content", "gallery", "more posts", "recent posts",
            "what's next", "whats next", "next update", "languages",
            "community", "links", "follow me", "follow us", "patreon", "discord", "join discord", "social links",
            "下载", "下载说明", "系统需求", "已知问题", "后续计划", "更多动态"
        ]
        let includedHeadings: Set<String> = [
            "welcome", "plot", "story", "synopsis", "overview",
            "about the game", "the game", "gameplay", "features",
            "description", "剧情", "故事", "游戏介绍", "游戏简介",
            "玩法", "游戏特色", "简介", "世界观"
        ]
        let allSectionHeadings = excludedHeadings.union(includedHeadings)

        func normalizedHeading(_ line: String) -> String {
            var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            value = value.replacingOccurrences(of: #"\s*\[[^\]]+\]\s*$"#, with: "", options: .regularExpression)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: ":：|—–- "))
            return value
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
        }

        func isExcludedHeading(_ heading: String) -> Bool {
            excludedHeadings.contains(heading)
                || excludedHeadings.contains(where: { heading.hasPrefix($0 + " ") })
                || heading.hasPrefix("get ")
                || heading.hasPrefix("download ")
        }

        let promotionalLines = [
            "join our discord", "join the discord", "join my discord", "join our server", "join our community",
            "support this project on patreon", "support the project on patreon",
            "support the game on patreon", "become a patron",
            "subscribe on patreon", "follow us on twitter"
        ]

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
            if allSectionHeadings.contains(heading) || isExcludedHeading(heading) {
                skippingSection = isExcludedHeading(heading)
                if !skippingSection { output.append(line) }
                continue
            }

            if !skippingSection {
                let lower = line.lowercased()
                let isCreatorPromotion = (lower.contains("patreon")
                    && ["support", "become a patron", "subscribe", "exclusive content", "early access"].contains(where: { lower.contains($0) }))
                    || (lower.contains("discord")
                    && ["join", "server", "community", "announcements"].contains(where: { lower.contains($0) }))
                if isCreatorPromotion || promotionalLines.contains(where: { lower.contains($0) }) {
                    continue
                }
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
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? source.trimmingCharacters(in: .whitespacesAndNewlines) : result
    }
}

enum GameDetailSnapshotPolicy {
    static func displayedDescription(
        current: String?,
        cached: String?,
        fallback: String?
    ) -> String? {
        current ?? cached ?? fallback
    }

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

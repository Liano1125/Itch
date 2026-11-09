import Foundation
import SwiftData

/// V2 -> V3 is deliberately custom: before SwiftData removes the legacy
/// columns, reconcile them into the normalized records and reject ambiguity.
/// V2 is copied to a staging store by V3StoreBootstrap, so a failed migration
/// never mutates the retained V2 recovery database.
enum ItchPocketMigrationPlan: SchemaMigrationPlan {
    enum MigrationError: LocalizedError {
        case collectionMembershipConflict(String)
        case duplicateCollectionMember(String)
        case duplicateGameDetail(String)

        var errorDescription: String? {
            switch self {
            case .collectionMembershipConflict(let id):
                return "V2 collection membership representations disagree for collection \(id)."
            case .duplicateCollectionMember(let id):
                return "V2 collection contains duplicate normalized members: \(id)."
            case .duplicateGameDetail(let id):
                return "V2 contains duplicate normalized detail records for game: \(id)."
            }
        }
    }

    static var schemas: [any VersionedSchema.Type] {
        [ItchPocketSchemaV2Snapshot.self, ItchPocketSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [v2ToV3]
    }

    static let v2ToV3 = MigrationStage.custom(
        fromVersion: ItchPocketSchemaV2Snapshot.self,
        toVersion: ItchPocketSchemaV3.self,
        willMigrate: { context in
            let games = try context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGame>())
            let details = try context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGameDetail>())
            var detailsByGameID: [String: ItchPocketSchemaV2Snapshot.DBGameDetail] = [:]
            for detail in details {
                guard detailsByGameID.updateValue(detail, forKey: detail.gameID) == nil else {
                    throw MigrationError.duplicateGameDetail(detail.gameID)
                }
            }

            // Prefer already-normalized V2 values. Fill only missing fields
            // from the compatibility columns so partial caches are retained.
            for game in games {
                if let detail = detailsByGameID[game.id] {
                    if detail.descriptionText == nil {
                        detail.descriptionText = game.descriptionText
                    }
                    if detail.galleryURLs.isEmpty && !game.galleryURLs.isEmpty {
                        detail.galleryURLs = game.galleryURLs
                    }
                    if detail.discoveryTagsData == nil {
                        detail.discoveryTagsData = game.discoveryTagsData
                    }
                } else if game.descriptionText != nil
                            || !game.galleryURLs.isEmpty
                            || game.discoveryTagsData != nil {
                    let detail = ItchPocketSchemaV2Snapshot.DBGameDetail(
                        gameID: game.id,
                        descriptionText: game.descriptionText,
                        galleryURLs: game.galleryURLs,
                        discoveryTagsData: game.discoveryTagsData,
                        fetchedAt: nil,
                        isComplete: false
                    )
                    context.insert(detail)
                    detailsByGameID[game.id] = detail
                }
            }

            let collections = try context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollection>())
            let items = try context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem>())
            let itemsByCollection = Dictionary(grouping: items, by: \.collectionID)

            for collection in collections {
                let legacyIDs = uniqueInOrder(collection.gameIDs)
                let existing = (itemsByCollection[collection.id] ?? []).sorted {
                    if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                    return $0.id < $1.id
                }
                let existingIDs = existing.map(\.gameID)

                guard Set(existingIDs).count == existingIDs.count else {
                    throw MigrationError.duplicateCollectionMember(collection.id)
                }
                guard existing.allSatisfy({
                    $0.id == ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem.stableID(
                        collectionID: collection.id,
                        gameID: $0.gameID
                    )
                }) else {
                    throw MigrationError.collectionMembershipConflict(collection.id)
                }

                if existing.isEmpty {
                    for (index, gameID) in legacyIDs.enumerated() {
                        context.insert(ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem(
                            id: ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem.stableID(
                                collectionID: collection.id,
                                gameID: gameID
                            ),
                            collectionID: collection.id,
                            gameID: gameID,
                            sortOrder: index,
                            addedAt: collection.createdAt
                        ))
                    }
                } else if existingIDs != legacyIDs {
                    throw MigrationError.collectionMembershipConflict(collection.id)
                }
            }

            try context.save()
        },
        didMigrate: { context in
            let games = try context.fetch(FetchDescriptor<DBGame>())
            let gameIDs = Set(games.map(\.id))
            let details = try context.fetch(FetchDescriptor<DBGameDetail>())
            guard details.allSatisfy({ gameIDs.contains($0.gameID) }) else {
                throw MigrationError.collectionMembershipConflict("orphan-game-detail")
            }
            guard Set(details.map(\.gameID)).count == details.count else {
                throw MigrationError.duplicateGameDetail("duplicate")
            }

            let collections = try context.fetch(FetchDescriptor<DBLibraryCollection>())
            let collectionIDs = Set(collections.map(\.id))
            let items = try context.fetch(FetchDescriptor<DBLibraryCollectionItem>())
            var seen = Set<String>()
            for item in items {
                guard collectionIDs.contains(item.collectionID),
                      gameIDs.contains(item.gameID),
                      item.id == DBLibraryCollectionItem.stableID(
                        collectionID: item.collectionID,
                        gameID: item.gameID
                      ),
                      seen.insert(item.id).inserted else {
                    throw MigrationError.collectionMembershipConflict(item.collectionID)
                }
            }
        }
    )

    private static func uniqueInOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

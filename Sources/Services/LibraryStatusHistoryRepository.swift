import Foundation
import SwiftData

/// Owns status-history reads and incremental writes.
/// A caller's in-memory history is never treated as a complete database snapshot.
@MainActor
final class LibraryStatusHistoryRepository {
    enum RepositoryError: LocalizedError {
        case eventIDConflict(String)

        var errorDescription: String? {
            switch self {
            case .eventIDConflict(let id):
                return "Status-history event ID \(id) is already associated with another game."
            }
        }
    }

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func loadEvents() throws -> [String: [LibraryStatusEvent]] {
        let rows = try database.repositoryContext.fetch(FetchDescriptor<DBLibraryStatusEvent>())
        return Dictionary(grouping: rows, by: \.gameID).mapValues { events in
            events.map {
                LibraryStatusEvent(
                    id: $0.id,
                    fromStatus: $0.fromStatus.flatMap(LibraryStatus.init(rawValue:)),
                    toStatus: LibraryStatus(rawValue: $0.toStatus) ?? .playing,
                    changedAt: $0.changedAt
                )
            }
        }
    }

    /// Inserts or updates exactly one event. It never deletes events omitted
    /// from a caller's in-memory cache.
    func append(_ event: LibraryStatusEvent, for gameID: String, save shouldSave: Bool = true) throws {
        let context = database.repositoryContext
        let eventID = event.id
        let descriptor = FetchDescriptor<DBLibraryStatusEvent>(
            predicate: #Predicate { $0.id == eventID }
        )

        let row: DBLibraryStatusEvent
        if let existing = try context.fetch(descriptor).first {
            guard existing.gameID == gameID else {
                throw RepositoryError.eventIDConflict(eventID)
            }
            row = existing
        } else {
            row = DBLibraryStatusEvent(
                id: event.id,
                gameID: gameID,
                fromStatus: event.fromStatus?.rawValue,
                toStatus: event.toStatus.rawValue,
                changedAt: event.changedAt
            )
            context.insert(row)
        }

        row.fromStatus = event.fromStatus?.rawValue
        row.toStatus = event.toStatus.rawValue
        row.changedAt = event.changedAt

        if shouldSave {
            try database.save()
        }
    }
}

import Foundation
import SwiftData

/// Shared write-time checks for the logical foreign keys represented by stable IDs.
/// SwiftData's scalar ID fields are intentionally not modeled as cascading relationships,
/// so every repository must validate references before mutating the shared context.
enum DatabaseReferenceValidator {
    enum ValidationError: LocalizedError, Equatable {
        case missingGame(String)
        case missingDeveloper(String)
        case calendarUpdateGameMismatch(eventGameID: String, updateID: String, updateGameID: String)

        var errorDescription: String? {
            switch self {
            case .missingGame(let id):
                return "Database reference points to missing game: \(id)."
            case .missingDeveloper(let id):
                return "Database reference points to missing developer: \(id)."
            case .calendarUpdateGameMismatch(let eventGameID, let updateID, let updateGameID):
                return "Calendar event for game \(eventGameID) cannot link update \(updateID) owned by game \(updateGameID)."
            }
        }
    }

    static func requireGame(_ gameID: String, in context: RepositoryContext) throws {
        let descriptor = FetchDescriptor<DBGame>(predicate: #Predicate { $0.id == gameID })
        guard try context.fetch(descriptor).first != nil else {
            throw ValidationError.missingGame(gameID)
        }
    }

    static func requireDeveloper(_ developerID: String, in context: RepositoryContext) throws {
        let descriptor = FetchDescriptor<DBDeveloper>(predicate: #Predicate { $0.id == developerID })
        guard try context.fetch(descriptor).first != nil else {
            throw ValidationError.missingDeveloper(developerID)
        }
    }

    /// Missing updates are tolerated because a Devlog may be deleted while its
    /// calendar snapshot remains useful. A present update must belong to the same game.
    static func validateCalendarUpdateLink(
        _ updateID: String?,
        eventGameID: String,
        in context: RepositoryContext
    ) throws {
        guard let updateID else { return }
        let descriptor = FetchDescriptor<DBGameUpdate>(predicate: #Predicate { $0.id == updateID })
        guard let update = try context.fetch(descriptor).first else { return }
        guard update.gameID == eventGameID else {
            throw ValidationError.calendarUpdateGameMismatch(
                eventGameID: eventGameID,
                updateID: updateID,
                updateGameID: update.gameID
            )
        }
    }
}

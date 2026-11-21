import Foundation
import SwiftData

enum V4AccountRegistryGuardError: LocalizedError, Equatable {
    case accountNotRegistered(String)

    var errorDescription: String? {
        switch self {
        case .accountNotRegistered(let accountID):
            return "The V4 itch account is no longer registered: \(accountID)."
        }
    }
}

/// Prevents a retained account-scoped repository from recreating personal rows
/// after the corresponding account registry entry has been explicitly removed.
enum V4AccountRegistryGuard {
    static func requireRegisteredAccount(_ accountID: String, in context: ModelContext) throws {
        let descriptor = FetchDescriptor<DBAccount>(
            predicate: #Predicate { $0.id == accountID }
        )
        guard try context.fetch(descriptor).count == 1 else {
            throw V4AccountRegistryGuardError.accountNotRegistered(accountID)
        }
    }
}

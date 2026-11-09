import Foundation

/// Explicit persistence rules for data that can arrive as partial snapshots.
enum LibraryUpdatePersistencePolicy {
    /// Only a caller that has positively identified a complete snapshot may
    /// remove stored updates omitted from that snapshot.
    static func shouldDeleteStoredUpdate(
        storedID: String,
        incomingIDs: Set<String>,
        isCompleteSnapshot: Bool
    ) -> Bool {
        isCompleteSnapshot && !incomingIDs.contains(storedID)
    }
}

/// Resolves the source-update link without treating an omitted argument as an unlink request.
enum CalendarSourceUpdateLinkPolicy {
    static func resolvedValue(
        existing: String?,
        incoming: String?,
        clear: Bool
    ) -> String? {
        if clear { return nil }
        return incoming ?? existing
    }
}

enum GameDetailPersistenceMode {
    case partial
    case complete
}

enum GameDetailPersistencePolicy {
    static func resolvedValue<Value>(
        existing: Value?,
        incoming: Value?,
        mode: GameDetailPersistenceMode
    ) -> Value? {
        switch mode {
        case .partial:
            return incoming ?? existing
        case .complete:
            return incoming
        }
    }
}

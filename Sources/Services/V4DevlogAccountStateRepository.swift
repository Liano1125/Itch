import Foundation
import SwiftData

struct V4DevlogHistoricalSyncState: Equatable {
    let lastSyncAt: Date?
    let lastMessage: String?
    let resultsData: Data?
}

/// V4-only account-scoped persistence for historical Devlog projection and
/// automatic-sync throttling. It is deliberately not wired into the V3
/// production singleton while database migration remains staged.
@MainActor
final class V4DevlogAccountStateRepository {
    enum StateError: LocalizedError {
        case staleSession
        case invalidAccountContext

        var errorDescription: String? {
            switch self {
            case .staleSession:
                return "The Devlog operation belongs to an inactive itch account session."
            case .invalidAccountContext:
                return "A canonical positive itch account ID is required."
            }
        }
    }

    private enum Key {
        static let historicalDate = "devlogSync.lastDate"
        static let historicalMessage = "devlogSync.lastMessage"
        static let historicalResults = "devlogSync.lastResults"
        static let autoSyncLastAttempt = "itchPocket.devlogAutoSync.lastAttempt"
    }

    private let repository: ScopedAppStateRepository

    init(context: ModelContext) {
        repository = ScopedAppStateRepository(context: context)
    }

    func historicalSyncState(
        for requestContext: ItchAccountRequestContext,
        session: ItchAccountSession
    ) throws -> V4DevlogHistoricalSyncState {
        let scope = try validatedScope(for: requestContext, session: session)
        return V4DevlogHistoricalSyncState(
            lastSyncAt: try repository.state(for: Key.historicalDate, in: scope)?.dateValue,
            lastMessage: try repository.state(for: Key.historicalMessage, in: scope)?.stringValue,
            resultsData: try repository.state(for: Key.historicalResults, in: scope)?.dataValue
        )
    }

    func saveHistoricalSyncState(
        lastSyncAt: Date?,
        message: String?,
        resultsData: Data?,
        for requestContext: ItchAccountRequestContext,
        session: ItchAccountSession
    ) throws {
        let scope = try validatedScope(for: requestContext, session: session)
        try repository.setDate(lastSyncAt, for: Key.historicalDate, in: scope)
        try repository.setString(message, for: Key.historicalMessage, in: scope)
        try repository.setData(resultsData, for: Key.historicalResults, in: scope)
    }

    func lastAutoSyncAttempt(
        for requestContext: ItchAccountRequestContext,
        session: ItchAccountSession
    ) throws -> Date? {
        let scope = try validatedScope(for: requestContext, session: session)
        return try repository.state(for: Key.autoSyncLastAttempt, in: scope)?.dateValue
    }

    func setAutoSyncAttempt(
        _ date: Date,
        for requestContext: ItchAccountRequestContext,
        session: ItchAccountSession
    ) throws {
        let scope = try validatedScope(for: requestContext, session: session)
        try repository.setDate(date, for: Key.autoSyncLastAttempt, in: scope)
    }

    private func validatedScope(
        for requestContext: ItchAccountRequestContext,
        session: ItchAccountSession
    ) throws -> AppStateScope {
        guard session.isCurrent(requestContext) else {
            throw StateError.staleSession
        }

        let prefix = "itch:"
        guard requestContext.accountID.hasPrefix(prefix),
              let userID = Int(requestContext.accountID.dropFirst(prefix.count)),
              userID > 0 else {
            throw StateError.invalidAccountContext
        }
        return try AppStateScope.itchAccount(userID: userID)
    }
}

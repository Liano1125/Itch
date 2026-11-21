import Foundation
import SwiftData

/// A mandatory persistence partition. It intentionally has no "current account"
/// resolver: callers must carry the identity they intend to read or mutate.
struct AppStateScope: Equatable {
    let kind: AppStateScopeKind
    let identifier: String

    private init(kind: AppStateScopeKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }

    static let device = AppStateScope(kind: .device, identifier: "device")
    static let appGlobal = AppStateScope(kind: .appGlobal, identifier: "app-global")
    static let legacyUnclassified = AppStateScope(
        kind: .legacyUnclassified,
        identifier: "legacy-unclassified"
    )

    enum ScopeError: LocalizedError {
        case invalidItchUserID
        case invalidPatreonAccountID

        var errorDescription: String? {
            switch self {
            case .invalidItchUserID:
                return "A positive numeric itch user ID is required for this scope."
            case .invalidPatreonAccountID:
                return "A non-empty Patreon account ID is required for this scope."
            }
        }
    }

    static func itchAccount(userID: Int) throws -> AppStateScope {
        guard userID > 0 else { throw ScopeError.invalidItchUserID }
        return AppStateScope(kind: .itchAccount, identifier: "itch:\(userID)")
    }

    static func patreonAccount(accountID: String) throws -> AppStateScope {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ScopeError.invalidPatreonAccountID }
        return AppStateScope(kind: .patreonAccount, identifier: "patreon:\(normalized)")
    }

    /// Length-prefixed components avoid delimiter collisions and keep
    /// namespaces independent even when account IDs contain punctuation.
    var scopeID: String {
        "\(kind.rawValue.utf8.count):\(kind.rawValue)\(identifier.utf8.count):\(identifier)"
    }
}

struct StoredScopedAppState: Equatable {
    let scopeID: String
    let key: String
    let stringValue: String?
    let dateValue: Date?
    let dataValue: Data?
    let updatedAt: Date

    fileprivate init(_ row: DBScopedAppState) {
        scopeID = row.scopeID
        key = row.logicalKey
        stringValue = row.stringValue
        dateValue = row.dateValue
        dataValue = row.dataValue
        updatedAt = row.updatedAt
    }
}

/// V4-only, explicitly scoped replacement for AppStateRepository.
/// V3 DBAppState rows are not read, mutated, or automatically copied here.
@MainActor
final class ScopedAppStateRepository {
    enum RepositoryError: LocalizedError {
        case invalidKey
        case duplicateState(String)
        case snapshotScopeMismatch

        var errorDescription: String? {
            switch self {
            case .invalidKey:
                return "An AppState logical key must not be empty."
            case .duplicateState(let key):
                return "Multiple scoped AppState rows exist for key \(key)."
            case .snapshotScopeMismatch:
                return "The AppState snapshot does not belong to the requested scope and key."
            }
        }
    }

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func state(for key: String, in scope: AppStateScope) throws -> StoredScopedAppState? {
        try existingRows(for: key, in: scope).first.map(StoredScopedAppState.init)
    }

    func states(in scope: AppStateScope) throws -> [StoredScopedAppState] {
        let scopeID = scope.scopeID
        let descriptor = FetchDescriptor<DBScopedAppState>(
            predicate: #Predicate { $0.scopeID == scopeID }
        )
        return try context.fetch(descriptor)
            .map(StoredScopedAppState.init)
            .sorted { $0.key < $1.key }
    }

    func setString(
        _ value: String?,
        for key: String,
        in scope: AppStateScope,
        save shouldSave: Bool = true
    ) throws {
        let row = try existingOrInsert(key: key, in: scope)
        row.stringValue = value
        row.dateValue = nil
        row.dataValue = nil
        row.updatedAt = .now
        if shouldSave { try context.save() }
    }

    func setDate(
        _ value: Date?,
        for key: String,
        in scope: AppStateScope,
        save shouldSave: Bool = true
    ) throws {
        let row = try existingOrInsert(key: key, in: scope)
        row.dateValue = value
        row.stringValue = nil
        row.dataValue = nil
        row.updatedAt = .now
        if shouldSave { try context.save() }
    }

    func setData(
        _ value: Data?,
        for key: String,
        in scope: AppStateScope,
        save shouldSave: Bool = true
    ) throws {
        let row = try existingOrInsert(key: key, in: scope)
        row.dataValue = value
        row.stringValue = nil
        row.dateValue = nil
        row.updatedAt = .now
        if shouldSave { try context.save() }
    }

    func restore(
        _ snapshot: StoredScopedAppState?,
        for key: String,
        in scope: AppStateScope,
        save shouldSave: Bool = false
    ) throws {
        try validate(key)
        if let snapshot,
           snapshot.scopeID != scope.scopeID || snapshot.key != key {
            throw RepositoryError.snapshotScopeMismatch
        }

        let existing = try existingRows(for: key, in: scope).first
        guard let snapshot else {
            if let existing { context.delete(existing) }
            if shouldSave, existing != nil { try context.save() }
            return
        }

        let row = existing ?? DBScopedAppState(scopeID: scope.scopeID, logicalKey: key)
        if existing == nil { context.insert(row) }
        row.stringValue = snapshot.stringValue
        row.dateValue = snapshot.dateValue
        row.dataValue = snapshot.dataValue
        row.updatedAt = snapshot.updatedAt
        if shouldSave { try context.save() }
    }

    func removeAll(matchingKeyPrefix prefix: String, in scope: AppStateScope, save shouldSave: Bool = true) throws {
        let rows = try states(in: scope)
        let keys = Set(rows.filter { $0.key.hasPrefix(prefix) }.map(\.key))
        for key in keys {
            for row in try existingRows(for: key, in: scope) {
                context.delete(row)
            }
        }
        if shouldSave, !keys.isEmpty { try context.save() }
    }

    func removeAll(in scope: AppStateScope, save shouldSave: Bool = true) throws {
        let rows = try states(in: scope)
        guard !rows.isEmpty else { return }
        let scopeID = scope.scopeID
        let descriptor = FetchDescriptor<DBScopedAppState>(
            predicate: #Predicate { $0.scopeID == scopeID }
        )
        for row in try context.fetch(descriptor) {
            context.delete(row)
        }
        if shouldSave { try context.save() }
    }

    private func existingOrInsert(key: String, in scope: AppStateScope) throws -> DBScopedAppState {
        if scope.kind == .itchAccount {
            try V4AccountRegistryGuard.requireRegisteredAccount(scope.identifier, in: context)
        }
        let rows = try existingRows(for: key, in: scope)
        guard rows.count <= 1 else { throw RepositoryError.duplicateState(key) }
        if let existing = rows.first { return existing }

        let row = DBScopedAppState(scopeID: scope.scopeID, logicalKey: key)
        context.insert(row)
        return row
    }

    private func existingRows(for key: String, in scope: AppStateScope) throws -> [DBScopedAppState] {
        try validate(key)
        let scopeID = scope.scopeID
        let descriptor = FetchDescriptor<DBScopedAppState>(
            predicate: #Predicate { $0.scopeID == scopeID && $0.logicalKey == key }
        )
        return try context.fetch(descriptor)
    }

    private func validate(_ key: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidKey
        }
    }
}

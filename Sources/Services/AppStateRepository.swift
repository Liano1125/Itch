import Foundation
import SwiftData

struct StoredAppState {
    let key: String
    let stringValue: String?
    let dateValue: Date?
    let dataValue: Data?
    let updatedAt: Date

    fileprivate init(_ row: DBAppState) {
        key = row.key
        stringValue = row.stringValue
        dateValue = row.dateValue
        dataValue = row.dataValue
        updatedAt = row.updatedAt
    }
}

/// Owns typed DBAppState persistence. Feature services retain responsibility
/// for the meaning and lifecycle of their own keys.
@MainActor
final class AppStateRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func state(for key: String) throws -> StoredAppState? {
        let descriptor = FetchDescriptor<DBAppState>(
            predicate: #Predicate { $0.key == key }
        )
        return try database.repositoryContext.fetch(descriptor).first.map(StoredAppState.init)
    }

    func setString(_ value: String?, for key: String, clearOtherValues: Bool = false, save shouldSave: Bool = true) throws {
        let row = try existingOrInsert(key: key)
        row.stringValue = value
        if clearOtherValues { row.dateValue = nil; row.dataValue = nil }
        row.updatedAt = .now
        if shouldSave { try database.save() }
    }

    func setDate(_ value: Date?, for key: String, clearOtherValues: Bool = false, save shouldSave: Bool = true) throws {
        let row = try existingOrInsert(key: key)
        row.dateValue = value
        if clearOtherValues { row.stringValue = nil; row.dataValue = nil }
        row.updatedAt = .now
        if shouldSave { try database.save() }
    }

    func setData(_ value: Data?, for key: String, save shouldSave: Bool = true) throws {
        let row = try existingOrInsert(key: key)
        row.dataValue = value
        row.updatedAt = .now
        if shouldSave { try database.save() }
    }

    /// Restores one previously captured key without saving or rolling back the shared context.
    /// A nil snapshot means the key did not exist before the operation.
    func restore(_ snapshot: StoredAppState?, for key: String, save shouldSave: Bool = false) throws {
        let descriptor = FetchDescriptor<DBAppState>(
            predicate: #Predicate { $0.key == key }
        )
        let existing = try database.repositoryContext.fetch(descriptor).first
        guard let snapshot else {
            if let existing { database.repositoryContext.delete(existing) }
            if shouldSave { try database.save() }
            return
        }

        let row = existing ?? DBAppState(key: key)
        if row.modelContext == nil { database.repositoryContext.insert(row) }
        row.stringValue = snapshot.stringValue
        row.dateValue = snapshot.dateValue
        row.dataValue = snapshot.dataValue
        row.updatedAt = snapshot.updatedAt
        if shouldSave { try database.save() }
    }

    func removeAll(matchingKeyPrefix prefix: String, save shouldSave: Bool = true) throws {
        let rows = try database.repositoryContext.fetch(FetchDescriptor<DBAppState>())
        for row in rows where row.key.hasPrefix(prefix) {
            database.repositoryContext.delete(row)
        }
        if shouldSave { try database.save() }
    }

    func removeAll(save shouldSave: Bool = true) throws {
        // Use tracked per-model deletions so save:false remains part of the
        // caller's ModelContext transaction instead of issuing a bulk delete.
        let rows = try database.repositoryContext.fetch(FetchDescriptor<DBAppState>())
        for row in rows {
            database.repositoryContext.delete(row)
        }
        if shouldSave { try database.save() }
    }

    private func existingOrInsert(key: String) throws -> DBAppState {
        let descriptor = FetchDescriptor<DBAppState>(
            predicate: #Predicate { $0.key == key }
        )
        if let existing = try database.repositoryContext.fetch(descriptor).first {
            return existing
        }
        let row = DBAppState(key: key)
        database.repositoryContext.insert(row)
        return row
    }
}

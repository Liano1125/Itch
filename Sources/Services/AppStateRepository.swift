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
        return try database.context.fetch(descriptor).first.map(StoredAppState.init)
    }

    func setString(_ value: String?, for key: String, save shouldSave: Bool = true) throws {
        let row = try existingOrInsert(key: key)
        row.stringValue = value
        row.updatedAt = .now
        if shouldSave { try database.save() }
    }

    func setDate(_ value: Date?, for key: String, save shouldSave: Bool = true) throws {
        let row = try existingOrInsert(key: key)
        row.dateValue = value
        row.updatedAt = .now
        if shouldSave { try database.save() }
    }

    func setData(_ value: Data?, for key: String, save shouldSave: Bool = true) throws {
        let row = try existingOrInsert(key: key)
        row.dataValue = value
        row.updatedAt = .now
        if shouldSave { try database.save() }
    }

    func removeAll(matchingKeyPrefix prefix: String, save shouldSave: Bool = true) throws {
        let rows = try database.context.fetch(FetchDescriptor<DBAppState>())
        for row in rows where row.key.hasPrefix(prefix) {
            database.context.delete(row)
        }
        if shouldSave { try database.save() }
    }

    func removeAll(save shouldSave: Bool = true) throws {
        try database.context.delete(model: DBAppState.self)
        if shouldSave { try database.save() }
    }

    private func existingOrInsert(key: String) throws -> DBAppState {
        let descriptor = FetchDescriptor<DBAppState>(
            predicate: #Predicate { $0.key == key }
        )
        if let existing = try database.context.fetch(descriptor).first {
            return existing
        }
        let row = DBAppState(key: key)
        database.context.insert(row)
        return row
    }
}

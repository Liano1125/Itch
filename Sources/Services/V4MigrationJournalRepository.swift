import Foundation

/// An actor-isolated, file-backed control store for migration metadata.
///
/// The complete record/event snapshot is replaced in one atomic file write.
/// It is independent from both the authoritative V3 store and each disposable
/// V4 staging store. It stores metadata only.
actor V4MigrationJournalRepository {
    struct CreationResult: Equatable {
        let record: V4MigrationJournalRecord
        let wasCreated: Bool
    }

    enum RepositoryError: Error, Equatable {
        case invalidIdentifier
        case idempotencyKeyConflict
        case runIDConflict
        case recordNotFound
        case stateConflict
        case corruptStore
        case unsupportedStoreVersion
    }

    private struct Snapshot: Codable {
        let storeVersion: Int
        var records: [String: V4MigrationJournalRecord]
        var events: [V4MigrationJournalEvent]

        static let currentStoreVersion = 1
        static var empty: Snapshot {
            Snapshot(storeVersion: currentStoreVersion, records: [:], events: [])
        }
    }

    private let fileURL: URL
    private let ownerLockURL: URL
    private let fileManager: FileManager
    private let writeData: (Data, URL) throws -> Void
    private var snapshot: Snapshot?

    /// The URL must point to a dedicated control-store file, never the V3
    /// source or a V4 staging database.
    init(
        fileURL: URL,
        ownerLockURL: URL? = nil,
        fileManager: FileManager = .default,
        writeData: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: [.atomic])
        }
    ) {
        self.fileURL = fileURL
        self.ownerLockURL = (ownerLockURL ?? fileURL.deletingLastPathComponent().appendingPathComponent("migration-owner.lock")).standardizedFileURL
        self.fileManager = fileManager
        self.writeData = writeData
    }

    /// Creates a journal once per idempotency key. Replaying the same request
    /// returns the original record and never creates a second run.
    func createOrGet(
        runID: String,
        idempotencyKey: String,
        sourceSchemaVersion: String,
        destinationSchemaVersion: String,
        at date: Date,
        attemptNumber: Int = 1,
        stagingStoreID: String? = nil,
        ownerLease: V4MigrationOwnerLock.Lease? = nil
    ) throws -> CreationResult {
        let acquiredLease: V4MigrationOwnerLock.Lease?
        if let ownerLease {
            try ownerLease.validateOwnership(at: ownerLockURL)
            acquiredLease = nil
        } else {
            acquiredLease = try V4MigrationOwnerLock.acquire(at: ownerLockURL)
        }
        defer { acquiredLease?.release() }
        guard Self.isValidIdentifier(runID),
              Self.isValidIdentifier(idempotencyKey),
              Self.isValidIdentifier(sourceSchemaVersion),
              Self.isValidIdentifier(destinationSchemaVersion),
              stagingStoreID.map(Self.isValidIdentifier) ?? true,
              attemptNumber > 0 else {
            throw RepositoryError.invalidIdentifier
        }

        var current = try loadIfNeeded()
        if let existing = current.records.values.first(where: { $0.idempotencyKey == idempotencyKey }) {
            guard existing.sourceSchemaVersion == sourceSchemaVersion,
                  existing.destinationSchemaVersion == destinationSchemaVersion,
                  existing.attemptNumber == attemptNumber,
                  existing.stagingStoreID == stagingStoreID else {
                throw RepositoryError.idempotencyKeyConflict
            }
            return CreationResult(record: existing, wasCreated: false)
        }
        guard current.records[runID] == nil else {
            throw RepositoryError.runIDConflict
        }

        let record = V4MigrationJournalRecord(
            runID: runID,
            idempotencyKey: idempotencyKey,
            sourceSchemaVersion: sourceSchemaVersion,
            destinationSchemaVersion: destinationSchemaVersion,
            createdAt: date,
            attemptNumber: attemptNumber,
            stagingStoreID: stagingStoreID
        )
        let event = V4MigrationJournalEvent(
            runID: runID,
            sequence: 1,
            fromState: nil,
            toState: .requested,
            code: "migration.requested",
            timestamp: date
        )
        current.records[runID] = record
        current.events.append(event)
        try persist(current)
        return CreationResult(record: record, wasCreated: true)
    }

    /// Performs a compare-and-swap transition. Record replacement and event
    /// append are committed together in the same atomic snapshot write.
    /// Replaying the immediately preceding transition (same target and code)
    /// is idempotent and returns the already-committed record.
    func transition(
        runID: String,
        from expectedState: V4MigrationJournalState,
        to nextState: V4MigrationJournalState,
        at date: Date,
        code: String,
        ownerLease: V4MigrationOwnerLock.Lease? = nil
    ) throws -> V4MigrationJournalRecord {
        let acquiredLease: V4MigrationOwnerLock.Lease?
        if let ownerLease {
            try ownerLease.validateOwnership(at: ownerLockURL)
            acquiredLease = nil
        } else {
            acquiredLease = try V4MigrationOwnerLock.acquire(at: ownerLockURL)
        }
        defer { acquiredLease?.release() }
        var current = try loadIfNeeded()
        guard let record = current.records[runID] else {
            throw RepositoryError.recordNotFound
        }

        let runEvents = current.events.filter { $0.runID == runID }
        if record.state == nextState,
           let lastEvent = runEvents.last,
           lastEvent.toState == nextState,
           lastEvent.code == code {
            return record
        }
        guard record.state == expectedState else {
            throw RepositoryError.stateConflict
        }

        let sequence = (runEvents.last?.sequence ?? 0) + 1
        let result = try record.transitioning(
            to: nextState,
            at: date,
            sequence: sequence,
            code: code
        )
        current.records[runID] = result.record
        current.events.append(result.event)
        try persist(current)
        return result.record
    }

    func record(runID: String) throws -> V4MigrationJournalRecord? {
        try loadIfNeeded().records[runID]
    }

    func events(runID: String) throws -> [V4MigrationJournalEvent] {
        try loadIfNeeded().events
            .filter { $0.runID == runID }
            .sorted { $0.sequence < $1.sequence }
    }

    func allRecords() throws -> [V4MigrationJournalRecord] {
        try loadIfNeeded().records.values.sorted { $0.createdAt < $1.createdAt }
    }

    private func loadIfNeeded() throws -> Snapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let empty = Snapshot.empty
            snapshot = empty
            return empty
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(Snapshot.self, from: data)
            guard decoded.storeVersion == Snapshot.currentStoreVersion else {
                throw RepositoryError.unsupportedStoreVersion
            }
            guard Self.isConsistent(decoded) else {
                throw RepositoryError.corruptStore
            }
            snapshot = decoded
            return decoded
        } catch let error as RepositoryError {
            throw error
        } catch {
            throw RepositoryError.corruptStore
        }
    }

    private func persist(_ candidate: Snapshot) throws {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try writeData(encoder.encode(candidate), fileURL)
            snapshot = candidate
        } catch {
            // Keep the last committed in-memory snapshot. Migration must stop
            // when a journal commit fails.
            throw error
        }
    }

    private static func isConsistent(_ value: Snapshot) -> Bool {
        guard value.records.allSatisfy({ key, record in
            key == record.runID &&
            record.journalVersion == V4MigrationJournalRecord.currentJournalVersion &&
            isValidIdentifier(record.runID) &&
            isValidIdentifier(record.idempotencyKey) &&
            isValidIdentifier(record.sourceSchemaVersion) &&
            isValidIdentifier(record.destinationSchemaVersion) &&
            record.attemptNumber > 0 &&
            record.completedDomains.allSatisfy(isValidIdentifier) &&
            [record.sourceSnapshotID, record.sourceSnapshotDigest,
             record.sourceInventoryDigest, record.stagingStoreID,
             record.manifestDigest, record.failureCode]
                .compactMap({ $0 }).allSatisfy(isValidIdentifier)
        }) else { return false }

        guard value.events.allSatisfy({
            isValidIdentifier($0.runID) &&
            $0.sequence > 0 &&
            Self.isSafeCode($0.code)
        }) else { return false }

        let keys = value.records.values.map(\.idempotencyKey)
        guard Set(keys).count == keys.count else { return false }

        for (runID, record) in value.records {
            let runEvents = value.events.filter { $0.runID == runID }.sorted { $0.sequence < $1.sequence }
            guard !runEvents.isEmpty,
                  runEvents.first?.fromState == nil,
                  runEvents.first?.toState == .requested,
                  runEvents.last?.toState == record.state,
                  runEvents.map(\.sequence) == Array(1...runEvents.count) else {
                return false
            }
            for pair in zip(runEvents, runEvents.dropFirst()) {
                guard pair.0.toState == pair.1.fromState,
                      V4MigrationJournalStateMachine.canTransition(
                        from: pair.0.toState,
                        to: pair.1.toState
                      ) else { return false }
            }
        }
        return value.events.allSatisfy { value.records[$0.runID] != nil }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
    }

    private static func isSafeCode(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 96 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
    }
}

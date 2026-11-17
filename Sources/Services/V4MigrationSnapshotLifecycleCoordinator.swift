import Foundation

/// Coordinates the journal and disposable staging snapshot for one migration attempt.
struct V4MigrationSnapshotLifecycleCoordinator {
    enum CoordinatorError: Error, Equatable { case attemptAlreadyExists }

    private let journal: V4MigrationJournalRepository
    private let stagingManager: V4MigrationStagingStoreManager
    private let ownerLockURL: URL

    init(
        journal: V4MigrationJournalRepository,
        stagingManager: V4MigrationStagingStoreManager,
        ownerLockURL: URL
    ) {
        self.journal = journal
        self.stagingManager = stagingManager
        self.ownerLockURL = ownerLockURL.standardizedFileURL
    }

    /// Runs an entire migration pipeline under one OS-level lease.
    /// The lease remains valid across awaited journal/filesystem work and the
    /// caller's synchronous conversion/verification work inside the closure.
    func withExclusiveMigrationOwnership<T>(
        _ operation: (V4MigrationOwnerLock.Lease) async throws -> T
    ) async throws -> T {
        let ownerLease = try V4MigrationOwnerLock.acquire(at: ownerLockURL)
        defer { ownerLease.release() }
        return try await operation(ownerLease)
    }

    /// Convenience entry point for snapshot-only callers. A full migration
    /// should instead call this from withExclusiveMigrationOwnership and pass
    /// that same lease to both snapshot creation and V4MigrationCoordinator.
    func createStagingSnapshot(
        from sourceURL: URL, runID: String, idempotencyKey: String,
        sourceSchemaVersion: String, destinationSchemaVersion: String,
        stagingStoreID: String, at date: Date, attemptNumber: Int = 1
    ) async throws -> V4MigrationStagingStore {
        try await withExclusiveMigrationOwnership { ownerLease in
            try await createStagingSnapshot(
                from: sourceURL, runID: runID, idempotencyKey: idempotencyKey,
                sourceSchemaVersion: sourceSchemaVersion,
                destinationSchemaVersion: destinationSchemaVersion,
                stagingStoreID: stagingStoreID, at: date,
                attemptNumber: attemptNumber, ownerLease: ownerLease
            )
        }
    }

    /// Caller must pass the live lease yielded by withExclusiveMigrationOwnership.
    func createStagingSnapshot(
        from sourceURL: URL, runID: String, idempotencyKey: String,
        sourceSchemaVersion: String, destinationSchemaVersion: String,
        stagingStoreID: String, at date: Date, attemptNumber: Int = 1,
        ownerLease: V4MigrationOwnerLock.Lease
    ) async throws -> V4MigrationStagingStore {
        try ownerLease.validateOwnership(at: ownerLockURL)

        let creation = try await journal.createOrGet(
            runID: runID, idempotencyKey: idempotencyKey,
            sourceSchemaVersion: sourceSchemaVersion,
            destinationSchemaVersion: destinationSchemaVersion,
            at: date, attemptNumber: attemptNumber, stagingStoreID: stagingStoreID
        )
        guard creation.wasCreated else { throw CoordinatorError.attemptAlreadyExists }

        do {
            _ = try await journal.transition(runID: runID, from: .requested, to: .snapshotting, at: date, code: "snapshot.started")
            let staging = try stagingManager.createSnapshot(from: sourceURL, runID: runID, stagingStoreID: stagingStoreID)
            _ = try await journal.transition(runID: runID, from: .snapshotting, to: .snapshotReady, at: date, code: "snapshot.ready")
            _ = try await journal.transition(runID: runID, from: .snapshotReady, to: .stagingCreated, at: date, code: "staging.created")
            return staging
        } catch {
            try? stagingManager.discard(runID: runID, stagingStoreID: stagingStoreID)
            if let current = try? await journal.record(runID: runID), !current.state.isTerminal {
                try? await journal.transition(runID: runID, from: current.state, to: .failed, at: date, code: "staging.failed")
            }
            throw error
        }
    }

    /// Convenience entry point for recovery that owns its own lock scope.
    func recoverInterruptedSnapshotAttempts(at date: Date) async throws -> [String] {
        try await withExclusiveMigrationOwnership { ownerLease in
            try await recoverInterruptedSnapshotAttempts(at: date, ownerLease: ownerLease)
        }
    }

    /// Recovery variant for a top-level migration owner that already holds the
    /// shared lease across recovery and any subsequent migration work.
    func recoverInterruptedSnapshotAttempts(
        at date: Date,
        ownerLease: V4MigrationOwnerLock.Lease
    ) async throws -> [String] {
        try ownerLease.validateOwnership(at: ownerLockURL)
        let records = try await journal.allRecords()
        var recovered: [String] = []
        for record in records where record.state == .requested || record.state == .snapshotting || record.state == .snapshotReady {
            if let stagingStoreID = record.stagingStoreID {
                _ = try stagingManager.discard(runID: record.runID, stagingStoreID: stagingStoreID)
            }
            _ = try await journal.transition(runID: record.runID, from: record.state, to: .failed, at: date, code: "recovery.interrupted")
            recovered.append(record.runID)
        }
        return recovered
    }
}

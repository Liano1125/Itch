import Foundation

/// Coordinates the journal and disposable staging snapshot for one migration attempt.
struct V4MigrationSnapshotLifecycleCoordinator {
    enum CoordinatorError: Error, Equatable { case attemptAlreadyExists }

    private let journal: V4MigrationJournalRepository
    private let stagingManager: V4MigrationStagingStoreManager

    init(journal: V4MigrationJournalRepository, stagingManager: V4MigrationStagingStoreManager) {
        self.journal = journal
        self.stagingManager = stagingManager
    }

    /// Persists the staging identity before touching the filesystem.
    func createStagingSnapshot(
        from sourceURL: URL, runID: String, idempotencyKey: String,
        sourceSchemaVersion: String, destinationSchemaVersion: String,
        stagingStoreID: String, at date: Date, attemptNumber: Int = 1
    ) async throws -> V4MigrationStagingStore {
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

    /// Only recover pre-staging states. Caller must first hold an exclusive
    /// migration-owner lock; the journal actor is not a cross-process lock.
    /// Completed stagingCreated attempts are preserved for the next phase.
    func recoverInterruptedSnapshotAttempts(at date: Date) async throws -> [String] {
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
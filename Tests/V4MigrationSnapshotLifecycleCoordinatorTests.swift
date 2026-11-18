import XCTest
import SQLite3
@testable import itchPocket

final class V4MigrationSnapshotLifecycleCoordinatorTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("V4SnapshotCoordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCreatesStagingAndPersistsJournalTransitions() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try makeDatabase(in: root)
        let journalURL = root.appendingPathComponent("control/journal.json")
        let journal = V4MigrationJournalRepository(fileURL: journalURL)
        let manager = V4MigrationStagingStoreManager(rootURL: root.appendingPathComponent("staging"))
        let coordinator = V4MigrationSnapshotLifecycleCoordinator(journal: journal, stagingManager: manager, ownerLockURL: root.appendingPathComponent("control/migration-owner.lock"))

        let staging = try await coordinator.createStagingSnapshot(
            from: sourceURL, runID: "run-101", idempotencyKey: "request-101",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4",
            stagingStoreID: "stage-101", at: epoch
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.storeURL.path))
        let restarted = V4MigrationJournalRepository(fileURL: journalURL)
        let record = try await restarted.record(runID: "run-101")
        XCTAssertEqual(record?.state, .stagingCreated)
        XCTAssertEqual(record?.stagingStoreID, "stage-101")
        let events = try await restarted.events(runID: "run-101")
        XCTAssertEqual(events.map(\.toState), [.requested, .snapshotting, .snapshotReady, .stagingCreated])
    }

    func testFailedSnapshotCleansStagingAndMarksAttemptFailed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("invalid.sqlite")
        try Data("not sqlite".utf8).write(to: sourceURL)
        let journalURL = root.appendingPathComponent("control/journal.json")
        let manager = V4MigrationStagingStoreManager(rootURL: root.appendingPathComponent("staging"))
        let journal = V4MigrationJournalRepository(fileURL: journalURL)
        let coordinator = V4MigrationSnapshotLifecycleCoordinator(journal: journal, stagingManager: manager, ownerLockURL: root.appendingPathComponent("control/migration-owner.lock"))

        do {
            _ = try await coordinator.createStagingSnapshot(
                from: sourceURL, runID: "run-102", idempotencyKey: "request-102",
                sourceSchemaVersion: "3", destinationSchemaVersion: "4",
                stagingStoreID: "stage-102", at: epoch
            )
            XCTFail("Expected invalid SQLite source to fail")
        } catch {
            XCTAssertTrue(error is SQLiteStoreSnapshotCopier.CopyError || error is SQLiteStoreIntegrityChecker.CheckError)
        }

        let record = try await journal.record(runID: "run-102")
        XCTAssertEqual(record?.state, .failed)
        XCTAssertEqual(record?.stagingStoreID, "stage-102")
        let stagingDirectory = root.appendingPathComponent("staging/run-run-102-staging-stage-102", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testRecoveryDiscardsOnlyRecordedInterruptedAttempt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = V4MigrationJournalRepository(fileURL: root.appendingPathComponent("control/journal.json"))
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let manager = V4MigrationStagingStoreManager(rootURL: stagingRoot)
        _ = try await journal.createOrGet(
            runID: "run-103", idempotencyKey: "request-103",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4",
            at: epoch, stagingStoreID: "stage-103"
        )
        _ = try await journal.transition(runID: "run-103", from: .requested, to: .snapshotting, at: epoch, code: "snapshot.started")
        let interrupted = stagingRoot.appendingPathComponent("run-run-103-staging-stage-103", isDirectory: true)
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        let unrelated = stagingRoot.appendingPathComponent("run-other-staging-stage-other", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        let coordinator = V4MigrationSnapshotLifecycleCoordinator(journal: journal, stagingManager: manager, ownerLockURL: root.appendingPathComponent("control/migration-owner.lock"))
        let recovered = try await coordinator.recoverInterruptedSnapshotAttempts(at: epoch.addingTimeInterval(10))
        XCTAssertEqual(recovered, ["run-103"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        let record = try await journal.record(runID: "run-103")
        XCTAssertEqual(record?.state, .failed)
    }

    func testIdempotentReplayCannotSilentlyStartDuplicateAttempt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try makeDatabase(in: root)
        let journal = V4MigrationJournalRepository(fileURL: root.appendingPathComponent("control/journal.json"))
        let manager = V4MigrationStagingStoreManager(rootURL: root.appendingPathComponent("staging"))
        let coordinator = V4MigrationSnapshotLifecycleCoordinator(journal: journal, stagingManager: manager, ownerLockURL: root.appendingPathComponent("control/migration-owner.lock"))
        _ = try await coordinator.createStagingSnapshot(
            from: sourceURL, runID: "run-104", idempotencyKey: "request-104",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4",
            stagingStoreID: "stage-104", at: epoch
        )
        do {
            _ = try await coordinator.createStagingSnapshot(
                from: sourceURL, runID: "run-104-replay", idempotencyKey: "request-104",
                sourceSchemaVersion: "3", destinationSchemaVersion: "4",
                stagingStoreID: "stage-104", at: epoch
            )
            XCTFail("Expected duplicate attempt to be rejected")
        } catch {
            XCTAssertEqual(error as? V4MigrationSnapshotLifecycleCoordinator.CoordinatorError, .attemptAlreadyExists)
        }
    }


    func testSharedLeaseCanSpanSnapshotAndFollowingPipelineWork() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try makeDatabase(in: root)
        let lockURL = root.appendingPathComponent("control/migration-owner.lock")
        let journal = V4MigrationJournalRepository(fileURL: root.appendingPathComponent("control/journal.json"))
        let manager = V4MigrationStagingStoreManager(rootURL: root.appendingPathComponent("staging"))
        let coordinator = V4MigrationSnapshotLifecycleCoordinator(
            journal: journal, stagingManager: manager, ownerLockURL: lockURL
        )

        let staging = try await coordinator.withExclusiveMigrationOwnership { lease in
            let created = try await coordinator.createStagingSnapshot(
                from: sourceURL, runID: "run-shared-lock", idempotencyKey: "request-shared-lock",
                sourceSchemaVersion: "3", destinationSchemaVersion: "4",
                stagingStoreID: "stage-shared-lock", at: epoch, ownerLease: lease
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: created.storeURL.path))
            XCTAssertNoThrow(try lease.validateOwnership(at: lockURL))
            XCTAssertThrowsError(try V4MigrationOwnerLock.acquire(at: lockURL)) { error in
                XCTAssertEqual(error as? V4MigrationOwnerLock.LockError, .alreadyHeld)
            }
            // The caller performs conversion and verification here with this
            // exact lease before leaving the closure.
            return created
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.storeURL.path))
        let nextLease = try V4MigrationOwnerLock.acquire(at: lockURL)
        nextLease.release()
    }


    func testRecoveryDiscardsEveryUnvalidatedInterruptedStageAndIsIdempotent() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = V4MigrationJournalRepository(fileURL: root.appendingPathComponent("control/journal.json"))
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let manager = V4MigrationStagingStoreManager(rootURL: stagingRoot)
        let interruptedStates: [V4MigrationJournalState] = [
            .snapshotting, .snapshotReady, .stagingCreated, .converting, .verifying, .manifestWritten
        ]
        let transitionPath: [V4MigrationJournalState] = [
            .snapshotting, .snapshotReady, .stagingCreated, .converting, .verifying, .manifestWritten
        ]

        for (index, target) in interruptedStates.enumerated() {
            let runID = "crash-run-\(index)"
            let stageID = "crash-stage-\(index)"
            _ = try await journal.createOrGet(
                runID: runID, idempotencyKey: "crash-request-\(index)",
                sourceSchemaVersion: "3", destinationSchemaVersion: "4",
                at: epoch.addingTimeInterval(TimeInterval(index)), stagingStoreID: stageID
            )
            var current = V4MigrationJournalState.requested
            for next in transitionPath {
                _ = try await journal.transition(
                    runID: runID, from: current, to: next,
                    at: epoch, code: "test.crash.transition"
                )
                current = next
                if current == target { break }
            }
            let directory = stagingRoot.appendingPathComponent(
                "run-\(runID)-staging-\(stageID)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let validatedID = "validated-run"
        let validatedStageID = "validated-stage"
        _ = try await journal.createOrGet(
            runID: validatedID, idempotencyKey: "validated-request",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4",
            at: epoch.addingTimeInterval(100), stagingStoreID: validatedStageID
        )
        var validatedState = V4MigrationJournalState.requested
        for next in transitionPath + [.stagingValidated] {
            _ = try await journal.transition(
                runID: validatedID, from: validatedState, to: next,
                at: epoch, code: "test.validated.transition"
            )
            validatedState = next
        }
        let validatedDirectory = stagingRoot.appendingPathComponent(
            "run-\(validatedID)-staging-\(validatedStageID)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: validatedDirectory, withIntermediateDirectories: true)

        let unrelated = stagingRoot.appendingPathComponent("unrelated-data", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let coordinator = V4MigrationSnapshotLifecycleCoordinator(
            journal: journal, stagingManager: manager,
            ownerLockURL: root.appendingPathComponent("control/migration-owner.lock")
        )

        let recovered = try await coordinator.recoverInterruptedSnapshotAttempts(at: epoch.addingTimeInterval(200))
        XCTAssertEqual(Set(recovered), Set(interruptedStates.indices.map { "crash-run-\($0)" }))
        XCTAssertEqual(recovered.count, interruptedStates.count)
        for index in interruptedStates.indices {
            let record = try await journal.record(runID: "crash-run-\(index)")
            XCTAssertEqual(record?.state, .failed)
            let directory = stagingRoot.appendingPathComponent(
                "run-crash-run-\(index)-staging-crash-stage-\(index)", isDirectory: true
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }

        let validatedRecord = try await journal.record(runID: validatedID)
        XCTAssertEqual(validatedRecord?.state, .stagingValidated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: validatedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))

        let repeated = try await coordinator.recoverInterruptedSnapshotAttempts(at: epoch.addingTimeInterval(300))
        XCTAssertTrue(repeated.isEmpty)
        let finalValidatedRecord = try await journal.record(runID: validatedID)
        XCTAssertEqual(finalValidatedRecord?.state, .stagingValidated)
    }

    func testRecoveryFailureCanBeRetriedWithFreshAttemptIdentity() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try makeDatabase(in: root)
        let journal = V4MigrationJournalRepository(fileURL: root.appendingPathComponent("control/journal.json"))
        let manager = V4MigrationStagingStoreManager(rootURL: root.appendingPathComponent("staging"))
        _ = try await journal.createOrGet(
            runID: "retry-run", idempotencyKey: "retry-request",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4",
            at: epoch, stagingStoreID: "retry-stage"
        )
        _ = try await journal.transition(
            runID: "retry-run", from: .requested, to: .snapshotting,
            at: epoch, code: "snapshot.started"
        )
        let interrupted = root.appendingPathComponent(
            "staging/run-retry-run-staging-retry-stage", isDirectory: true
        )
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        let unrelated = root.appendingPathComponent("staging/keep-me", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let coordinator = V4MigrationSnapshotLifecycleCoordinator(
            journal: journal, stagingManager: manager,
            ownerLockURL: root.appendingPathComponent("control/migration-owner.lock")
        )

        _ = try await coordinator.recoverInterruptedSnapshotAttempts(at: epoch.addingTimeInterval(1))
        let failedRecord = try await journal.record(runID: "retry-run")
        XCTAssertEqual(failedRecord?.state, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))

        let retry = try await journal.createOrGet(
            runID: "retry-run-2", idempotencyKey: "retry-request-2",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4",
            at: epoch.addingTimeInterval(2), attemptNumber: 2, stagingStoreID: "retry-stage-2"
        )
        XCTAssertTrue(retry.wasCreated)
        XCTAssertNotEqual(retry.record.runID, "retry-run")
        XCTAssertNotEqual(retry.record.stagingStoreID, "retry-stage")
    }

    private func makeDatabase(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).sqlite")
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        XCTAssertEqual(result, SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close_v2(handle) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let sql = "CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT NOT NULL); INSERT INTO records VALUES (1, 'ok');"
        let execution = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard execution == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            if let errorMessage { sqlite3_free(errorMessage) }
            throw NSError(domain: "CoordinatorTests", code: Int(execution), userInfo: [NSLocalizedDescriptionKey: detail])
        }
        return url
    }
}
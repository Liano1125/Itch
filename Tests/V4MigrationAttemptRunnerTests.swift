import XCTest
import SwiftData
@testable import itchPocket

final class V4MigrationAttemptRunnerTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testRunnerMigratesOnlySnapshotAndPersistsValidatedJournal() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try makeV3Store(in: root, gameID: "runner-game")
        let controlURL = root.appendingPathComponent("control", isDirectory: true)
        let ownerLockURL = controlURL.appendingPathComponent("migration-owner.lock")
        let journal = V4MigrationJournalRepository(
            fileURL: controlURL.appendingPathComponent("journal.json"),
            ownerLockURL: ownerLockURL
        )
        let stagingManager = V4MigrationStagingStoreManager(
            rootURL: root.appendingPathComponent("staging", isDirectory: true)
        )
        let lifecycle = V4MigrationSnapshotLifecycleCoordinator(
            journal: journal,
            stagingManager: stagingManager,
            ownerLockURL: ownerLockURL
        )

        let result = try await V4MigrationAttemptRunner.run(
            sourceV3StoreURL: sourceURL,
            runID: "runner-success",
            idempotencyKey: "runner-success-request",
            stagingStoreID: "runner-success-stage",
            at: epoch,
            lifecycle: lifecycle,
            stagingManager: stagingManager,
            journal: journal,
            ownerLockURL: ownerLockURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.snapshot.storeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.destinationStoreURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.manifestURL.path))
        XCTAssertEqual(result.attempt.runID, "runner-success")
        try SQLiteStoreIntegrityChecker.fullCheck(at: result.destinationStoreURL)

        let record = try await journal.record(runID: "runner-success")
        XCTAssertTrue(
            record?.state == .stagingValidated ||
            record?.state == .eligibleForIndependentSafetyGates
        )
        let states = try await journal.events(runID: "runner-success").map(\.toState)
        XCTAssertEqual(
            Array(states.prefix(7)),
            [.requested, .snapshotting, .snapshotReady, .stagingCreated,
             .converting, .verifying, .manifestWritten]
        )
        XCTAssertTrue(states.contains(.stagingValidated))
    }

    @MainActor
    func testRunnerFailureMarksJournalAndRemovesOnlyItsStagingDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidSource = root.appendingPathComponent("invalid-v3.sqlite")
        try Data("not a sqlite database".utf8).write(to: invalidSource)
        let controlURL = root.appendingPathComponent("control", isDirectory: true)
        let ownerLockURL = controlURL.appendingPathComponent("migration-owner.lock")
        let journal = V4MigrationJournalRepository(
            fileURL: controlURL.appendingPathComponent("journal.json"),
            ownerLockURL: ownerLockURL
        )
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let stagingManager = V4MigrationStagingStoreManager(rootURL: stagingRoot)
        let lifecycle = V4MigrationSnapshotLifecycleCoordinator(
            journal: journal,
            stagingManager: stagingManager,
            ownerLockURL: ownerLockURL
        )
        let unrelated = stagingRoot.appendingPathComponent("keep-unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        do {
            _ = try await V4MigrationAttemptRunner.run(
                sourceV3StoreURL: invalidSource,
                runID: "runner-failure",
                idempotencyKey: "runner-failure-request",
                stagingStoreID: "runner-failure-stage",
                at: epoch,
                lifecycle: lifecycle,
                stagingManager: stagingManager,
                journal: journal,
                ownerLockURL: ownerLockURL
            )
            XCTFail("Expected invalid SQLite source to fail")
        } catch {
            XCTAssertTrue(
                error is SQLiteStoreSnapshotCopier.CopyError ||
                error is SQLiteStoreIntegrityChecker.CheckError
            )
        }

        let record = try await journal.record(runID: "runner-failure")
        XCTAssertEqual(record?.state, .failed)
        let failedDirectory = stagingRoot.appendingPathComponent(
            "run-runner-failure-staging-runner-failure-stage",
            isDirectory: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidSource.path))
    }

    @MainActor
    func testRunnerRecoversInterruptedAttemptBeforeStartingNewOne() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try makeV3Store(in: root, gameID: "recovery-game")
        let controlURL = root.appendingPathComponent("control", isDirectory: true)
        let ownerLockURL = controlURL.appendingPathComponent("migration-owner.lock")
        let journal = V4MigrationJournalRepository(
            fileURL: controlURL.appendingPathComponent("journal.json"),
            ownerLockURL: ownerLockURL
        )
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let stagingManager = V4MigrationStagingStoreManager(rootURL: stagingRoot)
        let lifecycle = V4MigrationSnapshotLifecycleCoordinator(
            journal: journal,
            stagingManager: stagingManager,
            ownerLockURL: ownerLockURL
        )

        _ = try await journal.createOrGet(
            runID: "interrupted-before-run",
            idempotencyKey: "interrupted-request",
            sourceSchemaVersion: "3",
            destinationSchemaVersion: "4.0.0",
            at: epoch,
            stagingStoreID: "interrupted-stage"
        )
        _ = try await journal.transition(
            runID: "interrupted-before-run",
            from: .requested,
            to: .snapshotting,
            at: epoch,
            code: "test.interrupted"
        )
        let interruptedDirectory = stagingRoot.appendingPathComponent(
            "run-interrupted-before-run-staging-interrupted-stage",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: interruptedDirectory,
            withIntermediateDirectories: true
        )

        _ = try await V4MigrationAttemptRunner.run(
            sourceV3StoreURL: sourceURL,
            runID: "recovery-new-run",
            idempotencyKey: "recovery-new-request",
            stagingStoreID: "recovery-new-stage",
            at: epoch.addingTimeInterval(1),
            lifecycle: lifecycle,
            stagingManager: stagingManager,
            journal: journal,
            ownerLockURL: ownerLockURL
        )

        let interruptedRecord = try await journal.record(runID: "interrupted-before-run")
        XCTAssertEqual(interruptedRecord?.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: interruptedDirectory.path))
        let newRecord = try await journal.record(runID: "recovery-new-run")
        XCTAssertTrue(
            newRecord?.state == .stagingValidated ||
            newRecord?.state == .eligibleForIndependentSafetyGates
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "V4MigrationAttemptRunner-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func makeV3Store(in directory: URL, gameID: String) throws -> URL {
        let storeURL = directory.appendingPathComponent("\(gameID).sqlite")
        let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
        let configuration = ModelConfiguration(
            "V4MigrationAttemptRunnerSource-\(UUID().uuidString)",
            schema: schema,
            url: storeURL
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.insert(DBGame(id: gameID, title: "Runner fixture"))
        try container.mainContext.save()
        return storeURL
    }
}

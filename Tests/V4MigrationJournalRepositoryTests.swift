import XCTest
@testable import itchPocket

final class V4MigrationJournalRepositoryTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("V4JournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("journal.json")
    }

    func testCreateIsIdempotentAndSurvivesRepositoryRestart() async throws {
        let url = try temporaryStoreURL()
        let firstRepository = V4MigrationJournalRepository(fileURL: url)
        let first = try await firstRepository.createOrGet(
            runID: "run-a", idempotencyKey: "request-a",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4", at: epoch
        )
        XCTAssertTrue(first.wasCreated)

        let replay = try await firstRepository.createOrGet(
            runID: "run-b", idempotencyKey: "request-a",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4",
            at: epoch.addingTimeInterval(10)
        )
        XCTAssertFalse(replay.wasCreated)
        XCTAssertEqual(replay.record.runID, "run-a")

        let restartedRepository = V4MigrationJournalRepository(fileURL: url)
        let restored = try await restartedRepository.record(runID: "run-a")
        XCTAssertEqual(restored, first.record)
        let events = try await restartedRepository.events(runID: "run-a")
        XCTAssertEqual(events.map(\.sequence), [1])
        XCTAssertEqual(events.first?.toState, .requested)
    }

    func testTransitionAtomicallyPersistsRecordAndEventAndReplayIsIdempotent() async throws {
        let url = try temporaryStoreURL()
        let repository = V4MigrationJournalRepository(fileURL: url)
        _ = try await repository.createOrGet(
            runID: "run-a", idempotencyKey: "request-a",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4", at: epoch
        )

        let transitioned = try await repository.transition(
            runID: "run-a", from: .requested, to: .snapshotting,
            at: epoch.addingTimeInterval(1), code: "snapshot.started"
        )
        let replay = try await repository.transition(
            runID: "run-a", from: .requested, to: .snapshotting,
            at: epoch.addingTimeInterval(2), code: "snapshot.started"
        )
        XCTAssertEqual(replay, transitioned)

        let restarted = V4MigrationJournalRepository(fileURL: url)
        let restored = try await restarted.record(runID: "run-a")
        XCTAssertEqual(restored?.state, .snapshotting)
        let events = try await restarted.events(runID: "run-a")
        XCTAssertEqual(events.map(\.sequence), [1, 2])
        XCTAssertEqual(events.last?.fromState, .requested)
        XCTAssertEqual(events.last?.toState, .snapshotting)
    }

    func testConcurrentStateMismatchIsRejected() async throws {
        let repository = V4MigrationJournalRepository(fileURL: try temporaryStoreURL())
        _ = try await repository.createOrGet(
            runID: "run-a", idempotencyKey: "request-a",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4", at: epoch
        )
        _ = try await repository.transition(
            runID: "run-a", from: .requested, to: .snapshotting,
            at: epoch, code: "snapshot.started"
        )

        do {
            _ = try await repository.transition(
                runID: "run-a", from: .requested, to: .snapshotting,
                at: epoch, code: "different.request"
            )
            XCTFail("Expected stale state to be rejected")
        } catch {
            XCTAssertEqual(error as? V4MigrationJournalRepository.RepositoryError, .stateConflict)
        }
    }

    func testFailedWriteDoesNotPersistPartialEvent() async throws {
        enum WriteFailure: Error { case injected }
        let url = try temporaryStoreURL()
        let repository = V4MigrationJournalRepository(
            fileURL: url,
            writeData: { _, _ in throw WriteFailure.injected }
        )

        do {
            _ = try await repository.createOrGet(
                runID: "run-a", idempotencyKey: "request-a",
                sourceSchemaVersion: "3", destinationSchemaVersion: "4", at: epoch
            )
            XCTFail("Expected injected write failure")
        } catch {
            XCTAssertTrue(error is WriteFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTransitionWriteFailureKeepsLastCommittedRecordAndEventHistory() async throws {
        enum WriteFailure: Error { case injected }
        let url = try temporaryStoreURL()
        let repository = V4MigrationJournalRepository(
            fileURL: url,
            writeData: { data, destination in
                let serialized = String(decoding: data, as: UTF8.self)
                if serialized.contains("\"state\":\"snapshotting\"") {
                    throw WriteFailure.injected
                }
                try data.write(to: destination, options: [.atomic])
            }
        )
        _ = try await repository.createOrGet(
            runID: "run-a", idempotencyKey: "request-a",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4", at: epoch
        )

        do {
            _ = try await repository.transition(
                runID: "run-a", from: .requested, to: .snapshotting,
                at: epoch.addingTimeInterval(1), code: "snapshot.started"
            )
            XCTFail("Expected injected transition write failure")
        } catch {
            XCTAssertTrue(error is WriteFailure)
        }

        let current = try await repository.record(runID: "run-a")
        XCTAssertEqual(current?.state, .requested)
        let events = try await repository.events(runID: "run-a")
        XCTAssertEqual(events.map(\.sequence), [1])

        let restarted = V4MigrationJournalRepository(fileURL: url)
        let restartedRecord = try await restarted.record(runID: "run-a")
        let restartedEvents = try await restarted.events(runID: "run-a")
        XCTAssertEqual(restartedRecord?.state, .requested)
        XCTAssertEqual(restartedEvents.map(\.sequence), [1])
    }

    func testCorruptJournalFailsClosedWithoutReplacingTheFile() async throws {
        let url = try temporaryStoreURL()
        let corruptBytes = Data("not-a-valid-journal".utf8)
        try corruptBytes.write(to: url)

        let repository = V4MigrationJournalRepository(fileURL: url)
        do {
            _ = try await repository.allRecords()
            XCTFail("Expected corrupt journal to be rejected")
        } catch {
            XCTAssertEqual(error as? V4MigrationJournalRepository.RepositoryError, .corruptStore)
        }
        XCTAssertEqual(try Data(contentsOf: url), corruptBytes)
    }

    func testUnsafePersistedEventCodeIsRejectedDuringRecovery() async throws {
        let url = try temporaryStoreURL()
        let repository = V4MigrationJournalRepository(fileURL: url)
        _ = try await repository.createOrGet(
            runID: "run-a", idempotencyKey: "request-a",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4", at: epoch
        )
        let bytes = try Data(contentsOf: url)
        var serialized = String(decoding: bytes, as: UTF8.self)
        serialized = serialized.replacingOccurrences(
            of: "migration.requested",
            with: "private/path"
        )
        try Data(serialized.utf8).write(to: url, options: [.atomic])

        let restarted = V4MigrationJournalRepository(fileURL: url)
        do {
            _ = try await restarted.allRecords()
            XCTFail("Expected unsafe event code to be rejected")
        } catch {
            XCTAssertEqual(error as? V4MigrationJournalRepository.RepositoryError, .corruptStore)
        }
    }

    func testIdempotencyKeyCannotBeReusedForDifferentSchemaRequest() async throws {
        let repository = V4MigrationJournalRepository(fileURL: try temporaryStoreURL())
        _ = try await repository.createOrGet(
            runID: "run-a", idempotencyKey: "request-a",
            sourceSchemaVersion: "3", destinationSchemaVersion: "4", at: epoch
        )
        do {
            _ = try await repository.createOrGet(
                runID: "run-b", idempotencyKey: "request-a",
                sourceSchemaVersion: "3", destinationSchemaVersion: "5", at: epoch
            )
            XCTFail("Expected idempotency conflict")
        } catch {
            XCTAssertEqual(error as? V4MigrationJournalRepository.RepositoryError, .idempotencyKeyConflict)
        }
    }
}

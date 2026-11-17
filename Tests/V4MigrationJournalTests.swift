import XCTest
@testable import itchPocket

final class V4MigrationJournalTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func testNewRunStartsOnlyAtRequested() {
        XCTAssertTrue(V4MigrationJournalStateMachine.canTransition(from: nil, to: .requested))
        XCTAssertFalse(V4MigrationJournalStateMachine.canTransition(from: nil, to: .snapshotting))
        XCTAssertFalse(V4MigrationJournalStateMachine.canTransition(from: nil, to: .failed))
    }

    func testHappyPathRequiresEveryLifecycleGate() throws {
        let path: [V4MigrationJournalState] = [
            .requested, .snapshotting, .snapshotReady, .stagingCreated,
            .converting, .verifying, .manifestWritten, .stagingValidated,
            .eligibleForIndependentSafetyGates
        ]

        for pair in zip(path, path.dropFirst()) {
            XCTAssertTrue(
                V4MigrationJournalStateMachine.canTransition(from: pair.0, to: pair.1),
                "Expected valid transition \(pair.0) → \(pair.1)"
            )
        }
    }

    func testCannotSkipRequiredStatesOrMoveBackwards() {
        XCTAssertFalse(V4MigrationJournalStateMachine.canTransition(from: .requested, to: .snapshotReady))
        XCTAssertFalse(V4MigrationJournalStateMachine.canTransition(from: .converting, to: .stagingCreated))
        XCTAssertFalse(V4MigrationJournalStateMachine.canTransition(from: .manifestWritten, to: .verifying))
        XCTAssertFalse(V4MigrationJournalStateMachine.canTransition(from: .stagingValidated, to: .converting))
    }

    func testFailureAndAbandonmentAreTerminal() {
        for state in V4MigrationJournalState.allCases where !state.isTerminal {
            XCTAssertTrue(V4MigrationJournalStateMachine.canTransition(from: state, to: .failed))
            XCTAssertTrue(V4MigrationJournalStateMachine.canTransition(from: state, to: .abandoned))
        }
        for state in [V4MigrationJournalState.failed, .abandoned, .superseded, .eligibleForIndependentSafetyGates] {
            XCTAssertTrue(state.isTerminal)
            XCTAssertFalse(V4MigrationJournalStateMachine.canTransition(from: state, to: .requested))
            XCTAssertFalse(V4MigrationJournalStateMachine.canTransition(from: state, to: .failed))
        }
    }

    func testTransitionProducesUpdatedRecordAndMonotonicEventSequence() throws {
        let initial = V4MigrationJournalRecord(
            runID: "run-001",
            idempotencyKey: "operation-001",
            sourceSchemaVersion: "3.0.0",
            destinationSchemaVersion: "4.0.0",
            createdAt: epoch
        )
        let nextDate = epoch.addingTimeInterval(5)
        let result = try initial.transitioning(
            to: .snapshotting,
            at: nextDate,
            sequence: 2,
            code: "snapshot.started"
        )

        XCTAssertEqual(result.record.state, .snapshotting)
        XCTAssertEqual(result.record.updatedAt, nextDate)
        XCTAssertEqual(result.record.runID, initial.runID)
        XCTAssertEqual(result.event.runID, initial.runID)
        XCTAssertEqual(result.event.sequence, 2)
        XCTAssertEqual(result.event.fromState, .requested)
        XCTAssertEqual(result.event.toState, .snapshotting)
        XCTAssertEqual(result.event.code, "snapshot.started")
        XCTAssertEqual(initial.state, .requested, "Value transition must not mutate original record")
    }

    func testRejectsInvalidTransitionAndUnsafeDiagnosticCode() throws {
        let initial = V4MigrationJournalRecord(
            runID: "run-002",
            idempotencyKey: "operation-002",
            sourceSchemaVersion: "3.0.0",
            destinationSchemaVersion: "4.0.0",
            createdAt: epoch
        )

        XCTAssertThrowsError(try initial.transitioning(
            to: .snapshotReady, at: epoch, sequence: 1, code: "snapshot.ready"
        )) { error in
            XCTAssertEqual(error as? V4MigrationJournalRecord.TransitionError, .invalidTransition)
        }

        XCTAssertThrowsError(try initial.transitioning(
            to: .snapshotting, at: epoch, sequence: 1, code: "private note: user@example.com"
        )) { error in
            XCTAssertEqual(error as? V4MigrationJournalRecord.TransitionError, .invalidDiagnosticCode)
        }

        XCTAssertThrowsError(try initial.transitioning(
            to: .snapshotting, at: epoch, sequence: 0, code: "snapshot.started"
        )) { error in
            XCTAssertEqual(error as? V4MigrationJournalRecord.TransitionError, .invalidSequence)
        }
    }

    func testJournalRecordSerializationContainsOnlyExplicitMetadata() throws {
        let record = V4MigrationJournalRecord(
            runID: "opaque-run-id",
            idempotencyKey: "opaque-operation-key",
            sourceSchemaVersion: "3.0.0",
            destinationSchemaVersion: "4.0.0",
            createdAt: epoch
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("opaque-run-id"))
        XCTAssertTrue(json.contains("requested"))
        XCTAssertFalse(json.contains("access_token"))
        XCTAssertFalse(json.contains("oauth"))
        XCTAssertFalse(json.contains("private note"))
        XCTAssertFalse(json.contains("/var/mobile"))
    }
}

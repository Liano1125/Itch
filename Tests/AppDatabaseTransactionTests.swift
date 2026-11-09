import XCTest
import SwiftData
@testable import itchPocket

final class AppDatabaseTransactionTests: XCTestCase {
    private enum TestError: Error {
        case simulatedFailure
    }

    @MainActor
    func testFailedTransactionRollsBackOnlyItsOwnCleanContextChanges() throws {
        let database = try AppDatabase(inMemory: true)

        XCTAssertThrowsError(try database.performTransaction {
            database.context.insert(DBAppState(key: "transaction.partial", stringValue: "discard"))
            throw TestError.simulatedFailure
        })

        XCTAssertFalse(database.context.hasChanges)
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBAppState>()).isEmpty)
    }

    @MainActor
    func testTransactionRefusesToRollbackPreexistingPendingChanges() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBAppState(key: "unrelated.pending", stringValue: "preserve"))

        XCTAssertThrowsError(try database.performTransaction {
            database.context.insert(DBAppState(key: "transaction.partial", stringValue: "discard"))
        }) { error in
            XCTAssertTrue(error is AppDatabase.TransactionError)
        }

        XCTAssertTrue(database.context.hasChanges)
        let pending = try database.context.fetch(FetchDescriptor<DBAppState>())
        XCTAssertEqual(Set(pending.map(\.key)), ["unrelated.pending"])
        try database.save()
        XCTAssertEqual(try database.context.fetch(FetchDescriptor<DBAppState>()).map(\.key), ["unrelated.pending"])
    }

    @MainActor
    func testSuccessfulTransactionSavesAllChangesTogether() throws {
        let database = try AppDatabase(inMemory: true)

        try database.performTransaction {
            database.context.insert(DBAppState(key: "transaction.first", stringValue: "one"))
            database.context.insert(DBAppState(key: "transaction.second", stringValue: "two"))
        }

        XCTAssertFalse(database.context.hasChanges)
        XCTAssertEqual(
            Set(try database.context.fetch(FetchDescriptor<DBAppState>()).map(\.key)),
            ["transaction.first", "transaction.second"]
        )
    }
}

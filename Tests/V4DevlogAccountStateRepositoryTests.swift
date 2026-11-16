import XCTest
import SwiftData
@testable import itchPocket

final class V4DevlogAccountStateRepositoryTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-devlog-state-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    private func identity(_ userID: Int) -> ItchAccountIdentity {
        ItchAccountIdentity(itchUserID: userID, username: "user-\(userID)")
    }

    @MainActor
    func testHistoricalSyncAndThrottleAreIsolatedBetweenAccounts() throws {
        let container = try makeContainer()
        let repository = V4DevlogAccountStateRepository(context: container.mainContext)
        let session = ItchAccountSession()

        session.activate(identity(101))
        let accountA = try XCTUnwrap(session.captureRequestContext())
        let dateA = Date(timeIntervalSince1970: 1_700_000_101)
        try repository.saveHistoricalSyncState(
            lastSyncAt: dateA,
            message: "Account A completed",
            resultsData: Data([1, 0, 1]),
            for: accountA,
            session: session
        )
        try repository.setAutoSyncAttempt(dateA, for: accountA, session: session)

        session.activate(identity(202))
        let accountB = try XCTUnwrap(session.captureRequestContext())
        let dateB = Date(timeIntervalSince1970: 1_700_000_202)
        try repository.saveHistoricalSyncState(
            lastSyncAt: dateB,
            message: "Account B completed",
            resultsData: Data([2, 0, 2]),
            for: accountB,
            session: session
        )
        try repository.setAutoSyncAttempt(dateB, for: accountB, session: session)

        XCTAssertEqual(
            try repository.historicalSyncState(for: accountB, session: session),
            V4DevlogHistoricalSyncState(
                lastSyncAt: dateB,
                lastMessage: "Account B completed",
                resultsData: Data([2, 0, 2])
            )
        )
        XCTAssertEqual(try repository.lastAutoSyncAttempt(for: accountB, session: session), dateB)

        session.activate(identity(101))
        let restoredA = try XCTUnwrap(session.captureRequestContext())
        XCTAssertEqual(
            try repository.historicalSyncState(for: restoredA, session: session),
            V4DevlogHistoricalSyncState(
                lastSyncAt: dateA,
                lastMessage: "Account A completed",
                resultsData: Data([1, 0, 1])
            )
        )
        XCTAssertEqual(try repository.lastAutoSyncAttempt(for: restoredA, session: session), dateA)
    }

    @MainActor
    func testStaleAccountContextCannotReadOrWriteAfterSwitch() throws {
        let container = try makeContainer()
        let repository = V4DevlogAccountStateRepository(context: container.mainContext)
        let session = ItchAccountSession()

        session.activate(identity(303))
        let accountA = try XCTUnwrap(session.captureRequestContext())
        try repository.setAutoSyncAttempt(
            Date(timeIntervalSince1970: 1_700_000_303),
            for: accountA,
            session: session
        )

        session.activate(identity(404))
        XCTAssertThrowsError(try repository.lastAutoSyncAttempt(for: accountA, session: session))
        XCTAssertThrowsError(
            try repository.saveHistoricalSyncState(
                lastSyncAt: .now,
                message: "must not be written",
                resultsData: Data([4]),
                for: accountA,
                session: session
            )
        )

        let accountB = try XCTUnwrap(session.captureRequestContext())
        XCTAssertNil(try repository.lastAutoSyncAttempt(for: accountB, session: session))
        XCTAssertNil(try repository.historicalSyncState(for: accountB, session: session).lastMessage)
    }

    @MainActor
    func testSignedOutSessionCannotUseAccountScopedDevlogState() throws {
        let container = try makeContainer()
        let repository = V4DevlogAccountStateRepository(context: container.mainContext)
        let session = ItchAccountSession()

        session.activate(identity(505))
        let context = try XCTUnwrap(session.captureRequestContext())
        session.activate(nil)

        XCTAssertThrowsError(try repository.historicalSyncState(for: context, session: session))
        XCTAssertThrowsError(try repository.setAutoSyncAttempt(.now, for: context, session: session))
    }

    @MainActor
    func testOldGenerationCannotAccessAfterSameAccountSignsOutAndBackIn() throws {
        let container = try makeContainer()
        let repository = V4DevlogAccountStateRepository(context: container.mainContext)
        let session = ItchAccountSession()
        let account = identity(606)

        session.activate(account)
        let originalContext = try XCTUnwrap(session.captureRequestContext())
        try repository.setAutoSyncAttempt(
            Date(timeIntervalSince1970: 1_700_000_606),
            for: originalContext,
            session: session
        )

        session.activate(nil)
        session.activate(account)
        let renewedContext = try XCTUnwrap(session.captureRequestContext())

        XCTAssertNotEqual(originalContext.generation, renewedContext.generation)
        XCTAssertThrowsError(
            try repository.lastAutoSyncAttempt(for: originalContext, session: session)
        )
        XCTAssertThrowsError(
            try repository.saveHistoricalSyncState(
                lastSyncAt: .now,
                message: "stale generation",
                resultsData: Data([6]),
                for: originalContext,
                session: session
            )
        )
        XCTAssertNil(try repository.historicalSyncState(
            for: renewedContext,
            session: session
        ).lastMessage)
    }

}

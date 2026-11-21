import XCTest
import SwiftData
@testable import itchPocket

final class ScopedAppStateRepositoryTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-scoped-appstate-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        for userID in [1, 2, 7, 11, 22, 101, 202, 303, 404, 505, 606, 707] {
            container.mainContext.insert(DBAccount(itchUserID: userID, username: "test-\\(userID)"))
        }
        try container.mainContext.save()
        return container
    }

    @MainActor
    func testSameLogicalKeyIsIndependentAcrossTwoItchAccounts() throws {
        let container = try makeContainer()
        let repository = ScopedAppStateRepository(context: container.mainContext)
        let accountA = try AppStateScope.itchAccount(userID: 101)
        let accountB = try AppStateScope.itchAccount(userID: 202)

        try repository.setString("A", for: "devlogSync.lastMessage", in: accountA)
        try repository.setString("B", for: "devlogSync.lastMessage", in: accountB)

        XCTAssertEqual(try repository.state(for: "devlogSync.lastMessage", in: accountA)?.stringValue, "A")
        XCTAssertEqual(try repository.state(for: "devlogSync.lastMessage", in: accountB)?.stringValue, "B")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBScopedAppState>()), 2)
    }

    @MainActor
    func testDeviceAppGlobalItchAndPatreonScopesAreIndependent() throws {
        let container = try makeContainer()
        let repository = ScopedAppStateRepository(context: container.mainContext)
        let itch = try AppStateScope.itchAccount(userID: 7)
        let patreon = try AppStateScope.patreonAccount(accountID: "creator-7")

        try repository.setString("device", for: "same", in: .device)
        try repository.setString("global", for: "same", in: .appGlobal)
        try repository.setString("itch", for: "same", in: itch)
        try repository.setString("patreon", for: "same", in: patreon)

        XCTAssertEqual(try repository.state(for: "same", in: .device)?.stringValue, "device")
        XCTAssertEqual(try repository.state(for: "same", in: .appGlobal)?.stringValue, "global")
        XCTAssertEqual(try repository.state(for: "same", in: itch)?.stringValue, "itch")
        XCTAssertEqual(try repository.state(for: "same", in: patreon)?.stringValue, "patreon")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBScopedAppState>()), 4)
    }

    @MainActor
    func testPrefixDeletionIsLimitedToTheRequestedScope() throws {
        let container = try makeContainer()
        let repository = ScopedAppStateRepository(context: container.mainContext)
        let accountA = try AppStateScope.itchAccount(userID: 1)
        let accountB = try AppStateScope.itchAccount(userID: 2)

        try repository.setString("a1", for: "avatarFailure.one", in: accountA)
        try repository.setString("a2", for: "avatarFailure.two", in: accountA)
        try repository.setString("b1", for: "avatarFailure.one", in: accountB)
        try repository.setString("keep", for: "devlogSync.lastMessage", in: accountA)

        try repository.removeAll(matchingKeyPrefix: "avatarFailure.", in: accountA)

        XCTAssertNil(try repository.state(for: "avatarFailure.one", in: accountA))
        XCTAssertNil(try repository.state(for: "avatarFailure.two", in: accountA))
        XCTAssertEqual(try repository.state(for: "avatarFailure.one", in: accountB)?.stringValue, "b1")
        XCTAssertEqual(try repository.state(for: "devlogSync.lastMessage", in: accountA)?.stringValue, "keep")
    }

    @MainActor
    func testSnapshotRestoreIsScopedAndRejectsCrossAccountSnapshot() throws {
        let container = try makeContainer()
        let repository = ScopedAppStateRepository(context: container.mainContext)
        let accountA = try AppStateScope.itchAccount(userID: 11)
        let accountB = try AppStateScope.itchAccount(userID: 22)

        try repository.setString("before", for: "key", in: accountA)
        let snapshot = try XCTUnwrap(repository.state(for: "key", in: accountA))
        try repository.setString("after", for: "key", in: accountA)
        try repository.restore(snapshot, for: "key", in: accountA)

        XCTAssertEqual(try repository.state(for: "key", in: accountA)?.stringValue, "before")
        XCTAssertThrowsError(try repository.restore(snapshot, for: "key", in: accountB))
        XCTAssertNil(try repository.state(for: "key", in: accountB))
    }

    @MainActor
    func testUnknownLegacyRowsRemainUntouchedAndUnassigned() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let legacy = DBAppState(
            key: "futureFeature.privateState",
            stringValue: "legacy-payload",
            dataValue: Data([9, 8, 7])
        )
        context.insert(legacy)
        try context.save()

        let repository = ScopedAppStateRepository(context: context)
        XCTAssertNil(try repository.state(for: "futureFeature.privateState", in: .legacyUnclassified))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAppState>()), 1)
        let preserved = try XCTUnwrap(context.fetch(FetchDescriptor<DBAppState>()).first)
        XCTAssertEqual(preserved.stringValue, "legacy-payload")
        XCTAssertEqual(preserved.dataValue, Data([9, 8, 7]))
    }

    @MainActor
    func testRollbackRestoresPreviouslyCommittedScopedValue() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = ScopedAppStateRepository(context: context)
        let account = try AppStateScope.itchAccount(userID: 303)

        try repository.setString("committed", for: "rollback", in: account)
        try repository.setString("uncommitted", for: "rollback", in: account, save: false)
        context.rollback()

        XCTAssertEqual(try repository.state(for: "rollback", in: account)?.stringValue, "committed")
    }

    @MainActor
    func testScopeFactoriesRejectInvalidAccountIdentities() throws {
        XCTAssertThrowsError(try AppStateScope.itchAccount(userID: 0))
        XCTAssertThrowsError(try AppStateScope.patreonAccount(accountID: "  "))
    }

    @MainActor
    func testEmptyKeysAreRejected() throws {
        let container = try makeContainer()
        let repository = ScopedAppStateRepository(context: container.mainContext)
        XCTAssertThrowsError(try repository.setString("x", for: "  ", in: .device))
    }

    @MainActor
    func testTypedWritesReplacePreviousValueTypes() throws {
        let container = try makeContainer()
        let repository = ScopedAppStateRepository(context: container.mainContext)
        let scope = try AppStateScope.itchAccount(userID: 404)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data([0, 1, 2, 255])

        try repository.setString("first", for: "typed", in: scope)
        try repository.setDate(date, for: "typed", in: scope)
        var state = try XCTUnwrap(repository.state(for: "typed", in: scope))
        XCTAssertNil(state.stringValue)
        XCTAssertEqual(state.dateValue, date)
        XCTAssertNil(state.dataValue)

        try repository.setData(data, for: "typed", in: scope)
        state = try XCTUnwrap(repository.state(for: "typed", in: scope))
        XCTAssertNil(state.stringValue)
        XCTAssertNil(state.dateValue)
        XCTAssertEqual(state.dataValue, data)

        try repository.setString("final", for: "typed", in: scope)
        state = try XCTUnwrap(repository.state(for: "typed", in: scope))
        XCTAssertEqual(state.stringValue, "final")
        XCTAssertNil(state.dateValue)
        XCTAssertNil(state.dataValue)
    }

    @MainActor
    func testDateSnapshotCanBeRestoredAfterDataOverwrite() throws {
        let container = try makeContainer()
        let repository = ScopedAppStateRepository(context: container.mainContext)
        let scope = try AppStateScope.itchAccount(userID: 505)
        let date = Date(timeIntervalSince1970: 1_710_000_000)

        try repository.setDate(date, for: "snapshot", in: scope)
        let snapshot = try XCTUnwrap(repository.state(for: "snapshot", in: scope))
        try repository.setData(Data([4, 5, 6]), for: "snapshot", in: scope)
        try repository.restore(snapshot, for: "snapshot", in: scope, save: true)

        let restored = try XCTUnwrap(repository.state(for: "snapshot", in: scope))
        XCTAssertEqual(restored.dateValue, date)
        XCTAssertNil(restored.stringValue)
        XCTAssertNil(restored.dataValue)
    }

    @MainActor
    func testRestoringNilSnapshotDeletesOnlyTheRequestedScopedRow() throws {
        let container = try makeContainer()
        let repository = ScopedAppStateRepository(context: container.mainContext)
        let accountA = try AppStateScope.itchAccount(userID: 606)
        let accountB = try AppStateScope.itchAccount(userID: 707)

        try repository.setData(Data([7, 7]), for: "remove-me", in: accountA)
        try repository.setString("keep", for: "remove-me", in: accountB)
        try repository.restore(nil, for: "remove-me", in: accountA, save: true)

        XCTAssertNil(try repository.state(for: "remove-me", in: accountA))
        XCTAssertEqual(try repository.state(for: "remove-me", in: accountB)?.stringValue, "keep")
    }

}

import XCTest
import SwiftData
import UserNotifications
@testable import itchPocket

@MainActor
private final class FakeV4RemovalNotificationCenter: AccountCalendarNotificationCenterClient {
    var pending = Set<String>()
    var delivered = Set<String>()
    var removedPending = Set<String>()
    var removedDelivered = Set<String>()

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async -> Bool { true }
    func pendingIdentifiers() async -> Set<String> { pending }
    func deliveredIdentifiers() async -> Set<String> { delivered }
    func removePending(identifiers: [String]) async {
        removedPending.formUnion(identifiers)
        pending.subtract(identifiers)
    }
    func removeDelivered(identifiers: [String]) async {
        removedDelivered.formUnion(identifiers)
        delivered.subtract(identifiers)
    }
    func add(_ request: UNNotificationRequest) async throws {
        pending.insert(request.identifier)
    }
}

final class V4AccountRemovalRepositoryTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-account-removal-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    func testExplicitRemovalDeletesOnlySelectedAccountsPersonalRows() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let accountA = DBAccount(itchUserID: 811, username: "account-a")
        let accountB = DBAccount(itchUserID: 812, username: "account-b")
        context.insert(accountA)
        context.insert(accountB)
        context.insert(DBGame(id: "shared-game", title: "Shared"))
        context.insert(DBGameUpdate(id: "shared-update", gameID: "shared-game", summary: "Shared update"))
        context.insert(DBCalendarSourceEvent(sourceFingerprint: "shared-source", gameID: "shared-game", kind: "release"))

        context.insert(ItchPocketSchemaV4.DBLibraryEntry(accountID: accountA.id, gameID: "shared-game", status: "playing"))
        context.insert(ItchPocketSchemaV4.DBLibraryEntry(accountID: accountB.id, gameID: "shared-game", status: "completed"))
        context.insert(ItchPocketSchemaV4.DBLibraryEntry(accountID: nil, gameID: "legacy-game", status: "playing"))
        context.insert(ItchPocketSchemaV4.DBLibraryCollection(accountID: accountA.id, collectionKey: "a", title: "A"))
        context.insert(ItchPocketSchemaV4.DBLibraryCollection(accountID: accountB.id, collectionKey: "b", title: "B"))
        context.insert(ItchPocketSchemaV4.DBLibraryCollectionItem(accountID: accountA.id, collectionKey: "a", gameID: "shared-game", sortOrder: 0))
        context.insert(ItchPocketSchemaV4.DBLibraryCollectionItem(accountID: accountB.id, collectionKey: "b", gameID: "shared-game", sortOrder: 0))
        context.insert(ItchPocketSchemaV4.DBLibraryStatusEvent(accountID: accountA.id, eventKey: "a-event", gameID: "shared-game", fromStatus: nil, toStatus: "playing"))
        context.insert(ItchPocketSchemaV4.DBLibraryStatusEvent(accountID: accountB.id, eventKey: "b-event", gameID: "shared-game", fromStatus: nil, toStatus: "completed"))
        context.insert(DBAccountCalendarEvent(accountID: accountA.id, eventKey: "a-calendar", gameID: "shared-game", kind: "personal"))
        context.insert(DBAccountCalendarEvent(accountID: accountB.id, eventKey: "b-calendar", gameID: "shared-game", kind: "personal"))
        context.insert(DBAccountCalendarOverlay(accountID: accountA.id, sourceEventID: DBCalendarSourceEvent.stableID(sourceFingerprint: "shared-source")))
        context.insert(DBAccountCalendarOverlay(accountID: accountB.id, sourceEventID: DBCalendarSourceEvent.stableID(sourceFingerprint: "shared-source")))
        context.insert(DBAccountUpdateWatch(accountID: accountA.id, gameID: "shared-game"))
        context.insert(DBAccountUpdateWatch(accountID: accountB.id, gameID: "shared-game"))
        context.insert(DBLegacyCalendarEvent(copying: DBCalendarEvent(id: "legacy-calendar", gameID: "shared-game", kind: "legacy")))
        context.insert(DBLegacyUpdateWatch(originalGameID: "legacy-game", integrityIssue: "missing-game"))
        let stateA = try AppStateScope.itchAccount(userID: 811)
        let stateB = try AppStateScope.itchAccount(userID: 812)
        let appState = ScopedAppStateRepository(context: context)
        try appState.setString("private-a", for: "private-key", in: stateA, save: false)
        try appState.setString("private-b", for: "private-key", in: stateB, save: false)
        try appState.setString("device-pref", for: "appearance", in: .device, save: false)
        try context.save()

        let report = try V4AccountRemovalRepository(context: context, session: ItchAccountSession())
            .removeAccountAndPersonalData(itchUserID: 811)

        XCTAssertEqual(report, .init(
            accountID: "itch:811", libraryEntries: 1, collections: 1,
            collectionItems: 1, libraryStatusEvents: 1, calendarEvents: 1,
            calendarOverlays: 1, updateWatches: 1, scopedAppStates: 1
        ))
        XCTAssertEqual(try context.fetch(FetchDescriptor<DBAccount>()).map(\.id), ["itch:812"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()).count, 2,
                       "Other account and unassigned legacy library rows must survive.")
        XCTAssertEqual(try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()).filter { $0.accountID == "itch:812" }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>()).map(\.accountID), ["itch:812"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollectionItem>()).map(\.accountID), ["itch:812"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryStatusEvent>()).map(\.accountID), ["itch:812"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<DBAccountCalendarEvent>()).map(\.accountID), ["itch:812"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<DBAccountCalendarOverlay>()).map(\.accountID), ["itch:812"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<DBAccountUpdateWatch>()).map(\.accountID), ["itch:812"])
        XCTAssertNil(try appState.state(for: "private-key", in: stateA))
        XCTAssertEqual(try appState.state(for: "private-key", in: stateB)?.stringValue, "private-b")
        XCTAssertEqual(try appState.state(for: "appearance", in: .device)?.stringValue, "device-pref")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGame>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGameUpdate>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBCalendarSourceEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBLegacyCalendarEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBLegacyUpdateWatch>()), 1)

        // Re-authentication recreates only the account registry entry. Explicitly
        // removed personal rows must not silently reappear on the next login.
        let registry = V4AccountRegistryRepository(context: context)
        let reauthenticated = try registry.recordAuthenticatedIdentity(
            ItchAccountIdentity(itchUserID: 811, username: "account-a-returned")
        )
        XCTAssertEqual(reauthenticated.id, "itch:811")
        XCTAssertEqual(reauthenticated.username, "account-a-returned")
        XCTAssertEqual(try context.fetch(FetchDescriptor<DBAccount>()).count, 2)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>())
                .filter { $0.accountID == "itch:811" }.count,
            0
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<DBAccountCalendarEvent>())
                .filter { $0.accountID == "itch:811" }.count,
            0
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<DBAccountUpdateWatch>())
                .filter { $0.accountID == "itch:811" }.count,
            0
        )
        XCTAssertNil(try appState.state(for: "private-key", in: stateA))
    }

    @MainActor
    func testRemovalRejectsInvalidOrUnknownAccountWithoutMutation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBAccount(itchUserID: 813, username: "keep"))
        try context.save()
        let repository = V4AccountRemovalRepository(context: context, session: ItchAccountSession())

        XCTAssertThrowsError(try repository.removeAccountAndPersonalData(itchUserID: 0))
        XCTAssertThrowsError(try repository.removeAccountAndPersonalData(itchUserID: 999))
        XCTAssertEqual(try context.fetch(FetchDescriptor<DBAccount>()).map(\.id), ["itch:813"])
    }

    @MainActor
    func testRemovalRefusesTheCurrentlyAuthenticatedAccount() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBAccount(itchUserID: 814, username: "active"))
        try context.save()
        let session = ItchAccountSession()
        session.activate(ItchAccountIdentity(itchUserID: 814, username: "active"))
        let repository = V4AccountRemovalRepository(context: context, session: session)

        XCTAssertThrowsError(try repository.removeAccountAndPersonalData(itchUserID: 814)) { error in
            XCTAssertEqual(error as? V4AccountRemovalRepository.RepositoryError, .accountIsActive("itch:814"))
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccount>()), 1)
    }

    @MainActor
    func testRemovedAccountCanReauthenticateAsFreshAccountWithoutRestoringDeletedPersonalRows() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = DBAccount(itchUserID: 815, username: "before-removal")
        context.insert(account)
        context.insert(DBGame(id: "shared-after-removal", title: "Shared catalog row"))
        context.insert(ItchPocketSchemaV4.DBLibraryEntry(
            accountID: account.id, gameID: "shared-after-removal", status: "playing"
        ))
        try context.save()

        _ = try V4AccountRemovalRepository(context: context, session: ItchAccountSession())
            .removeAccountAndPersonalData(itchUserID: 815)

        let reauthenticated = try V4AccountRegistryRepository(context: context)
            .recordAuthenticatedIdentity(
                ItchAccountIdentity(itchUserID: 815, username: "after-removal"),
                at: Date(timeIntervalSince1970: 1_800_000_000)
            )

        XCTAssertEqual(reauthenticated.id, "itch:815")
        XCTAssertEqual(reauthenticated.username, "after-removal")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccount>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGame>()), 1,
                       "Shared catalog data must survive account removal and re-login.")
    }
    @MainActor
    func testRemovalCoordinatorCommitsAccountDeletionThenClearsOnlyItsNotificationNamespaces() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let accountA = DBAccount(itchUserID: 816, username: "remove-me")
        let accountB = DBAccount(itchUserID: 817, username: "keep-me")
        context.insert(accountA)
        context.insert(accountB)
        context.insert(DBAccountCalendarEvent(
            accountID: accountA.id, eventKey: "removed-calendar", gameID: "shared", kind: "personal"
        ))
        context.insert(DBAccountUpdateWatch(accountID: accountA.id, gameID: "shared"))
        try context.save()

        let calendarA = AccountCalendarNotificationCoordinator.notificationIdentifier(
            accountID: accountA.id, eventID: "calendar-event"
        ) + ".generation.1"
        let calendarB = AccountCalendarNotificationCoordinator.notificationIdentifier(
            accountID: accountB.id, eventID: "calendar-event"
        ) + ".generation.1"
        let updateA = AccountUpdateWatchNotificationCoordinator.notificationIdentifier(
            accountID: accountA.id, gameID: "shared"
        ) + ".generation.1"
        let updateB = AccountUpdateWatchNotificationCoordinator.notificationIdentifier(
            accountID: accountB.id, gameID: "shared"
        ) + ".generation.1"
        let center = FakeV4RemovalNotificationCenter()
        center.pending = [calendarA, calendarB, updateA, updateB, "unrelated.pending"]
        center.delivered = [calendarA, calendarB, updateA, updateB, "unrelated.delivered"]

        let session = ItchAccountSession()
        let repository = V4AccountRemovalRepository(context: context, session: session)
        let coordinator = V4AccountRemovalCoordinator(
            session: session,
            repository: repository,
            calendarNotifications: AccountCalendarNotificationCoordinator(center: center),
            updateWatchNotifications: AccountUpdateWatchNotificationCoordinator(center: center)
        )

        let report = try await coordinator.removeAccountAndPersonalData(itchUserID: 816)

        XCTAssertEqual(report.accountID, "itch:816")
        XCTAssertEqual(try context.fetch(FetchDescriptor<DBAccount>()).map(\.id), ["itch:817"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccountCalendarEvent>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccountUpdateWatch>()), 0)
        XCTAssertTrue(center.removedPending.contains(calendarA))
        XCTAssertTrue(center.removedPending.contains(updateA))
        XCTAssertTrue(center.removedDelivered.contains(calendarA))
        XCTAssertTrue(center.removedDelivered.contains(updateA))
        XCTAssertTrue(center.pending.contains(calendarB))
        XCTAssertTrue(center.pending.contains(updateB))
        XCTAssertTrue(center.delivered.contains(calendarB))
        XCTAssertTrue(center.delivered.contains(updateB))
        XCTAssertTrue(center.pending.contains("unrelated.pending"))
        XCTAssertTrue(center.delivered.contains("unrelated.delivered"))
    }

}

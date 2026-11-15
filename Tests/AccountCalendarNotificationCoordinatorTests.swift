import XCTest
import UserNotifications
@testable import itchPocket

@MainActor
private final class FakeAccountCalendarNotificationCenter: AccountCalendarNotificationCenterClient {
    var status: UNAuthorizationStatus = .authorized
    var authorizationResult = true
    var onRequestAuthorization: (() -> Void)?
    var onAdd: (() -> Void)?
    var pending = Set<String>()
    var delivered = Set<String>()
    var added: [UNNotificationRequest] = []
    var removedPending: [String] = []
    var removedDelivered: [String] = []

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async -> Bool {
        onRequestAuthorization?()
        return authorizationResult
    }
    func pendingIdentifiers() async -> Set<String> { pending }
    func deliveredIdentifiers() async -> Set<String> { delivered }
    func removePending(identifiers: [String]) async {
        removedPending.append(contentsOf: identifiers)
        pending.subtract(identifiers)
    }
    func removeDelivered(identifiers: [String]) async {
        removedDelivered.append(contentsOf: identifiers)
        delivered.subtract(identifiers)
    }
    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
        pending.insert(request.identifier)
        onAdd?()
    }
}

final class AccountCalendarNotificationCoordinatorTests: XCTestCase {
    @MainActor
    private func event(
        id: String = "event-1",
        enabled: Bool = true,
        date: Date = Date(timeIntervalSince1970: 2_000_000_000),
        minutes: Int = 30
    ) -> ResolvedCalendarV4Event {
        ResolvedCalendarV4Event(
            id: id, gameID: "game-1", title: "Game update", date: date,
            kind: "update", reminderEnabled: enabled, reminderMinutes: minutes,
            notes: nil, origin: .accountPersonal
        )
    }

    @MainActor
    func testAccountSwitchRemovesOnlyPreviousAccountPendingAndDeliveredNotifications() async {
        let center = FakeAccountCalendarNotificationCenter()
        let oldID = AccountCalendarNotificationCoordinator.notificationIdentifier(
            accountID: "itch:101", eventID: "event-1"
        )
        let otherID = AccountCalendarNotificationCoordinator.notificationIdentifier(
            accountID: "itch:303", eventID: "event-1"
        )
        center.pending = [oldID, otherID, "some.other.app.notification"]
        center.delivered = [oldID, otherID, "some.other.app.notification"]
        let coordinator = AccountCalendarNotificationCoordinator(center: center)

        let count = await coordinator.rebuild(
            previousAccountID: "itch:101", accountID: "itch:202",
            events: [event()], now: Date(timeIntervalSince1970: 1_900_000_000),
            isCurrent: { true }
        )

        XCTAssertEqual(count, 1)
        XCTAssertTrue(center.removedPending.contains(oldID))
        XCTAssertTrue(center.removedDelivered.contains(oldID))
        XCTAssertFalse(center.removedPending.contains(otherID))
        XCTAssertFalse(center.removedDelivered.contains(otherID))
        XCTAssertFalse(center.removedPending.contains("some.other.app.notification"))
        XCTAssertFalse(center.removedDelivered.contains("some.other.app.notification"))
    }

    @MainActor
    func testUnknownPreviousAccountClearsOnlyManagedNamespaceBeforeRestore() async {
        let center = FakeAccountCalendarNotificationCenter()
        let accountA = AccountCalendarNotificationCoordinator.notificationIdentifier(
            accountID: "itch:101", eventID: "old-event-a"
        )
        let accountB = AccountCalendarNotificationCoordinator.notificationIdentifier(
            accountID: "itch:202", eventID: "old-event-b"
        )
        center.pending = [accountA, accountB, "unrelated.pending"]
        center.delivered = [accountA, accountB, "unrelated.delivered"]
        let coordinator = AccountCalendarNotificationCoordinator(center: center)

        let count = await coordinator.rebuild(
            previousAccountID: nil, accountID: "itch:303",
            events: [], isCurrent: { true }
        )

        XCTAssertEqual(count, 0)
        XCTAssertFalse(center.pending.contains(accountA))
        XCTAssertFalse(center.pending.contains(accountB))
        XCTAssertFalse(center.delivered.contains(accountA))
        XCTAssertFalse(center.delivered.contains(accountB))
        XCTAssertTrue(center.pending.contains("unrelated.pending"))
        XCTAssertTrue(center.delivered.contains("unrelated.delivered"))
    }

    @MainActor
    func testNotificationIdentifiersAreNamespacedByAccount() {
        let a = AccountCalendarNotificationCoordinator.notificationIdentifier(
            accountID: "itch:101", eventID: "same-event"
        )
        let b = AccountCalendarNotificationCoordinator.notificationIdentifier(
            accountID: "itch:202", eventID: "same-event"
        )
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix(AccountCalendarNotificationCoordinator.identifierPrefix))
    }

    @MainActor
    func testRepeatedRebuildReplacesRatherThanDuplicatesProjection() async {
        let center = FakeAccountCalendarNotificationCenter()
        let coordinator = AccountCalendarNotificationCoordinator(center: center)
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        let first = await coordinator.rebuild(
            previousAccountID: nil, accountID: "itch:101",
            events: [event()], now: now, isCurrent: { true }
        )
        let second = await coordinator.rebuild(
            previousAccountID: "itch:101", accountID: "itch:101",
            events: [event()], now: now, isCurrent: { true }
        )

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.added.count, 2)
    }

    @MainActor
    func testSignOutClearsManagedNotificationsIncludingDeliveredOnes() async {
        let center = FakeAccountCalendarNotificationCenter()
        let managed = AccountCalendarNotificationCoordinator.notificationIdentifier(
            accountID: "itch:101", eventID: "event-1"
        )
        center.pending = [managed, "unrelated"]
        center.delivered = [managed, "unrelated"]
        let coordinator = AccountCalendarNotificationCoordinator(center: center)

        let count = await coordinator.rebuild(
            previousAccountID: "itch:101", accountID: nil,
            events: [], isCurrent: { true }
        )

        XCTAssertEqual(count, 0)
        XCTAssertFalse(center.pending.contains(managed))
        XCTAssertFalse(center.delivered.contains(managed))
        XCTAssertTrue(center.pending.contains("unrelated"))
        XCTAssertTrue(center.delivered.contains("unrelated"))
    }

    @MainActor
    func testDeniedAuthorizationAndExpiredOrDisabledEventsAreNotScheduled() async {
        let center = FakeAccountCalendarNotificationCenter()
        center.status = .denied
        let coordinator = AccountCalendarNotificationCoordinator(center: center)
        let count = await coordinator.rebuild(
            previousAccountID: nil, accountID: "itch:101",
            events: [
                event(),
                event(id: "disabled", enabled: false),
                event(id: "expired", date: Date(timeIntervalSince1970: 1))
            ],
            now: Date(timeIntervalSince1970: 1_900_000_000),
            isCurrent: { true }
        )

        XCTAssertEqual(count, 0)
        XCTAssertTrue(center.added.isEmpty)
    }

    @MainActor
    func testSessionInvalidatedWhilePermissionPromptIsSuspendedCannotSchedule() async {
        let center = FakeAccountCalendarNotificationCenter()
        center.status = .notDetermined
        var sessionIsCurrent = true
        center.onRequestAuthorization = { sessionIsCurrent = false }
        let coordinator = AccountCalendarNotificationCoordinator(center: center)

        let count = await coordinator.rebuild(
            previousAccountID: nil, accountID: "itch:101",
            events: [event()], now: Date(timeIntervalSince1970: 1_900_000_000),
            isCurrent: { sessionIsCurrent }
        )

        XCTAssertEqual(count, 0)
        XCTAssertTrue(center.added.isEmpty)
    }

    @MainActor
    func testSessionInvalidatedWhileNotificationAddCompletesRemovesStaleRequest() async {
        let center = FakeAccountCalendarNotificationCenter()
        let session = ItchAccountSession()
        session.activate(ItchAccountIdentity(itchUserID: 101, username: "account-a"))
        let context = session.captureOperationContext()
        center.onAdd = {
            session.activate(ItchAccountIdentity(itchUserID: 202, username: "account-b"))
        }
        let coordinator = AccountCalendarNotificationCoordinator(center: center)

        let count = await coordinator.rebuild(
            previousAccountID: nil, accountID: "itch:101",
            events: [event()], now: Date(timeIntervalSince1970: 1_900_000_000),
            isCurrent: { session.isCurrent(context) }
        )

        XCTAssertEqual(count, 0)
        XCTAssertEqual(center.added.count, 1)
        let staleIdentifier = try! XCTUnwrap(center.added.first?.identifier)
        XCTAssertTrue(staleIdentifier.hasPrefix(AccountCalendarNotificationCoordinator.identifierPrefix))
        XCTAssertTrue(staleIdentifier.contains(".generation."))
        XCTAssertTrue(center.removedPending.contains(staleIdentifier))
        XCTAssertFalse(center.pending.contains(staleIdentifier))
    }

    @MainActor
    func testStaleSessionAndInvalidAccountCannotSchedule() async {
        let center = FakeAccountCalendarNotificationCenter()
        let coordinator = AccountCalendarNotificationCoordinator(center: center)
        let staleCount = await coordinator.rebuild(
            previousAccountID: nil, accountID: "itch:101",
            events: [event()], now: Date(timeIntervalSince1970: 1_900_000_000),
            isCurrent: { false }
        )
        let invalidCount = await coordinator.rebuild(
            previousAccountID: nil, accountID: "patreon:101",
            events: [event()], now: Date(timeIntervalSince1970: 1_900_000_000),
            isCurrent: { true }
        )

        XCTAssertEqual(staleCount, 0)
        XCTAssertEqual(invalidCount, 0)
        XCTAssertTrue(center.added.isEmpty)
    }
}

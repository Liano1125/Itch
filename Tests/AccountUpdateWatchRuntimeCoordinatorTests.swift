import XCTest
import UserNotifications
import SwiftData
@testable import itchPocket

@MainActor
private final class FakeUpdateWatchNotificationCenter: AccountCalendarNotificationCenterClient {
    var status: UNAuthorizationStatus = .authorized
    var authorizationResult = true
    var onAuthorization: (() -> Void)?
    var onAdd: (() -> Void)?
    var pending = Set<String>()
    var delivered = Set<String>()
    var added: [UNNotificationRequest] = []
    var removedPending: [String] = []
    var removedDelivered: [String] = []

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async -> Bool {
        onAuthorization?()
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


private actor UpdateWatchFetchGate {
    private var continuation: CheckedContinuation<AccountUpdateWatchFetchResult, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func wait() async -> AccountUpdateWatchFetchResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resume(_ result: AccountUpdateWatchFetchResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

final class AccountUpdateWatchRuntimeCoordinatorTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "v4-update-watch-runtime-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    private func makeRepository(_ accountID: String) throws -> (ModelContainer, AccountScopedUpdateWatchRepository) {
        let container = try makeContainer()
        container.mainContext.insert(DBGame(id: "game", title: "Game"))
        try container.mainContext.save()
        let repository = try AccountScopedUpdateWatchRepository(context: container.mainContext, accountID: accountID)
        return (container, repository)
    }

    @MainActor
    func testLateFetchAfterAccountSwitchDoesNotPersistOrNotify() async throws {
        let (container, repository) = try makeRepository("itch:101")
        let session = ItchAccountSession()
        session.activate(ItchAccountIdentity(itchUserID: 101, username: "a"))
        let center = FakeUpdateWatchNotificationCenter()
        let notifications = AccountUpdateWatchNotificationCoordinator(center: center)
        let coordinator = AccountUpdateWatchRuntimeCoordinator(
            session: session, repository: repository, notifications: notifications
        )
        _ = container

        let gate = UpdateWatchFetchGate()
        let pendingFetch = AccountUpdateWatchFetchResult(
            entityTag: "A-etag", lastModified: nil, contentHash: "A-hash",
            checkedAt: Date(timeIntervalSince1970: 10), hasBaseline: true, detectedChange: true
        )
        let checkTask = Task { @MainActor in
            try await coordinator.check(gameID: "game", gameTitle: "Game") { _ in
                await gate.wait()
            }
        }
        await gate.waitUntilStarted()
        session.activate(ItchAccountIdentity(itchUserID: 202, username: "b"))
        await gate.resume(pendingFetch)
        let didPersist = try await checkTask.value

        XCTAssertFalse(didPersist)
        XCTAssertTrue(try repository.loadWatches().isEmpty)
        XCTAssertTrue(center.added.isEmpty)
    }

    @MainActor
    func testCurrentAccountPersistsWithoutCrossAccountSideEffects() async throws {
        let (container, repository) = try makeRepository("itch:101")
        let session = ItchAccountSession()
        session.activate(ItchAccountIdentity(itchUserID: 101, username: "a"))
        let center = FakeUpdateWatchNotificationCenter()
        let notifications = AccountUpdateWatchNotificationCoordinator(center: center)
        let coordinator = AccountUpdateWatchRuntimeCoordinator(
            session: session, repository: repository, notifications: notifications
        )
        _ = container

        let result = try await coordinator.check(gameID: "game", gameTitle: "Game") { _ in
            AccountUpdateWatchFetchResult(
                entityTag: "A-etag", lastModified: "A-date", contentHash: "A-hash",
                checkedAt: Date(timeIntervalSince1970: 20), hasBaseline: true, detectedChange: false
            )
        }

        XCTAssertTrue(result)
        XCTAssertEqual(try repository.loadWatches().first?.entityTag, "A-etag")
        XCTAssertTrue(center.added.isEmpty)
    }

    @MainActor
    func testNotificationIdentifiersSeparateAccountsForSameGame() {
        let a = AccountUpdateWatchNotificationCoordinator.notificationIdentifier(
            accountID: "itch:101", gameID: "same-game"
        )
        let b = AccountUpdateWatchNotificationCoordinator.notificationIdentifier(
            accountID: "itch:202", gameID: "same-game"
        )
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix(AccountUpdateWatchNotificationCoordinator.identifierPrefix))
    }

    @MainActor
    func testStaleNotificationAddIsRemovedAfterAccountSwitch() async {
        let center = FakeUpdateWatchNotificationCenter()
        let session = ItchAccountSession()
        session.activate(ItchAccountIdentity(itchUserID: 101, username: "a"))
        let context = session.captureRequestContext()!
        center.onAdd = {
            session.activate(ItchAccountIdentity(itchUserID: 202, username: "b"))
        }
        let coordinator = AccountUpdateWatchNotificationCoordinator(center: center)

        let scheduled = await coordinator.scheduleUpdate(
            accountID: "itch:101", gameID: "game", title: "Update", body: "Changed",
            isCurrent: { session.isCurrent(context) }
        )

        XCTAssertFalse(scheduled)
        let staleID = try! XCTUnwrap(center.added.first?.identifier)
        XCTAssertTrue(staleID.contains(".generation."))
        XCTAssertTrue(center.removedPending.contains(staleID))
        XCTAssertFalse(center.pending.contains(staleID))
    }

    @MainActor
    func testClearRemovesOnlySelectedAccountNamespace() async {
        let center = FakeUpdateWatchNotificationCenter()
        let a = AccountUpdateWatchNotificationCoordinator.notificationIdentifier(
            accountID: "itch:101", gameID: "game"
        ) + ".generation.1"
        let b = AccountUpdateWatchNotificationCoordinator.notificationIdentifier(
            accountID: "itch:202", gameID: "game"
        ) + ".generation.1"
        center.pending = [a, b, "other"]
        center.delivered = [a, b, "other"]
        let coordinator = AccountUpdateWatchNotificationCoordinator(center: center)

        await coordinator.clear(accountID: "itch:101")

        XCTAssertTrue(center.removedPending.contains(a))
        XCTAssertTrue(center.removedDelivered.contains(a))
        XCTAssertFalse(center.removedPending.contains(b))
        XCTAssertFalse(center.removedDelivered.contains(b))
        XCTAssertTrue(center.pending.contains(b))
        XCTAssertTrue(center.pending.contains("other"))
    }
    @MainActor
    func testLateFetchAfterAccountRemovalDoesNotPersistOrNotifyEvenAfterRemovalFinishes() async throws {
        let (container, repository) = try makeRepository("itch:101")
        let session = ItchAccountSession()
        session.activate(ItchAccountIdentity(itchUserID: 101, username: "a"))
        let center = FakeUpdateWatchNotificationCenter()
        let coordinator = AccountUpdateWatchRuntimeCoordinator(
            session: session,
            repository: repository,
            notifications: AccountUpdateWatchNotificationCoordinator(center: center)
        )
        _ = container

        let gate = UpdateWatchFetchGate()
        let pendingFetch = AccountUpdateWatchFetchResult(
            entityTag: "late-etag", lastModified: nil, contentHash: "late-hash",
            checkedAt: Date(timeIntervalSince1970: 30), hasBaseline: true, detectedChange: true
        )
        let checkTask = Task { @MainActor in
            try await coordinator.check(gameID: "game", gameTitle: "Game") { _ in
                await gate.wait()
            }
        }
        await gate.waitUntilStarted()

        XCTAssertTrue(session.beginAccountRemoval("itch:101"))
        session.endAccountRemoval("itch:101")
        await gate.resume(pendingFetch)

        let didPersist = try await checkTask.value
        XCTAssertFalse(didPersist)
        XCTAssertTrue(try repository.loadWatches().isEmpty)
        XCTAssertTrue(center.added.isEmpty)
    }

}

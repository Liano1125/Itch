import Foundation
import UserNotifications

struct AccountUpdateWatchFetchResult: Equatable {
    let entityTag: String?
    let lastModified: String?
    let contentHash: String?
    let checkedAt: Date
    let hasBaseline: Bool
    let detectedChange: Bool
}

/// Account-aware V4 check pipeline. It captures an immutable itch identity +
/// session generation before network work and revalidates immediately after
/// every suspension before persistence or notification side effects.
@MainActor
final class AccountUpdateWatchRuntimeCoordinator {
    private let session: ItchAccountSession
    private let repository: AccountScopedUpdateWatchRepository
    private let notifications: AccountUpdateWatchNotificationCoordinator

    init(
        session: ItchAccountSession,
        repository: AccountScopedUpdateWatchRepository,
        notifications: AccountUpdateWatchNotificationCoordinator
    ) {
        self.session = session
        self.repository = repository
        self.notifications = notifications
    }

    @discardableResult
    func check(
        gameID: String,
        gameTitle: String,
        fetch: (String) async throws -> AccountUpdateWatchFetchResult
    ) async throws -> Bool {
        guard let requestContext = session.captureRequestContext(),
              requestContext.accountID == repository.accountID else { return false }

        let existing = try repository.loadWatches().first { $0.gameID == gameID }
        guard existing?.isEnabled != false else { return false }

        let fetched = try await fetch(gameID)
        // This is the critical stale-result barrier. No persistence, publish,
        // or notification may occur for a request from a previous generation.
        guard session.isCurrent(requestContext),
              requestContext.accountID == repository.accountID else { return false }

        let updated = StoredAccountUpdateWatch(
            gameID: gameID,
            entityTag: fetched.entityTag,
            lastModified: fetched.lastModified,
            contentHash: fetched.contentHash,
            lastCheckedAt: fetched.checkedAt,
            hasBaseline: fetched.hasBaseline,
            isEnabled: existing?.isEnabled ?? true
        )
        try repository.upsert(updated)

        guard session.isCurrent(requestContext) else { return false }
        if fetched.detectedChange {
            await notifications.scheduleUpdate(
                accountID: requestContext.accountID,
                gameID: gameID,
                title: "游戏页面可能已更新",
                body: "\(gameTitle) 的 itch.io 页面信息发生变化，打开游戏页面确认详情。",
                isCurrent: { [session] in session.isCurrent(requestContext) }
            )
        }
        return session.isCurrent(requestContext)
    }
}

/// Account-scoped notification projection for V4 UpdateWatch.
/// It is deliberately separate from V3's global gameID notification IDs.
@MainActor
final class AccountUpdateWatchNotificationCoordinator {
    static let identifierPrefix = "itchPocket.update.v4."

    private let center: any AccountCalendarNotificationCenterClient
    private var operationGeneration: UInt64 = 0

    init(center: (any AccountCalendarNotificationCenterClient)? = nil) {
        self.center = center ?? SystemAccountCalendarNotificationCenter()
    }

    static func notificationIdentifier(accountID: String, gameID: String) -> String {
        "\(identifierPrefix)\(encoded(accountID)).game.\(encoded(gameID))"
    }

    @discardableResult
    func scheduleUpdate(
        accountID: String,
        gameID: String,
        title: String,
        body: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        operationGeneration &+= 1
        let generation = operationGeneration
        guard Self.isCanonicalItchAccountID(accountID),
              !gameID.isEmpty, isCurrent(), isCurrentOperation(generation) else { return false }

        let authorization = await center.authorizationStatus()
        guard isCurrent(), isCurrentOperation(generation) else { return false }
        let authorized: Bool
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            authorized = true
        case .notDetermined:
            authorized = await center.requestAuthorization()
        case .denied:
            authorized = false
        @unknown default:
            authorized = false
        }
        guard authorized, isCurrent(), isCurrentOperation(generation) else { return false }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let identifier = Self.notificationIdentifier(accountID: accountID, gameID: gameID)
            + ".generation.\(generation)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            guard isCurrent(), isCurrentOperation(generation) else {
                // The identifier is generation-specific: stale cleanup cannot
                // delete a newer account session's replacement notification.
                await center.removePending(identifiers: [identifier])
                return false
            }
            return true
        } catch {
            return false
        }
    }

    func clear(accountID: String?, isCurrent: @escaping @MainActor () -> Bool = { true }) async {
        // Do not let scheduling for another account invalidate this
        // account-specific cleanup while notification-center reads are suspended.
        if let accountID, !Self.isCanonicalItchAccountID(accountID) { return }
        let prefix = accountID.map(Self.accountPrefix) ?? Self.identifierPrefix
        let pending = await center.pendingIdentifiers()
        guard isCurrent() else { return }
        let pendingToRemove = pending.filter { $0.hasPrefix(prefix) }
        let delivered = await center.deliveredIdentifiers()
        guard isCurrent(), isCurrentOperation(generation) else { return }
        let deliveredToRemove = delivered.filter { $0.hasPrefix(prefix) }
        if !pendingToRemove.isEmpty {
            await center.removePending(identifiers: Array(pendingToRemove))
            guard isCurrent(), isCurrentOperation(generation) else { return }
        }
        if !deliveredToRemove.isEmpty {
            await center.removeDelivered(identifiers: Array(deliveredToRemove))
        }
    }

    private func isCurrentOperation(_ generation: UInt64) -> Bool {
        operationGeneration == generation
    }

    private static func accountPrefix(_ accountID: String) -> String {
        "\(identifierPrefix)\(encoded(accountID))."
    }

    private static func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isCanonicalItchAccountID(_ value: String) -> Bool {
        guard value.hasPrefix("itch:"),
              let id = Int(value.dropFirst(5)),
              id > 0 else { return false }
        return value == "itch:\(id)"
    }
}

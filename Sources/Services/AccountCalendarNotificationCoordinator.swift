import Foundation
import UserNotifications

@MainActor
protocol AccountCalendarNotificationCenterClient {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func pendingIdentifiers() async -> Set<String>
    func deliveredIdentifiers() async -> Set<String>
    func removePending(identifiers: [String]) async
    func removeDelivered(identifiers: [String]) async
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
final class SystemAccountCalendarNotificationCenter: AccountCalendarNotificationCenterClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func pendingIdentifiers() async -> Set<String> {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: Set(requests.map(\.identifier)))
            }
        }
    }

    func deliveredIdentifiers() async -> Set<String> {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: Set(notifications.map { $0.request.identifier }))
            }
        }
    }

    func removePending(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(identifiers: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
}

/// Builds the device notification projection for V4 account-scoped calendar data.
///
/// This coordinator is intentionally not connected to V3 GameCalendarStore or app startup.
/// Callers must pass the authenticated itch account ID and a session-generation validator.
@MainActor
final class AccountCalendarNotificationCoordinator {
    static let identifierPrefix = "itchPocket.calendar.v4."

    private let center: any AccountCalendarNotificationCenterClient
    private var operationGeneration: UInt64 = 0

    init(center: any AccountCalendarNotificationCenterClient = SystemAccountCalendarNotificationCenter()) {
        self.center = center
    }

    /// Replaces the notification projection after an account transition.
    /// Passing nil as accountID clears the app-managed V4 calendar notifications (sign-out).
    /// The validator must capture the session context that initiated this operation.
    @discardableResult
    func rebuild(
        previousAccountID: String?,
        accountID: String?,
        events: [ResolvedCalendarV4Event],
        now: Date = .now,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> Int {
        operationGeneration &+= 1
        let generation = operationGeneration

        guard isCurrent(), isCurrentOperation(generation) else { return 0 }

        if let accountID, !Self.isCanonicalItchAccountID(accountID) { return 0 }
        if let previousAccountID, !Self.isCanonicalItchAccountID(previousAccountID) { return 0 }

        if let previousAccountID, previousAccountID != accountID {
            await removeManagedNotifications(accountID: previousAccountID)
            guard isCurrent(), isCurrentOperation(generation) else { return 0 }
        }

        guard let accountID else {
            // A sign-out without a known previous identity still clears only this app's V4 IDs.
            if previousAccountID == nil {
                await removeManagedNotifications(accountID: nil)
            }
            return 0
        }

        // Clear the destination account's previous projection first. This makes rebuilds idempotent.
        await removeManagedNotifications(accountID: accountID)
        guard isCurrent(), isCurrentOperation(generation) else { return 0 }

        let authorization = await center.authorizationStatus()
        guard isCurrent(), isCurrentOperation(generation) else { return 0 }

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
        guard authorized, isCurrent(), isCurrentOperation(generation) else { return 0 }

        var scheduled = 0
        for event in events where event.reminderEnabled {
            guard isCurrent(), isCurrentOperation(generation) else { return scheduled }
            guard let eventDate = event.date else { continue }
            let fireDate = eventDate.addingTimeInterval(-Double(max(0, event.reminderMinutes) * 60))
            guard fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = event.title?.isEmpty == false ? event.title! : "游戏提醒"
            content.body = event.notes?.isEmpty == false
                ? event.notes!
                : "提醒时间：\(eventDate.formatted(date: .abbreviated, time: .shortened))"
            content.sound = .default

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: Self.notificationIdentifier(accountID: accountID, eventID: event.id),
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
                scheduled += 1
            } catch {
                // A failed individual notification must not stop other reminders from being projected.
            }
        }
        return scheduled
    }

    func cancelAllManagedNotifications() async {
        operationGeneration &+= 1
        await removeManagedNotifications(accountID: nil)
    }

    static func notificationIdentifier(accountID: String, eventID: String) -> String {
        "\(identifierPrefix)\(encoded(accountID)).event.\(encoded(eventID))"
    }

    private func removeManagedNotifications(accountID: String?) async {
        let prefix = accountID.map { Self.notificationIdentifierPrefix(accountID: $0) }
            ?? Self.identifierPrefix
        let pending = await center.pendingIdentifiers().filter { $0.hasPrefix(prefix) }
        let delivered = await center.deliveredIdentifiers().filter { $0.hasPrefix(prefix) }
        if !pending.isEmpty { await center.removePending(identifiers: Array(pending)) }
        if !delivered.isEmpty { await center.removeDelivered(identifiers: Array(delivered)) }
    }

    private func isCurrentOperation(_ generation: UInt64) -> Bool {
        operationGeneration == generation
    }

    private static func notificationIdentifierPrefix(accountID: String) -> String {
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

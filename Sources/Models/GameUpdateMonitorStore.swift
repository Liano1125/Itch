import Foundation
import Combine
import UserNotifications

struct GameUpdateWatch: Codable, Identifiable {
    var id: String { gameID }
    var gameID: String
    var gameTitle: String
    var gameURL: String
    var entityTag: String?
    var lastModified: String?
    var lastCheckedAt: Date?
    var hasBaseline: Bool
    var isEnabled: Bool
}

@MainActor
final class GameUpdateMonitorStore: ObservableObject {
    @Published private(set) var watches: [String: GameUpdateWatch] = [:]
    @Published private(set) var checkingIDs: Set<String> = []
    @Published var statusMessage: String?
    private let storageKey = "itchPocket.updateWatches.v1"

    init() { load() }

    func watch(for gameID: String) -> GameUpdateWatch? { watches[gameID] }

    func setEnabled(_ enabled: Bool, for record: LibraryRecord) {
        if enabled {
            let existing = watches[record.id]
            watches[record.id] = GameUpdateWatch(
                gameID: record.id,
                gameTitle: record.title,
                gameURL: record.gameURL ?? "",
                entityTag: existing?.entityTag,
                lastModified: existing?.lastModified,
                lastCheckedAt: existing?.lastCheckedAt,
                hasBaseline: existing?.hasBaseline ?? false,
                isEnabled: true
            )
        } else {
            watches.removeValue(forKey: record.id)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID(record.id)])
        }
        save()
    }

    func checkAll(calendarStore: GameCalendarStore, libraryStore: PersonalLibraryStore) async {
        let targets = watches.values.filter(\.isEnabled)
        guard !targets.isEmpty else {
            statusMessage = "还没有开启监控的游戏。"
            return
        }
        var updated = 0
        var failed = 0
        for target in targets {
            checkingIDs.insert(target.gameID)
            defer { checkingIDs.remove(target.gameID) }
            do {
                guard let url = URL(string: target.gameURL), url.scheme == "https" else {
                    failed += 1
                    continue
                }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 25
                request.setValue("text/html", forHTTPHeaderField: "Accept")
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                    failed += 1
                    continue
                }
                let etag = http.value(forHTTPHeaderField: "ETag")
                let modified = http.value(forHTTPHeaderField: "Last-Modified")
                guard var current = watches[target.gameID] else { continue }
                if !current.hasBaseline {
                    current.entityTag = etag
                    current.lastModified = modified
                    current.lastCheckedAt = Date()
                    current.hasBaseline = true
                } else {
                    let changed = (modified != nil && current.lastModified != nil && modified != current.lastModified)
                        || (modified == nil && etag != nil && current.entityTag != nil && etag != current.entityTag)
                    if changed {
                        let fingerprint = "modified:\(modified ?? current.lastModified ?? "")|etag:\(etag ?? current.entityTag ?? "")"
                        let detectedAt = Date()
                        let summary = "itch.io 游戏页面响应信息发生变化（ETag / Last-Modified）；请打开页面确认具体更新内容。"
                        calendarStore.addDetectedUpdate(
                            gameID: current.gameID,
                            gameTitle: current.gameTitle,
                            gameURL: current.gameURL,
                            fingerprint: fingerprint,
                            detectedAt: detectedAt
                        )
                        libraryStore.recordGameUpdate(gameID: current.gameID, summary: summary, detectedAt: detectedAt)
                        await sendUpdateNotification(for: current)
                        updated += 1
                    }
                    if etag != nil { current.entityTag = etag }
                    if modified != nil { current.lastModified = modified }
                    current.lastCheckedAt = Date()
                }
                watches[target.gameID] = current
                save()
            } catch {
                failed += 1
            }
        }
        statusMessage = "检查完成：\(updated) 款游戏检测到页面更新并已写入日历，\(failed) 款检查失败。首次检查只建立基准，不会生成更新记录。"
    }

    private func sendUpdateNotification(for watch: GameUpdateWatch) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "游戏页面可能已更新"
        content.body = "\(watch.gameTitle) 的 itch.io 页面信息发生变化，打开游戏页面确认详情。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: notificationID(watch.gameID), content: content, trigger: nil)
        try? await center.add(request)
    }

    private func notificationID(_ id: String) -> String { "itchPocket.update.\(id)" }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let values = try? JSONDecoder().decode([GameUpdateWatch].self, from: data) else { return }
        watches = Dictionary(uniqueKeysWithValues: values.map { ($0.gameID, $0) })
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(watches.values)) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

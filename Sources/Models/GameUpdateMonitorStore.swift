import Foundation
import Combine
import UserNotifications

struct DevlogSyncGameResult: Codable, Identifiable {
    var id: String { gameID }
    let gameID: String
    let gameTitle: String
    let importedCount: Int
    let message: String
}

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
    static let shared = GameUpdateMonitorStore()
    @Published private(set) var watches: [String: GameUpdateWatch] = [:]
    @Published private(set) var checkingIDs: Set<String> = []
    @Published var statusMessage: String?
    @Published private(set) var isSyncingHistoricalDevlogs = false
    @Published private(set) var lastHistoricalSyncAt: Date?
    @Published private(set) var lastHistoricalSyncMessage: String?
    @Published private(set) var lastHistoricalSyncResults: [DevlogSyncGameResult] = []
    private let storageKey = "itchPocket.updateWatches.v1"
    private let historicalSyncDateKey = "itchPocket.devlogSync.lastDate"
    private let historicalSyncMessageKey = "itchPocket.devlogSync.lastMessage"
    private let historicalSyncResultsKey = "itchPocket.devlogSync.lastResults"

    init() {
        load()
        lastHistoricalSyncAt = UserDefaults.standard.object(forKey: historicalSyncDateKey) as? Date
        lastHistoricalSyncMessage = UserDefaults.standard.string(forKey: historicalSyncMessageKey)
        if let data = UserDefaults.standard.data(forKey: historicalSyncResultsKey),
           let results = try? JSONDecoder().decode([DevlogSyncGameResult].self, from: data) {
            lastHistoricalSyncResults = results
        }
    }

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

    func syncHistoricalDevlogs(records: [LibraryRecord], calendarStore: GameCalendarStore, libraryStore: PersonalLibraryStore) async -> String {
        guard !isSyncingHistoricalDevlogs else {
            return lastHistoricalSyncMessage ?? "历史更新同步正在进行中。"
        }
        isSyncingHistoricalDevlogs = true
        defer { isSyncingHistoricalDevlogs = false }

        var imported = 0
        var unchanged = 0
        var failed = 0
        var results: [DevlogSyncGameResult] = []

        for record in records {
            guard let rawURL = record.gameURL,
                  let gameURL = URL(string: rawURL),
                  let feedURL = Self.devlogFeedURL(for: gameURL) else {
                failed += 1
                results.append(DevlogSyncGameResult(gameID: record.id, gameTitle: record.title, importedCount: 0, message: "缺少有效的游戏页面链接"))
                continue
            }
            do {
                var request = URLRequest(url: feedURL)
                request.timeoutInterval = 25
                request.setValue("application/rss+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    failed += 1
                    results.append(DevlogSyncGameResult(gameID: record.id, gameTitle: record.title, importedCount: 0, message: "服务器没有返回有效的 HTTP 响应"))
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    failed += 1
                    results.append(DevlogSyncGameResult(gameID: record.id, gameTitle: record.title, importedCount: 0, message: "RSS 请求失败，HTTP \(http.statusCode)"))
                    continue
                }
                let posts = try DevlogRSSParser.parse(data: data)
                let before = imported
                for post in posts {
                    guard let publishedAt = post.publishedAt else { continue }
                    let stableID = post.guid ?? post.url ?? "\(post.title)|\(publishedAt.timeIntervalSince1970)"
                    let libraryAdded = libraryStore.recordHistoricalUpdate(
                        gameID: record.id,
                        title: post.title,
                        summary: post.summary,
                        publishedAt: publishedAt,
                        url: post.url,
                        sourceID: stableID
                    )
                    let calendarAdded = calendarStore.addHistoricalUpdate(
                        gameID: record.id,
                        gameTitle: record.title,
                        gameURL: record.gameURL,
                        title: post.title,
                        summary: post.summary,
                        publishedAt: publishedAt,
                        sourceID: stableID,
                        postURL: post.url
                    )
                    if libraryAdded || calendarAdded { imported += 1 }
                }
                let addedForGame = imported - before
                if posts.isEmpty {
                    unchanged += 1
                    results.append(DevlogSyncGameResult(gameID: record.id, gameTitle: record.title, importedCount: 0, message: "没有公开的 Devlog 更新"))
                } else {
                    results.append(DevlogSyncGameResult(gameID: record.id, gameTitle: record.title, importedCount: addedForGame, message: addedForGame > 0 ? "已同步 \(addedForGame) 条更新" : "内容已是最新，没有重复导入"))
                }
            } catch {
                failed += 1
                results.append(DevlogSyncGameResult(gameID: record.id, gameTitle: record.title, importedCount: 0, message: "读取失败：\(error.localizedDescription)"))
            }
        }

        let message = "同步完成：新增或补齐 \(imported) 条记录，\(unchanged) 款游戏没有公开更新日志，\(failed) 款游戏读取失败。"
        lastHistoricalSyncAt = Date()
        lastHistoricalSyncMessage = message
        lastHistoricalSyncResults = results
        UserDefaults.standard.set(lastHistoricalSyncAt, forKey: historicalSyncDateKey)
        UserDefaults.standard.set(message, forKey: historicalSyncMessageKey)
        if let data = try? JSONEncoder().encode(results) {
            UserDefaults.standard.set(data, forKey: historicalSyncResultsKey)
        }
        return message
    }

    private static func devlogFeedURL(for gameURL: URL) -> URL? {
        guard var components = URLComponents(url: gameURL, resolvingAgainstBaseURL: false),
              components.scheme == "https" || components.scheme == "http" else { return nil }
        let cleanPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + (cleanPath.isEmpty ? "" : cleanPath + "/") + "devlog.rss"
        components.query = nil
        components.fragment = nil
        return components.url
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


private struct DevlogRSSPost {
    let title: String
    let summary: String
    let url: String?
    let guid: String?
    let publishedAt: Date?
}

private final class DevlogRSSParser: NSObject, XMLParserDelegate {
    private var posts: [DevlogRSSPost] = []
    private var isInsideItem = false
    private var currentElement = ""
    private var values: [String: String] = [:]

    static func parse(data: Data) throws -> [DevlogRSSPost] {
        let parser = XMLParser(data: data)
        let delegate = DevlogRSSParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "DevlogRSSParser", code: 1)
        }
        return delegate.posts
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = (qName ?? elementName).lowercased()
        if name == "item" || name == "entry" {
            isInsideItem = true
            values = [:]
        } else if isInsideItem {
            currentElement = name
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideItem, !currentElement.isEmpty else { return }
        values[currentElement, default: ""].append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard isInsideItem, !currentElement.isEmpty,
              let value = String(data: CDATABlock, encoding: .utf8) else { return }
        values[currentElement, default: ""].append(value)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = (qName ?? elementName).lowercased()
        if name == "item" || name == "entry" {
            let title = Self.clean(values["title"] ?? "")
            let link = Self.clean(values["link"] ?? "")
            let guid = Self.clean(values["guid"] ?? values["id"] ?? "")
            let rawDate = Self.clean(values["pubdate"] ?? values["published"] ?? values["updated"] ?? "")
            let summary = Self.cleanHTML(values["description"] ?? values["content:encoded"] ?? values["summary"] ?? "")
            if !title.isEmpty {
                posts.append(DevlogRSSPost(
                    title: title,
                    summary: summary,
                    url: link.isEmpty ? nil : link,
                    guid: guid.isEmpty ? nil : guid,
                    publishedAt: Self.parseDate(rawDate)
                ))
            }
            isInsideItem = false
            currentElement = ""
            values = [:]
        } else if isInsideItem {
            currentElement = ""
        }
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanHTML(_ value: String) -> String {
        let stripped = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

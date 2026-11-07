import Foundation
import SwiftUI
import ZIPFoundation

struct SparkGameSummary: Identifiable {
    var id: String { gameName.lowercased() }
    let gameName: String
    var runtimeSeconds: Double
    var lastSaveAt: Date?
    var lastBackupAt: Date?
    var renpyVersion: String?
    var saveCount: Int
}

@MainActor
final class SparkSyncStore: ObservableObject {
    static let shared = SparkSyncStore()

    @Published private(set) var folderName: String?
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var summaries: [SparkGameSummary] = []
    @Published private(set) var unmatchedGameNames: [String] = []
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?

    private let bookmarkKey = "itchPocket.sparkFolderBookmark.v1"
    private let lastSyncKey = "itchPocket.sparkLastSyncAt.v1"

    private init() {
        folderName = UserDefaults.standard.string(forKey: "itchPocket.sparkFolderName.v1")
        lastSyncAt = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    func selectFolder(_ url: URL, library: PersonalLibraryStore) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            folderName = url.lastPathComponent
            UserDefaults.standard.set(folderName, forKey: "itchPocket.sparkFolderName.v1")
            await scanFolder(url, library: library)
        } catch {
            errorMessage = "无法保存文件夹授权：\(error.localizedDescription)"
        }
    }

    func rescan(library: PersonalLibraryStore) async {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            errorMessage = "请先选择 iCloud Drive 中的 Spark 文件夹。"
            return
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }

            if isStale {
                let refreshed = try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            }
            await scanFolder(url, library: library)
        } catch {
            errorMessage = "无法重新访问 Spark 文件夹，请重新选择：\(error.localizedDescription)"
        }
    }

    private func scanFolder(_ url: URL, library: PersonalLibraryStore) async {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        defer { isScanning = false }

        do {
            let found = try await Task.detached(priority: .utility) {
                try SparkArchiveScanner.scan(rootURL: url)
            }.value

            summaries = found
            var unmatched: [String] = []

            for summary in found {
                let key = Self.normalized(summary.gameName)
                guard let record = library.records.first(where: {
                    Self.normalized($0.title) == key
                }) else {
                    unmatched.append(summary.gameName)
                    continue
                }

                var updated = record
                updated.sparkPlaytimeSeconds = summary.runtimeSeconds
                updated.sparkLastSaveAt = summary.lastSaveAt
                updated.sparkLastBackupAt = summary.lastBackupAt
                updated.sparkRenpyVersion = summary.renpyVersion
                updated.sparkSaveCount = summary.saveCount
                // Spark 的备份时间和存档时间都不能冒充真实启动时间。
                updated.sparkLastLaunchAt = nil
                library.update(updated)
            }

            unmatchedGameNames = unmatched.sorted()
            let now = Date()
            lastSyncAt = now
            UserDefaults.standard.set(now, forKey: lastSyncKey)
        } catch {
            errorMessage = "扫描 Spark 数据失败：\(error.localizedDescription)"
        }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

private struct SparkSaveMetadata {
    let runtimeSeconds: Double?
    let createdAt: Date?
    let renpyVersion: String?
}

private struct SparkAggregate {
    var runtimeSeconds: Double = 0
    var lastSaveAt: Date?
    var lastBackupAt: Date?
    var renpyVersion: String?
    var versionDate: Date?
    var saveCount: Int = 0

    mutating func merge(_ metadata: SparkSaveMetadata, countAsActiveSave: Bool) {
        if let runtime = metadata.runtimeSeconds {
            runtimeSeconds = max(runtimeSeconds, runtime)
        }
        if let date = metadata.createdAt {
            if lastSaveAt == nil || date > lastSaveAt! {
                lastSaveAt = date
            }
            if versionDate == nil || date >= versionDate! {
                versionDate = date
                if let version = metadata.renpyVersion {
                    renpyVersion = version
                }
            }
        } else if renpyVersion == nil {
            renpyVersion = metadata.renpyVersion
        }
        if countAsActiveSave { saveCount += 1 }
    }
}

private enum SparkArchiveScanner {
    static func scan(rootURL: URL) throws -> [SparkGameSummary] {
        let fileManager = FileManager.default
        let savesURL = childDirectory(named: "Saves", in: rootURL)
        let backupsURL = childDirectory(named: "Backups", in: rootURL)
        var aggregates: [String: SparkAggregate] = [:]

        if let savesURL,
           let enumerator = fileManager.enumerator(
                at: savesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
           ) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "save" {
                guard let gameName = gameNameForSave(fileURL, root: savesURL),
                      let metadata = readSaveMetadata(at: fileURL) else { continue }
                var aggregate = aggregates[gameName] ?? SparkAggregate()
                aggregate.merge(metadata, countAsActiveSave: true)
                aggregates[gameName] = aggregate
            }
        }

        if let backupsURL,
           let enumerator = fileManager.enumerator(
                at: backupsURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
           ) {
            for case let backupURL as URL in enumerator where backupURL.pathExtension.lowercased() == "zip" {
                guard let gameName = gameNameForBackup(backupURL),
                      let backupDate = backupDateFromFilename(backupURL.lastPathComponent) else { continue }
                var aggregate = aggregates[gameName] ?? SparkAggregate()
                if aggregate.lastBackupAt == nil || backupDate > aggregate.lastBackupAt! {
                    aggregate.lastBackupAt = backupDate
                }
                aggregates[gameName] = aggregate
                mergeNestedSaves(from: backupURL, gameName: gameName, into: &aggregates)
            }
        }

        return aggregates.map { name, aggregate in
            SparkGameSummary(
                gameName: name,
                runtimeSeconds: aggregate.runtimeSeconds,
                lastSaveAt: aggregate.lastSaveAt,
                lastBackupAt: aggregate.lastBackupAt,
                renpyVersion: aggregate.renpyVersion,
                saveCount: aggregate.saveCount
            )
        }.sorted { $0.gameName.localizedCaseInsensitiveCompare($1.gameName) == .orderedAscending }
    }

    private static func childDirectory(named name: String, in root: URL) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return children.first {
            $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func gameNameForSave(_ url: URL, root: URL) -> String? {
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        guard let first = relative.split(separator: "/").first else { return nil }
        return String(first)
    }

    private static func gameNameForBackup(_ url: URL) -> String? {
        let filename = url.deletingPathExtension().lastPathComponent
        if let range = filename.range(of: "_SLOT", options: [.caseInsensitive]) {
            return String(filename[..<range.lowerBound])
        }
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? nil : parent
    }

    private static func backupDateFromFilename(_ filename: String) -> Date? {
        guard let regex = try? NSRegularExpression(
            pattern: #"backup_(\d{8})_(\d{6})"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = regex.firstMatch(in: filename, range: range),
              let dateRange = Range(match.range(at: 1), in: filename),
              let timeRange = Range(match.range(at: 2), in: filename) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(filename[dateRange]) + String(filename[timeRange]))
    }

    private static func readSaveMetadata(at url: URL) -> SparkSaveMetadata? {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        var jsonData = Data()
        var versionData = Data()

        for entry in archive {
            let name = URL(fileURLWithPath: entry.path).lastPathComponent.lowercased()
            if name == "json" {
                _ = try? archive.extract(entry) { jsonData.append($0) }
            } else if name == "renpy_version" {
                _ = try? archive.extract(entry) { versionData.append($0) }
            }
            if !jsonData.isEmpty && !versionData.isEmpty { break }
        }

        guard !jsonData.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: jsonData),
              let values = object as? [String: Any] else { return nil }

        let runtime = (values["_game_runtime"] as? NSNumber)?.doubleValue
        let timestamp = (values["_ctime"] as? NSNumber)?.doubleValue
        let createdAt = timestamp.map { Date(timeIntervalSince1970: $0) }
        let versionText = String(data: versionData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = versionText?.isEmpty == false
            ? versionText
            : versionFromJSON(values["_renpy_version"])
        return SparkSaveMetadata(
            runtimeSeconds: runtime,
            createdAt: createdAt,
            renpyVersion: version
        )
    }

    private static func versionFromJSON(_ value: Any?) -> String? {
        guard let parts = value as? [NSNumber], parts.count >= 3 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    private static func mergeNestedSaves(
        from backupURL: URL,
        gameName: String,
        into aggregates: inout [String: SparkAggregate]
    ) {
        guard let archive = try? Archive(url: backupURL, accessMode: .read) else { return }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-Spark-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        for entry in archive where entry.path.lowercased().hasSuffix(".save") {
            let extractedURL = temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("save")
            guard (try? archive.extract(entry, to: extractedURL)) != nil,
                  let metadata = readSaveMetadata(at: extractedURL) else { continue }
            var aggregate = aggregates[gameName] ?? SparkAggregate()
            aggregate.merge(metadata, countAsActiveSave: false)
            aggregates[gameName] = aggregate
        }
    }
}

import Foundation
import CryptoKit
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
    var duplicateSaveCount: Int
    var saveSources: [String]
}

@MainActor
final class SparkSyncStore: ObservableObject {
    static let shared = SparkSyncStore()

    @Published private(set) var saveFolderName: String?
    @Published private(set) var backupFolderName: String?
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var summaries: [SparkGameSummary] = []
    @Published private(set) var unmatchedGameNames: [String] = []
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?

    private let saveBookmarkKey = "itchPocket.sparkAllSavesBookmark.v1"
    private let backupBookmarkKey = "itchPocket.sparkBackupsBookmark.v1"
    private let lastSyncKey = "itchPocket.sparkLastSyncAt.v1"

    private init() {
        saveFolderName = UserDefaults.standard.string(forKey: "itchPocket.sparkAllSavesFolderName.v1")
        backupFolderName = UserDefaults.standard.string(forKey: "itchPocket.sparkBackupsFolderName.v1")
        lastSyncAt = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    func selectSaveFolder(_ url: URL, library: PersonalLibraryStore) async {
        await saveFolder(url, bookmarkKey: saveBookmarkKey, nameKey: "itchPocket.sparkAllSavesFolderName.v1")
        await rescan(library: library)
    }

    func selectBackupFolder(_ url: URL, library: PersonalLibraryStore) async {
        await saveFolder(url, bookmarkKey: backupBookmarkKey, nameKey: "itchPocket.sparkBackupsFolderName.v1")
        await rescan(library: library)
    }

    private func saveFolder(_ url: URL, bookmarkKey: String, nameKey: String) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        if let bookmark {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
            if bookmarkKey == saveBookmarkKey { saveFolderName = url.lastPathComponent }
            if bookmarkKey == backupBookmarkKey { backupFolderName = url.lastPathComponent }
        } else {
            errorMessage = "无法保存文件夹授权，请重新选择该目录。"
        }
    }

    func rescan(library: PersonalLibraryStore) async {
        guard !isScanning else { return }
        let saveURL = resolveFolder(bookmarkKey: saveBookmarkKey)
        let backupURL = resolveFolder(bookmarkKey: backupBookmarkKey)
        guard saveURL != nil || backupURL != nil else {
            errorMessage = "请分别选择 itchPocket-allsaves 和 itchPocket-backups 文件夹。"
            return
        }

        let saveAccess = saveURL?.startAccessingSecurityScopedResource() ?? false
        let backupAccess = backupURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if saveAccess, let saveURL { saveURL.stopAccessingSecurityScopedResource() }
            if backupAccess, let backupURL { backupURL.stopAccessingSecurityScopedResource() }
        }

        await scanFolders(saveURL: saveURL, backupURL: backupURL, library: library)
    }

    private func resolveFolder(bookmarkKey: String) -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale, let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            }
            return url
        } catch {
            return nil
        }
    }

    private func scanFolders(saveURL: URL?, backupURL: URL?, library: PersonalLibraryStore) async {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        summaries = []
        unmatchedGameNames = []
        defer { isScanning = false }

        do {
            let found = try await Task.detached(priority: .utility) {
                try SparkArchiveScanner.scan(saveRootURL: saveURL, backupRootURL: backupURL)
            }.value

            summaries = found
            var unmatched: [String] = []
            for summary in found {
                let key = Self.normalized(summary.gameName)
                guard let record = library.records.first(where: { Self.normalized($0.title) == key }) else {
                    unmatched.append(summary.gameName)
                    continue
                }
                var updated = record
                updated.sparkPlaytimeSeconds = summary.runtimeSeconds
                updated.sparkLastSaveAt = summary.lastSaveAt
                updated.sparkLastBackupAt = summary.lastBackupAt
                updated.sparkRenpyVersion = summary.renpyVersion
                updated.sparkSaveCount = summary.saveCount
                updated.sparkLastLaunchAt = nil
                library.update(updated)
            }

            unmatchedGameNames = unmatched.sorted()
            let now = Date()
            lastSyncAt = now
            UserDefaults.standard.set(now, forKey: lastSyncKey)
        } catch {
            errorMessage = "扫描 itchPocket 存档目录失败：\\(error.localizedDescription)"
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
    var gameName: String
    var runtimeSeconds: Double = 0
    var lastSaveAt: Date?
    var lastBackupAt: Date?
    var renpyVersion: String?
    var versionDate: Date?
    var saveIdentities = Set<String>()
    var rawSaveCount = 0
    var saveSources = Set<String>()

    init(gameName: String) {
        self.gameName = gameName
    }

    var saveCount: Int { saveIdentities.count }
    var duplicateSaveCount: Int { max(0, rawSaveCount - saveIdentities.count) }

    mutating func merge(_ metadata: SparkSaveMetadata, saveIdentity: String?, source: String?) {
        if let runtime = metadata.runtimeSeconds, runtime.isFinite {
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
        if let saveIdentity {
            rawSaveCount += 1
            saveIdentities.insert(saveIdentity.lowercased())
        }
        if let source { saveSources.insert(source) }
    }
}

private enum SparkArchiveScanner {
    enum ScanError: LocalizedError {
        case sparkFoldersNotFound

        var errorDescription: String? {
            switch self {
            case .sparkFoldersNotFound:
                return "没有识别到存档文件夹。请检查是否选择了 itchPocket-allsaves 和 itchPocket-backups。"
            }
        }
    }

    static func scan(saveRootURL: URL?, backupRootURL: URL?) throws -> [SparkGameSummary] {
        let fileManager = FileManager.default
        guard saveRootURL != nil || backupRootURL != nil else {
            throw ScanError.sparkFoldersNotFound
        }

        var aggregates: [String: SparkAggregate] = [:]
        var visitedSaveFiles = Set<String>()

        if let savesURL = saveRootURL,
           let enumerator = fileManager.enumerator(
                at: savesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
           ) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "save" {
                let fileKey = fileURL.standardizedFileURL.path
                guard visitedSaveFiles.insert(fileKey).inserted,
                      let gameName = gameNameForSave(fileURL, root: savesURL),
                      let metadata = readSaveMetadata(at: fileURL) else { continue }
                let key = normalizedGameName(gameName)
                var aggregate = aggregates[key] ?? SparkAggregate(gameName: gameName)
                let saveIdentity: String
                if let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
                    saveIdentity = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                } else {
                    saveIdentity = fileURL.standardizedFileURL.path
                }
                aggregate.merge(metadata, saveIdentity: saveIdentity, source: "allsaves")
                aggregates[key] = aggregate
            }
        }

        if let backupsURL = backupRootURL,
           let enumerator = fileManager.enumerator(
                at: backupsURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
           ) {
            for case let backupURL as URL in enumerator where backupURL.pathExtension.lowercased() == "zip" {
                guard let backupDate = backupDateFromFilename(backupURL.lastPathComponent),
                      let gameName = gameNameForBackup(backupURL, root: backupsURL) else { continue }
                let key = normalizedGameName(gameName)
                var aggregate = aggregates[key] ?? SparkAggregate(gameName: gameName)
                if aggregate.lastBackupAt == nil || backupDate > aggregate.lastBackupAt! {
                    aggregate.lastBackupAt = backupDate
                }
                aggregates[key] = aggregate
                mergeNestedSaves(from: backupURL, gameName: gameName, into: &aggregates)
            }
        }

        return aggregates.values.map { aggregate in
            SparkGameSummary(
                gameName: aggregate.gameName,
                runtimeSeconds: aggregate.runtimeSeconds,
                lastSaveAt: aggregate.lastSaveAt,
                lastBackupAt: aggregate.lastBackupAt,
                renpyVersion: aggregate.renpyVersion,
                saveCount: aggregate.saveCount,
                duplicateSaveCount: aggregate.duplicateSaveCount,
                saveSources: aggregate.saveSources.sorted()
            )
        }.sorted { $0.gameName.localizedCaseInsensitiveCompare($1.gameName) == .orderedAscending }
    }

    private static func normalizedGameName(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func gameNameForSave(_ url: URL, root: URL) -> String? {
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        guard let first = relative.split(separator: "/").first else { return nil }
        return String(first)
    }

    private static func gameNameForBackup(_ url: URL, root: URL) -> String? {
        let components = url.deletingLastPathComponent().path
            .replacingOccurrences(of: root.path, with: "")
            .split(separator: "/")
            .map(String.init)
        if let autoBackupIndex = components.lastIndex(where: {
            $0.caseInsensitiveCompare("autoBackup") == .orderedSame
        }), autoBackupIndex > 0 {
            return components[autoBackupIndex - 1]
        }
        if let parent = components.last, !parent.isEmpty,
           parent.caseInsensitiveCompare("backups") != .orderedSame {
            return parent
        }
        return nil
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
            let key = normalizedGameName(gameName)
            var aggregate = aggregates[key] ?? SparkAggregate(gameName: gameName)
            // Backup contents are historical snapshots, not additional active save slots.
            aggregate.merge(metadata, saveIdentity: nil, source: nil)
            aggregates[key] = aggregate
        }
    }
}

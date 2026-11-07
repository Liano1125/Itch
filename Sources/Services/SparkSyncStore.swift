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

        folderName = url.lastPathComponent
        UserDefaults.standard.set(folderName, forKey: "itchPocket.sparkFolderName.v1")

        // A bookmark is useful for later scans, but failure to create one must not
        // prevent the first scan of the folder the user just selected.
        if let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }

        await scanFolder(url, library: library)
    }

    func rescan(library: PersonalLibraryStore) async {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            errorMessage = "尚未保存文件夹访问授权。请重新选择 Spark 本地数据文件夹。"
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

            if isStale, let refreshed = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
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
        summaries = []
        unmatchedGameNames = []
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
        if countAsActiveSave { saveCount += 1 }
    }
}

private enum SparkArchiveScanner {
    enum ScanError: LocalizedError {
        case sparkFoldersNotFound

        var errorDescription: String? {
            switch self {
            case .sparkFoldersNotFound:
                return "没有识别到 Spark 存档目录。请选择包含 saves 和 backups 的 Spark 本地数据文件夹；程序会读取 saves/renpy/saves、saves/staging/saves 与 backups。"
            }
        }
    }

    static func scan(rootURL: URL) throws -> [SparkGameSummary] {
        let fileManager = FileManager.default
        let saveRoots = locateSaveRoots(under: rootURL)
        let backupsURL = locateDirectory(named: "backups", under: rootURL, maxDepth: 5)
        guard !saveRoots.isEmpty || backupsURL != nil else {
            throw ScanError.sparkFoldersNotFound
        }

        var aggregates: [String: SparkAggregate] = [:]
        var visitedSaveFiles = Set<String>()

        for savesURL in saveRoots {
            guard let enumerator = fileManager.enumerator(
                at: savesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "save" {
                let fileKey = fileURL.standardizedFileURL.path
                guard visitedSaveFiles.insert(fileKey).inserted,
                      let gameName = gameNameForSave(fileURL, root: savesURL),
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
                guard let backupDate = backupDateFromFilename(backupURL.lastPathComponent),
                      let gameName = gameNameForBackup(backupURL, root: backupsURL) else { continue }

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

    // Prefer Spark's known on-device layout instead of selecting the first
    // arbitrary directory named "saves" (which may be an outer container).
    private static func locateSaveRoots(under root: URL) -> [URL] {
        let preferredRelativePaths = [
            "saves/renpy/saves",
            "saves/staging/saves",
            "renpy/saves",
            "staging/saves"
        ]
        var results: [URL] = []

        for relativePath in preferredRelativePaths {
            let candidate = relativePath.split(separator: "/").reduce(root) {
                $0.appendingPathComponent(String($1), isDirectory: true)
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                results.append(candidate)
            }
        }

        if results.isEmpty {
            // Allow a selected folder that is itself the Ren'Py saves directory.
            if containsSaveFiles(root) {
                results.append(root)
            } else if let nested = locateDirectory(named: "saves", under: root, maxDepth: 5),
                      containsSaveFiles(nested) {
                results.append(nested)
            }
        }
        return results
    }

    private static func containsSaveFiles(_ directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "save" { return true }
        }
        return false
    }

    private static func locateDirectory(named name: String, under root: URL, maxDepth: Int) -> URL? {
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var visited = Set<String>()

        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard visited.insert(current.url.standardizedFileURL.path).inserted,
                  current.depth < maxDepth,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: current.url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }

            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                if child.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame {
                    return child
                }
                queue.append((child, current.depth + 1))
            }
        }
        return nil
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
            var aggregate = aggregates[gameName] ?? SparkAggregate()
            aggregate.merge(metadata, countAsActiveSave: false)
            aggregates[gameName] = aggregate
        }
    }
}

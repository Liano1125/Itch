import Foundation
import CryptoKit
import SwiftUI
import ZIPFoundation

struct SparkGameSummary: Identifiable {
    var id: String { gameName.lowercased() }
    let gameName: String
    var runtimeSeconds: Double
    var lastSaveAt: Date?
    var renpyVersion: String?
    var saveCount: Int
    var duplicateSaveCount: Int
    var saveSources: [String]
}

@MainActor
final class SparkSyncStore: ObservableObject {
    static let shared = SparkSyncStore()

    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var summaries: [SparkGameSummary] = []
    @Published private(set) var unmatchedGameNames: [String] = []
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?

    private let lastSyncKey = "itchPocket.sparkLastSyncAt.v2"
    private let savesFolderName = "Allsaves"

    private init() {
        lastSyncAt = try? AppDatabase.shared.state(for: lastSyncKey)?.dateValue
    }

    /// Creates the fixed Allsaves folder inside the app's shared Documents directory.
    /// With file sharing enabled, Shortcuts and Files can copy into this folder.
    func prepareFolders() throws {
        let documents = try documentsDirectory()
        let manager = FileManager.default
        let folder = documents.appendingPathComponent(savesFolderName, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func rescan(library: PersonalLibraryStore) async {
        guard !isScanning else { return }
        do {
            try prepareFolders()
            let documents = try documentsDirectory()
            let savesURL = documents.appendingPathComponent(savesFolderName, isDirectory: true)
            await scanFolders(saveURL: savesURL, library: library)
        } catch {
            errorMessage = "无法准备 itchPocket 存档目录：\(error.localizedDescription)"
        }
    }

    private func documentsDirectory() throws -> URL {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "itchPocket.SparkSync", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法访问应用 Documents 目录。"
            ])
        }
        return url
    }

    private func scanFolders(saveURL: URL, library: PersonalLibraryStore) async {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        summaries = []
        unmatchedGameNames = []
        defer { isScanning = false }

        do {
            let found = try await Task.detached(priority: .utility) {
                try SparkArchiveScanner.scan(saveRootURL: saveURL)
            }.value

            summaries = found
            var unmatched: [String] = []
            var metadataByGameID: [String: SparkPlayMetadata] = [:]
            for summary in found {
                let key = Self.normalized(summary.gameName)
                guard let record = library.records.first(where: { Self.normalized($0.title) == key }) else {
                    unmatched.append(summary.gameName)
                    continue
                }
                metadataByGameID[record.id] = SparkPlayMetadata(
                    runtimeSeconds: summary.runtimeSeconds,
                    lastSaveAt: summary.lastSaveAt,
                    renpyVersion: summary.renpyVersion,
                    saveCount: summary.saveSources.contains("正式存档") ? summary.saveCount : nil
                )
            }
            library.updateSparkMetadata(metadataByGameID)

            unmatchedGameNames = unmatched.sorted()
            let now = Date()
            lastSyncAt = now
            try? AppDatabase.shared.setState(now, for: lastSyncKey)
        } catch {
            errorMessage = "扫描 itchPocket 存档目录失败：\(error.localizedDescription)"
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
                return "没有识别到正式存档。请检查 itchPocket/Allsaves 文件夹是否包含游戏存档。"
            }
        }
    }

    static func scan(saveRootURL: URL) throws -> [SparkGameSummary] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: saveRootURL.path) else {
            throw ScanError.sparkFoldersNotFound
        }

        var aggregates: [String: SparkAggregate] = [:]
        var visitedSaveFiles = Set<String>()

        let savesURL = saveRootURL
        if let enumerator = fileManager.enumerator(
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
                aggregate.merge(metadata, saveIdentity: saveIdentity, source: "正式存档")
                aggregates[key] = aggregate
            }
        }



        return aggregates.values.map { aggregate in
            SparkGameSummary(
                gameName: aggregate.gameName,
                runtimeSeconds: aggregate.runtimeSeconds,
                lastSaveAt: aggregate.lastSaveAt,
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
        let components = relative.split(separator: "/").map(String.init)
        guard var folderName = components.first else { return nil }

        // Ren'Py/Spark may prefix private save directories with "private".
        // Handle both "private/Game Name/slot.save" and
        // "privateGame Name/slot.save" layouts.
        if folderName.caseInsensitiveCompare("private") == .orderedSame {
            guard components.count > 1 else { return nil }
            folderName = components[1]
        } else if folderName.lowercased().hasPrefix("private"),
                  folderName.count > "private".count {
            folderName = String(folderName.dropFirst("private".count))
        }

        let cleaned = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
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

}

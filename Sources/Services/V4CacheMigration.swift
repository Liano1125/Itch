import CryptoKit
import Foundation
import SwiftData

struct V4TranslationCacheMigrationReport: Equatable {
    let rowCount: Int
    let inventoryDigest: String
}

struct V4TranslationCacheVerificationReport: Equatable {
    let verifiedRows: Int
    let unverifiedRows: Int
    let diagnostics: [String]
    var isVerified: Bool { unverifiedRows == 0 && diagnostics.isEmpty }
}

/// Translation entries are shared, rebuildable results for public game descriptions
/// and devlogs. Preserve them to avoid unnecessary provider/API usage. Only the
/// two currently supported public-content scopes are eligible for migration.
@MainActor
enum V4TranslationCacheConverter {
    enum ConversionError: LocalizedError, Equatable {
        case sourceHasPendingChanges
        case destinationHasPendingChanges
        case destinationNotEmpty
        case unsupportedScope

        var errorDescription: String? {
            switch self {
            case .sourceHasPendingChanges: return "The V3 source context must be clean before translation-cache migration."
            case .destinationHasPendingChanges: return "The V4 staging context must be clean before translation-cache migration."
            case .destinationNotEmpty: return "The V4 translation cache must be empty before conversion."
            case .unsupportedScope: return "A translation cache row has an unclassified scope and cannot be migrated safely."
            }
        }
    }

    static func convert(source: ModelContext, destination: ModelContext) throws -> V4TranslationCacheMigrationReport {
        guard !source.hasChanges else { throw ConversionError.sourceHasPendingChanges }
        guard !destination.hasChanges else { throw ConversionError.destinationHasPendingChanges }
        let rows = try source.fetch(FetchDescriptor<DBTranslation>())
        guard rows.allSatisfy({ isSupportedPublicScope($0.scope) }) else {
            throw ConversionError.unsupportedScope
        }
        guard try destination.fetchCount(FetchDescriptor<DBTranslation>()) == 0 else {
            throw ConversionError.destinationNotEmpty
        }

        let sorted = rows.sorted { $0.cacheKey < $1.cacheKey }
        let digest = inventoryDigest(for: sorted.map(\.cacheKey))
        do {
            for row in sorted {
                destination.insert(DBTranslation(
                    cacheKey: row.cacheKey,
                    scope: row.scope,
                    sourceHash: row.sourceHash,
                    sourceText: row.sourceText,
                    targetLanguage: row.targetLanguage,
                    translatedText: row.translatedText,
                    updatedAt: row.updatedAt
                ))
            }
            try destination.save()
        } catch {
            destination.rollback()
            throw error
        }
        return V4TranslationCacheMigrationReport(rowCount: sorted.count, inventoryDigest: digest)
    }

    static func isSupportedPublicScope(_ scope: String) -> Bool {
        scope.hasPrefix("game-description:") || scope.hasPrefix("devlog:")
    }

    static func inventoryDigest(for keys: [String]) -> String {
        let lines = keys.sorted().map { "translation:\($0)" }
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
enum V4TranslationCacheVerifier {
    private struct Value: Equatable {
        let cacheKey: String
        let scope: String
        let sourceHash: String
        let sourceText: String
        let targetLanguage: String
        let translatedText: String
        let updatedAt: Date

        init(_ row: DBTranslation) {
            cacheKey = row.cacheKey
            scope = row.scope
            sourceHash = row.sourceHash
            sourceText = row.sourceText
            targetLanguage = row.targetLanguage
            translatedText = row.translatedText
            updatedAt = row.updatedAt
        }
    }

    static func verify(source: ModelContext, destination: ModelContext) throws -> V4TranslationCacheVerificationReport {
        guard !source.hasChanges, !destination.hasChanges else {
            return V4TranslationCacheVerificationReport(
                verifiedRows: 0, unverifiedRows: 1,
                diagnostics: ["migration.translations.pendingContextChanges"]
            )
        }
        let sourceRows = try source.fetch(FetchDescriptor<DBTranslation>())
        let destinationRows = try destination.fetch(FetchDescriptor<DBTranslation>())
        let lhs = Dictionary(grouping: sourceRows.map(Value.init), by: \.cacheKey)
        let rhs = Dictionary(grouping: destinationRows.map(Value.init), by: \.cacheKey)
        var verified = 0
        var unverified = 0
        var diagnostics = Set<String>()
        for key in Set(lhs.keys).union(rhs.keys) {
            let a = lhs[key] ?? []
            let b = rhs[key] ?? []
            if a.count == 1, b.count == 1, a[0] == b[0] {
                verified += 1
            } else {
                unverified += a.count + b.count
                diagnostics.insert("migration.translations.rowMismatch")
            }
        }
        if sourceRows.contains(where: { !V4TranslationCacheConverter.isSupportedPublicScope($0.scope) }) {
            diagnostics.insert("migration.translations.unsupportedScope")
            unverified += 1
        }
        return V4TranslationCacheVerificationReport(
            verifiedRows: verified, unverifiedRows: unverified,
            diagnostics: diagnostics.sorted()
        )
    }
}

struct V4DiscoveryCacheDispositionReport: Equatable {
    let discardedRowCount: Int
    let inventoryDigest: String
}

/// Discovery snapshots are TTL-bound serialized responses, not canonical data.
/// They are deliberately omitted from V4 staging and rebuilt on demand.
@MainActor
enum V4DiscoveryCacheDisposition {
    enum DispositionError: LocalizedError, Equatable {
        case sourceHasPendingChanges
        case destinationHasPendingChanges
        case destinationNotEmpty

        var errorDescription: String? {
            switch self {
            case .sourceHasPendingChanges: return "The V3 source context must be clean before discovery-cache disposition."
            case .destinationHasPendingChanges: return "The V4 staging context must be clean before discovery-cache disposition."
            case .destinationNotEmpty: return "The V4 discovery cache must be empty because legacy snapshots are intentionally discarded."
            }
        }
    }

    static func discard(source: ModelContext, destination: ModelContext) throws -> V4DiscoveryCacheDispositionReport {
        guard !source.hasChanges else { throw DispositionError.sourceHasPendingChanges }
        guard !destination.hasChanges else { throw DispositionError.destinationHasPendingChanges }
        let rows = try source.fetch(FetchDescriptor<DBDiscoverySnapshot>())
        guard try destination.fetchCount(FetchDescriptor<DBDiscoverySnapshot>()) == 0 else {
            throw DispositionError.destinationNotEmpty
        }
        let digest = V4TranslationCacheConverter.inventoryDigest(
            for: rows.map(\.key).map { "discovery:\($0)" }
        )
        return V4DiscoveryCacheDispositionReport(
            discardedRowCount: rows.count,
            inventoryDigest: digest
        )
    }

    static func verify(
        source: ModelContext,
        destination: ModelContext,
        report: V4DiscoveryCacheDispositionReport
    ) throws -> Bool {
        guard !source.hasChanges, !destination.hasChanges else { return false }
        let sourceRows = try source.fetch(FetchDescriptor<DBDiscoverySnapshot>())
        let destinationCount = try destination.fetchCount(FetchDescriptor<DBDiscoverySnapshot>())
        let digest = V4TranslationCacheConverter.inventoryDigest(
            for: sourceRows.map(\.key).map { "discovery:\($0)" }
        )
        return destinationCount == 0
            && sourceRows.count == report.discardedRowCount
            && digest == report.inventoryDigest
    }
}

import Foundation

/// A gate between the read-only V3 inventory and the V4 library copy.
/// It proves that the converted personal-library row counts match the source
/// inventory and refuses to accept a structurally invalid V3 store.
enum V4LibraryMigrationParityGate {
    enum GateError: LocalizedError, Equatable {
        case sourceIntegrityIssues([String])
        case countMismatch(domain: String, source: Int, converted: Int)

        var errorDescription: String? {
            switch self {
            case .sourceIntegrityIssues(let issues):
                return "V3 migration preflight reported integrity issues: \(issues.joined(separator: ", "))."
            case .countMismatch(let domain, let source, let converted):
                return "V3/V4 migration count mismatch for \(domain): source=\(source), converted=\(converted)."
            }
        }
    }

    static func validate(
        source: V3MigrationPreflightReport,
        converted: V4LegacyLibraryMigrationReport
    ) throws {
        guard source.isStructurallyValid else {
            throw GateError.sourceIntegrityIssues(source.integrityIssues)
        }

        let expected: [(String, Int, Int)] = [
            ("libraryEntries", source.rowCounts["libraryEntries"] ?? 0, converted.libraryEntryCount),
            ("collections", source.rowCounts["collections"] ?? 0, converted.collectionCount),
            ("collectionItems", source.rowCounts["collectionItems"] ?? 0, converted.collectionItemCount),
            ("libraryStatusEvents", source.rowCounts["libraryStatusEvents"] ?? 0, converted.statusEventCount)
        ]

        for (domain, sourceCount, convertedCount) in expected where sourceCount != convertedCount {
            throw GateError.countMismatch(
                domain: domain,
                source: sourceCount,
                converted: convertedCount
            )
        }
    }
}

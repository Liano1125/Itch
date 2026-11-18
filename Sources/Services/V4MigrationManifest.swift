import Foundation

/// Describes what a migration run observed without storing source payloads.
/// Diagnostics must be stable machine-readable codes, never user-authored text.
enum V4MigrationDomainDisposition: String, Codable, Equatable {
    case migrated
    case discardedRebuildableCache
}

enum V4MigrationDigestKind: String, Codable, Equatable {
    case structuralSHA256
    case stableIdentitySHA256
    case keyOnlySHA256
}

enum V4MigrationPayloadVerificationStatus: String, Codable, Equatable {
    case notRun
    case partial
    case verified
    case failed
}

enum V4MigrationPayloadVerificationMethod: String, Codable, Equatable {
    case none
    case identityAndCounts
    case fieldByFieldCanonicalValues
}

struct V4MigrationPayloadVerificationSummary: Codable, Equatable {
    let status: V4MigrationPayloadVerificationStatus
    let method: V4MigrationPayloadVerificationMethod
    let verifiedRows: Int
    let unverifiedRows: Int
}

struct V4MigrationDomainManifest: Codable, Equatable {
    let disposition: V4MigrationDomainDisposition
    let sourceRowCount: Int
    let destinationRowCount: Int
    /// Counts are partitioned by destination scope; values must sum to destinationRowCount.
    let scopeCounts: [String: Int]
    let quarantinedRowCount: Int
    /// Domain-specific digest. Its meaning is defined by digestKind.
    let inventoryDigest: String?
    let digestKind: V4MigrationDigestKind?
    let payloadVerification: V4MigrationPayloadVerificationSummary
    /// Stable diagnostic codes only. Never include keys, notes, tokens, or payload values.
    let integrityDiagnostics: [String]

    init(
        disposition: V4MigrationDomainDisposition = .migrated,
        sourceRowCount: Int,
        destinationRowCount: Int,
        scopeCounts: [String: Int],
        quarantinedRowCount: Int,
        inventoryDigest: String?,
        digestKind: V4MigrationDigestKind?,
        payloadVerification: V4MigrationPayloadVerificationSummary,
        integrityDiagnostics: [String]
    ) {
        self.disposition = disposition
        self.sourceRowCount = sourceRowCount
        self.destinationRowCount = destinationRowCount
        self.scopeCounts = scopeCounts
        self.quarantinedRowCount = quarantinedRowCount
        self.inventoryDigest = inventoryDigest
        self.digestKind = digestKind
        self.payloadVerification = payloadVerification
        self.integrityDiagnostics = integrityDiagnostics
    }

    var hasConsistentScopeCounts: Bool {
        scopeCounts.values.allSatisfy { $0 >= 0 } &&
        scopeCounts.values.reduce(0, +) == destinationRowCount
    }

    private var hasValidDigest: Bool {
        guard let inventoryDigest, digestKind != nil else { return false }
        return V4MigrationManifest.isSHA256Hex(inventoryDigest)
    }

    var isPromotionEligible: Bool {
        let dispositionIsValid: Bool
        switch disposition {
        case .migrated:
            dispositionIsValid = payloadVerification.status == .verified
                && payloadVerification.verifiedRows >= destinationRowCount
        case .discardedRebuildableCache:
            dispositionIsValid = destinationRowCount == 0
                && quarantinedRowCount == 0
                && payloadVerification.status == .verified
                && payloadVerification.method == .identityAndCounts
                && payloadVerification.verifiedRows >= sourceRowCount
        }
        return sourceRowCount >= 0 &&
        destinationRowCount >= 0 &&
        quarantinedRowCount >= 0 &&
        quarantinedRowCount <= destinationRowCount &&
        hasConsistentScopeCounts &&
        hasValidDigest &&
        dispositionIsValid &&
        payloadVerification.unverifiedRows == 0 &&
        integrityDiagnostics.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case disposition, sourceRowCount, destinationRowCount, scopeCounts, quarantinedRowCount
        case inventoryDigest, digestKind, payloadVerification, integrityDiagnostics
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        disposition = try values.decodeIfPresent(V4MigrationDomainDisposition.self, forKey: .disposition) ?? .migrated
        sourceRowCount = try values.decode(Int.self, forKey: .sourceRowCount)
        destinationRowCount = try values.decode(Int.self, forKey: .destinationRowCount)
        scopeCounts = try values.decode([String: Int].self, forKey: .scopeCounts)
        quarantinedRowCount = try values.decode(Int.self, forKey: .quarantinedRowCount)
        inventoryDigest = try values.decodeIfPresent(String.self, forKey: .inventoryDigest)
        digestKind = try values.decodeIfPresent(V4MigrationDigestKind.self, forKey: .digestKind)
        payloadVerification = try values.decode(V4MigrationPayloadVerificationSummary.self, forKey: .payloadVerification)
        integrityDiagnostics = try values.decode([String].self, forKey: .integrityDiagnostics)
    }
}

/// Versioned, privacy-safe record of a V3 → V4 migration attempt.
///
/// This is a value type only. It does not open databases, perform conversion,
/// authorize production cutover, or persist itself. Callers must write it to
/// an isolated staging location only after deciding the appropriate lifecycle.
struct V4MigrationManifest: Codable, Equatable {
    static let currentManifestVersion = 1

    let manifestVersion: Int
    let runID: String
    let generatedAt: Date
    let sourceSchemaVersion: String
    let destinationSchemaVersion: String
    let registryVersion: Int
    let sourceRowCount: Int
    let sourceInventoryDigest: String
    let domains: [String: V4MigrationDomainManifest]
    /// Stable diagnostic codes only; no source payload or identity values.
    let integrityDiagnostics: [String]
    /// Must be present and valid before the manifest can pass its safety predicate.
    let referenceVerification: V4StoreReferenceVerificationReport?

    init(
        runID: String,
        generatedAt: Date,
        sourceSchemaVersion: String,
        destinationSchemaVersion: String,
        registryVersion: Int,
        sourceRowCount: Int,
        sourceInventoryDigest: String,
        domains: [String: V4MigrationDomainManifest],
        integrityDiagnostics: [String] = [],
        referenceVerification: V4StoreReferenceVerificationReport? = nil
    ) {
        self.manifestVersion = Self.currentManifestVersion
        self.runID = runID
        self.generatedAt = generatedAt
        self.sourceSchemaVersion = sourceSchemaVersion
        self.destinationSchemaVersion = destinationSchemaVersion
        self.registryVersion = registryVersion
        self.sourceRowCount = sourceRowCount
        self.sourceInventoryDigest = sourceInventoryDigest
        self.domains = domains
        self.integrityDiagnostics = integrityDiagnostics.sorted()
        self.referenceVerification = referenceVerification
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }

    /// A descriptive safety predicate only. Production promotion still requires
    /// independent backup, SQLite, restart-recovery, and rollback gates.
    var isPromotionEligible: Bool {
        manifestVersion == Self.currentManifestVersion &&
        !runID.isEmpty &&
        !sourceSchemaVersion.isEmpty &&
        !destinationSchemaVersion.isEmpty &&
        registryVersion > 0 &&
        sourceRowCount >= 0 &&
        Self.isSHA256Hex(sourceInventoryDigest) &&
        integrityDiagnostics.isEmpty &&
        referenceVerification?.isValid == true &&
        !domains.isEmpty &&
        domains.values.allSatisfy(\.isPromotionEligible)
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

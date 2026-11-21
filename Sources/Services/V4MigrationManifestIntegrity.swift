import CryptoKit
import Foundation

/// Integrity helpers for the small, privacy-safe V4 migration manifest.
enum V4MigrationManifestIntegrity {
    enum IntegrityError: Error, Equatable {
        case persistedManifestMismatch
    }

    /// Returns a lowercase SHA-256 digest suitable for durable journal metadata.
    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Reopens the atomically written manifest and proves it decodes to the
    /// exact value produced by the migration attempt.
    static func validatePersisted(
        data: Data,
        expected: V4MigrationManifest
    ) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(V4MigrationManifest.self, from: data),
              decoded == expected,
              decoded.runID == expected.runID else {
            throw IntegrityError.persistedManifestMismatch
        }
        return sha256Hex(of: data)
    }

    static func matches(_ data: Data, sha256Hex expectedDigest: String) -> Bool {
        sha256Hex(of: data) == expectedDigest
    }
}

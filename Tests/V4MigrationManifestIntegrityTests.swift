import XCTest
@testable import itchPocket

final class V4MigrationManifestIntegrityTests: XCTestCase {
    func testSHA256DigestDetectsAnyManifestByteMutation() {
        let original = Data("{\"runID\":\"attempt-a\",\"state\":\"validated\"}".utf8)
        var mutated = original
        mutated.append(0x20)

        let digest = V4MigrationManifestIntegrity.sha256Hex(of: original)
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(V4MigrationManifestIntegrity.matches(original, sha256Hex: digest))
        XCTAssertFalse(V4MigrationManifestIntegrity.matches(mutated, sha256Hex: digest))
    }

    func testSHA256DigestIsStableForIdenticalBytes() {
        let bytes = Data("stable-manifest".utf8)
        XCTAssertEqual(
            V4MigrationManifestIntegrity.sha256Hex(of: bytes),
            V4MigrationManifestIntegrity.sha256Hex(of: bytes)
        )
    }
}

import XCTest
@testable import itchPocket

final class AppStateScopeRegistryTests: XCTestCase {
    func testKnownDeviceAndGlobalKeysAreClassified() {
        let spark = AppStateScopeRegistry.classify("itchPocket.sparkLastSyncAt.v2")
        XCTAssertEqual(spark.scope, .device)
        XCTAssertEqual(spark.confidence, .established)
        XCTAssertFalse(spark.requiresOwnershipReview)

        let avatarVersion = AppStateScopeRegistry.classify("itchPocket.avatarResolver.version")
        XCTAssertEqual(avatarVersion.scope, .appGlobal)
        XCTAssertEqual(avatarVersion.confidence, .established)

        let detailStatus = AppStateScopeRegistry.classify("gameDetail.fetchStatus.game-123")
        XCTAssertEqual(detailStatus.scope, .appGlobal)
        XCTAssertEqual(detailStatus.family, "gameDetail.fetchStatus")
    }

    func testAccountDrivenDevlogKeysRemainProvisionalAndRequireOwnershipReview() {
        let keys = [
            "devlogSync.lastDate",
            "devlogSync.lastMessage",
            "devlogSync.lastResults",
            "itchPocket.devlogAutoSync.lastAttempt"
        ]

        for key in keys {
            let result = AppStateScopeRegistry.classify(key)
            XCTAssertEqual(result.scope, .itchAccount, key)
            XCTAssertEqual(result.confidence, .provisional, key)
            XCTAssertTrue(result.requiresOwnershipReview, key)
        }
    }

    func testDynamicCacheFamiliesRequireNonemptySuffix() {
        let cases: [(String, AppStateScopeKind)] = [
            ("gameDetail.lastSuccessfulFetch.game-1", .appGlobal),
            ("detailPrefetch.lastSuccess.game-1", .appGlobal),
            ("avatarFailure.https://example.com/avatar.png", .appGlobal)
        ]

        for (key, expectedScope) in cases {
            XCTAssertEqual(AppStateScopeRegistry.classify(key).scope, expectedScope, key)
        }

        XCTAssertEqual(
            AppStateScopeRegistry.classify("avatarFailure.").scope,
            .legacyUnclassified
        )
        XCTAssertEqual(
            AppStateScopeRegistry.classify("gameDetail.fetchStatus.").scope,
            .legacyUnclassified
        )
    }

    func testUnknownKeysArePreservedAsUnclassified() {
        let result = AppStateScopeRegistry.classify("futureFeature.privateState")
        XCTAssertEqual(result.scope, .legacyUnclassified)
        XCTAssertEqual(result.confidence, .unknown)
        XCTAssertTrue(result.requiresOwnershipReview)
        XCTAssertEqual(result.family, "unknown")
    }

    func testRegistryVersionIsExplicit() {
        XCTAssertEqual(AppStateScopeRegistry.registryVersion, 1)
    }
}

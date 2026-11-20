import XCTest
@testable import itchPocket

final class ItchAuthServiceSignOutTests: XCTestCase {
    @MainActor
    func testSignOutInvalidatesLocalSessionBeforeRemoteRevocationAndKeepsItOnFailure() async throws {
        var didDeleteLocalToken = false
        var revokedToken: String?
        var service: ItchAuthService!
        let revokeError = NSError(
            domain: "ItchAuthServiceSignOutTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Remote revocation unavailable"]
        )

        service = ItchAuthService(
            readAccessToken: { "test-access-token" },
            deleteAccessToken: {
                didDeleteLocalToken = true
            },
            revokeAccessToken: { token in
                revokedToken = token

                // The injected network boundary must only be reached after
                // local credentials and the authenticated session are invalidated.
                XCTAssertTrue(didDeleteLocalToken)
                XCTAssertNil(service.accountSession.identity)
                throw revokeError
            }
        )

        service.accountSession.activate(
            ItchAccountIdentity(itchUserID: 901, username: "sign-out-user")
        )
        let oldRequest = try XCTUnwrap(service.accountSession.captureRequestContext())

        await service.signOut()

        XCTAssertTrue(didDeleteLocalToken)
        XCTAssertEqual(revokedToken, "test-access-token")
        XCTAssertNil(service.accountSession.identity)
        XCTAssertFalse(service.accountSession.isCurrent(oldRequest))
        XCTAssertFalse(service.isSignedIn)
        XCTAssertEqual(service.errorMessage, "Remote revocation unavailable")
    }

    @MainActor
    func testSignOutWithoutStoredTokenStillInvalidatesLocalSession() async {
        var didDeleteLocalToken = false
        var didAttemptRemoteRevocation = false
        let service = ItchAuthService(
            readAccessToken: { nil },
            deleteAccessToken: {
                didDeleteLocalToken = true
            },
            revokeAccessToken: { _ in
                didAttemptRemoteRevocation = true
            }
        )
        service.accountSession.activate(
            ItchAccountIdentity(itchUserID: 902, username: "offline-user")
        )

        await service.signOut()

        XCTAssertTrue(didDeleteLocalToken)
        XCTAssertFalse(didAttemptRemoteRevocation)
        XCTAssertNil(service.accountSession.identity)
        XCTAssertFalse(service.isSignedIn)
    }

    @MainActor
    func testRestoreSessionCannotReactivateAccountAfterSignOut() async throws {
        var storedToken: String? = "restore-token"
        var didStartProfileRequest = false
        var profileContinuation: CheckedContinuation<ItchUser, Error>?

        let service = ItchAuthService(
            readAccessToken: { storedToken },
            deleteAccessToken: { storedToken = nil },
            revokeAccessToken: { _ in },
            fetchProfile: { _ in
                try await withCheckedThrowingContinuation { continuation in
                    didStartProfileRequest = true
                    profileContinuation = continuation
                }
            }
        )

        let restoreTask = Task { await service.restoreSession() }
        while !didStartProfileRequest {
            await Task.yield()
        }

        await service.signOut()
        profileContinuation?.resume(returning: ItchUser(
            id: 903,
            username: "stale-restore",
            displayName: nil,
            coverUrl: nil,
            url: nil
        ))
        profileContinuation = nil
        await restoreTask.value

        XCTAssertNil(service.user)
        XCTAssertNil(service.accountSession.identity)
        XCTAssertFalse(service.isSignedIn)
        XCTAssertNil(storedToken)
    }

}

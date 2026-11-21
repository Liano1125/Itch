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


    @MainActor
    func testNewerRestoreWinsWhenTwoRestoreRequestsOverlap() async throws {
        var storedToken: String? = "token-a"
        var startedTokens: Set<String> = []
        var continuations: [String: CheckedContinuation<ItchUser, Error>] = [:]

        let service = ItchAuthService(
            readAccessToken: { storedToken },
            deleteAccessToken: { storedToken = nil },
            revokeAccessToken: { _ in },
            fetchProfile: { token in
                try await withCheckedThrowingContinuation { continuation in
                    startedTokens.insert(token)
                    continuations[token] = continuation
                }
            }
        )

        let firstRestore = Task { await service.restoreSession() }
        while !startedTokens.contains("token-a") {
            await Task.yield()
        }

        storedToken = "token-b"
        let secondRestore = Task { await service.restoreSession() }
        while !startedTokens.contains("token-b") {
            await Task.yield()
        }

        continuations["token-a"]?.resume(returning: ItchUser(
            id: 904,
            username: "older-restore",
            displayName: nil,
            coverUrl: nil,
            url: nil
        ))
        continuations["token-a"] = nil
        await firstRestore.value

        XCTAssertNil(service.user, "The superseded restore must not activate its account.")

        continuations["token-b"]?.resume(returning: ItchUser(
            id: 905,
            username: "newer-restore",
            displayName: nil,
            coverUrl: nil,
            url: nil
        ))
        continuations["token-b"] = nil
        await secondRestore.value

        XCTAssertEqual(service.user?.id, 905)
        XCTAssertEqual(service.accountSession.identity?.id, "itch:905")
        XCTAssertEqual(storedToken, "token-b")
    }


    @MainActor
    func testStaleSignOutRevocationFailureDoesNotOverwriteRestoredSession() async throws {
        var storedToken: String? = "old-token"
        var didStartRevocation = false
        var revocationContinuation: CheckedContinuation<Void, Error>?

        let service = ItchAuthService(
            readAccessToken: { storedToken },
            deleteAccessToken: { storedToken = nil },
            revokeAccessToken: { _ in
                try await withCheckedThrowingContinuation { continuation in
                    didStartRevocation = true
                    revocationContinuation = continuation
                }
            },
            fetchProfile: { _ in
                ItchUser(
                    id: 906,
                    username: "new-session",
                    displayName: nil,
                    coverUrl: nil,
                    url: nil
                )
            }
        )

        let signOutTask = Task { await service.signOut() }
        while !didStartRevocation {
            await Task.yield()
        }

        // Simulate a newer authenticated session becoming authoritative while
        // the old token's remote revocation is still suspended.
        storedToken = "new-token"
        await service.restoreSession()
        XCTAssertEqual(service.accountSession.identity?.id, "itch:906")

        revocationContinuation?.resume(throwing: NSError(
            domain: "ItchAuthServiceSignOutTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Old token revoke failed"]
        ))
        revocationContinuation = nil
        await signOutTask.value

        XCTAssertEqual(service.user?.id, 906)
        XCTAssertEqual(service.accountSession.identity?.id, "itch:906")
        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(storedToken, "new-token")
    }

    @MainActor
    func testSignOutCancelsPendingOAuthResultBeforeTokenExchange() async throws {
        var storedToken: String?
        var didStartAuthorization = false
        var authorizationContinuation: CheckedContinuation<URL, Error>?
        var generatedCallbackURL: URL?
        var didExchangeCode = false
        var didFetchProfile = false

        let service = ItchAuthService(
            readAccessToken: { storedToken },
            deleteAccessToken: { storedToken = nil },
            revokeAccessToken: { _ in },
            fetchProfile: { _ in
                didFetchProfile = true
                return ItchUser(
                    id: 907,
                    username: "must-not-activate",
                    displayName: nil,
                    coverUrl: nil,
                    url: nil
                )
            },
            authorizeURL: { authorizationURL in
                let state = URLComponents(
                    url: authorizationURL,
                    resolvingAgainstBaseURL: false
                )?.queryItems?.first(where: { $0.name == "state" })?.value
                var callback = URLComponents()
                callback.scheme = ItchOAuthConfig.callbackScheme
                callback.host = "oauth"
                callback.queryItems = [
                    URLQueryItem(name: "state", value: state),
                    URLQueryItem(name: "code", value: "authorization-code")
                ]
                generatedCallbackURL = try XCTUnwrap(callback.url)
                return try await withCheckedThrowingContinuation { continuation in
                    didStartAuthorization = true
                    authorizationContinuation = continuation
                }
            },
            exchangeAuthorizationCode: { _, _ in
                didExchangeCode = true
                return "must-not-be-saved"
            }
        )

        let signInTask = Task { await service.signIn() }
        while !didStartAuthorization {
            await Task.yield()
        }

        await service.signOut()
        XCTAssertFalse(service.isLoading)

        authorizationContinuation?.resume(returning: try XCTUnwrap(generatedCallbackURL))
        authorizationContinuation = nil
        await signInTask.value

        XCTAssertFalse(didExchangeCode, "A stale OAuth callback must not exchange its authorization code.")
        XCTAssertFalse(didFetchProfile, "A stale OAuth callback must not fetch or activate an account.")
        XCTAssertNil(storedToken)
        XCTAssertNil(service.user)
        XCTAssertNil(service.accountSession.identity)
        XCTAssertFalse(service.isLoading)
    }

    @MainActor
    func testRestoreSessionCannotReactivateAccountWhileRemovalReservationIsHeld() async {
        var storedToken: String? = "account-being-removed-token"
        let service = ItchAuthService(
            readAccessToken: { storedToken },
            deleteAccessToken: { storedToken = nil },
            revokeAccessToken: { _ in },
            fetchProfile: { _ in
                ItchUser(
                    id: 910,
                    username: "removing-account",
                    displayName: nil,
                    coverUrl: nil,
                    url: nil
                )
            }
        )
        XCTAssertTrue(service.accountSession.beginAccountRemoval("itch:910"))

        await service.restoreSession()

        XCTAssertNil(service.user)
        XCTAssertNil(service.accountSession.identity)
        XCTAssertNil(storedToken, "A credential for an account being removed must not restore it after the removal lease ends.")
        XCTAssertNotNil(service.errorMessage)
        service.accountSession.endAccountRemoval("itch:910")
    }

    @MainActor
    func testSignInCannotActivateAccountWhileRemovalReservationIsHeld() async throws {
        var storedToken: String?
        let service = ItchAuthService(
            readAccessToken: { storedToken },
            deleteAccessToken: { storedToken = nil },
            revokeAccessToken: { _ in },
            fetchProfile: { _ in
                ItchUser(
                    id: 911,
                    username: "removing-account",
                    displayName: nil,
                    coverUrl: nil,
                    url: nil
                )
            },
            authorizeURL: { authorizationURL in
                let state = URLComponents(
                    url: authorizationURL,
                    resolvingAgainstBaseURL: false
                )?.queryItems?.first(where: { $0.name == "state" })?.value
                var callback = URLComponents()
                callback.scheme = ItchOAuthConfig.callbackScheme
                callback.host = "oauth"
                callback.queryItems = [
                    URLQueryItem(name: "state", value: state),
                    URLQueryItem(name: "code", value: "authorization-code")
                ]
                return try XCTUnwrap(callback.url)
            },
            exchangeAuthorizationCode: { _, _ in "new-account-token" }
        )
        XCTAssertTrue(service.accountSession.beginAccountRemoval("itch:911"))

        await service.signIn()

        XCTAssertNil(service.user)
        XCTAssertNil(service.accountSession.identity)
        XCTAssertNil(storedToken)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertFalse(service.isLoading)
        service.accountSession.endAccountRemoval("itch:911")
    }

}

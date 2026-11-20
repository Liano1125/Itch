
import SwiftUI
import AuthenticationServices
import UIKit

@MainActor
final class ItchAuthService: NSObject, ObservableObject,
    ASWebAuthenticationPresentationContextProviding {

    @Published private(set) var user: ItchUser?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let readAccessToken: @MainActor () -> String?
    private let deleteAccessToken: @MainActor () -> Void
    private let revokeAccessToken: @MainActor (String) async throws -> Void
    private let fetchProfile: @MainActor (String) async throws -> ItchUser
    private let authorizeURL: (@MainActor (URL) async throws -> URL)?
    private let exchangeAuthorizationCode: (@MainActor (String, String) async throws -> String)?
    private var authOperationGeneration: UInt64 = 0

    init(
        readAccessToken: @escaping @MainActor () -> String? = {
            KeychainStore.read("access_token")
        },
        deleteAccessToken: @escaping @MainActor () -> Void = {
            KeychainStore.delete("access_token")
        },
        revokeAccessToken: @escaping @MainActor (String) async throws -> Void = {
            try await ItchAuthService.revokeAccessTokenOnServer($0)
        },
        fetchProfile: @escaping @MainActor (String) async throws -> ItchUser = {
            try await ItchAPI().fetchProfile(token: $0)
        },
        authorizeURL: (@MainActor (URL) async throws -> URL)? = nil,
        exchangeAuthorizationCode: (@MainActor (String, String) async throws -> String)? = nil
    ) {
        self.readAccessToken = readAccessToken
        self.deleteAccessToken = deleteAccessToken
        self.revokeAccessToken = revokeAccessToken
        self.fetchProfile = fetchProfile
        self.authorizeURL = authorizeURL
        self.exchangeAuthorizationCode = exchangeAuthorizationCode
        super.init()
    }

    /// Account identity and generation shared with account-scoped request owners.
    let accountSession = ItchAccountSession()

    private var webSession: ASWebAuthenticationSession?

    var isSignedIn: Bool {
        user != nil
    }

    func restoreSession() async {
        authOperationGeneration &+= 1
        let operation = authOperationGeneration

        guard let token = readAccessToken() else {
            guard operation == authOperationGeneration else { return }
            user = nil
            accountSession.activate(nil)
            return
        }

        do {
            let restoredUser = try await fetchProfile(token)
            // A sign-out, newer restore, or sign-in may have superseded this
            // request while the profile lookup was suspended.
            guard operation == authOperationGeneration,
                  readAccessToken() == token else { return }
            user = restoredUser
            accountSession.activate(ItchAccountIdentity(user: restoredUser))
        } catch {
            // Never let a stale restore delete a newer login's credential.
            guard operation == authOperationGeneration,
                  readAccessToken() == token else { return }
            deleteAccessToken()
            user = nil
            accountSession.activate(nil)
            errorMessage = error.localizedDescription
        }
    }

    func signIn() async {
        guard !isLoading else { return }

        authOperationGeneration &+= 1
        let operation = authOperationGeneration
        isLoading = true
        errorMessage = nil
        defer {
            // An older sign-in must not clear the loading state of a newer one.
            if operation == authOperationGeneration {
                isLoading = false
            }
        }

        do {
            let verifier = PKCE.makeVerifier()
            let challenge = PKCE.makeChallenge(from: verifier)
            let state = UUID().uuidString

            var components = URLComponents(
                string: "https://itch.io/user/oauth"
            )!

            components.queryItems = [
                URLQueryItem(
                    name: "client_id",
                    value: ItchOAuthConfig.clientID
                ),
                URLQueryItem(
                    name: "scope",
                    value: ItchOAuthConfig.scopes
                ),
                URLQueryItem(
                    name: "redirect_uri",
                    value: ItchOAuthConfig.redirectURI
                ),
                URLQueryItem(
                    name: "response_type",
                    value: "code"
                ),
                URLQueryItem(
                    name: "code_challenge",
                    value: challenge
                ),
                URLQueryItem(
                    name: "code_challenge_method",
                    value: "S256"
                ),
                URLQueryItem(
                    name: "state",
                    value: state
                )
            ]

            guard let authorizationURL = components.url else {
                throw ItchAPIError.invalidResponse
            }

            let callbackURL: URL
            if let authorizeURL {
                callbackURL = try await authorizeURL(authorizationURL)
            } else {
                callbackURL = try await authorize(url: authorizationURL)
            }
            guard operation == authOperationGeneration else { return }

            guard let callback = URLComponents(
                url: callbackURL,
                resolvingAgainstBaseURL: false
            ) else {
                throw ItchAPIError.invalidResponse
            }

            let items = callback.queryItems ?? []

            let returnedState = items.first {
                $0.name == "state"
            }?.value

            guard returnedState == state else {
                throw ItchAPIError.httpError(
                    400,
                    "OAuth state 验证失败"
                )
            }

            if let oauthError = items.first(where: {
                $0.name == "error"
            })?.value {
                throw ItchAPIError.httpError(
                    400,
                    "用户未完成授权：\(oauthError)"
                )
            }

            guard let code = items.first(where: {
                $0.name == "code"
            })?.value else {
                throw ItchAPIError.invalidResponse
            }

            let token: String
            if let exchangeAuthorizationCode {
                token = try await exchangeAuthorizationCode(code, verifier)
            } else {
                token = try await exchangeCode(code, verifier: verifier)
            }
            guard operation == authOperationGeneration else { return }

            // Validate the new credential before replacing the persisted session.
            let authenticatedUser = try await fetchProfile(token)

            guard operation == authOperationGeneration else { return }
            try KeychainStore.save(
                token,
                for: "access_token"
            )

            user = authenticatedUser
            accountSession.activate(ItchAccountIdentity(user: authenticatedUser))

        } catch {
            guard operation == authOperationGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func authorize(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: ItchOAuthConfig.callbackScheme
            ) { callbackURL, error in

                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(
                        throwing: ItchAPIError.invalidResponse
                    )
                }
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false

            self.webSession = session

            if !session.start() {
                self.webSession = nil
                continuation.resume(
                    throwing: ItchAPIError.invalidResponse
                )
            }
        }
    }

    private func exchangeCode(
        _ code: String,
        verifier: String
    ) async throws -> String {

        let url = URL(
            string: "https://api.itch.io/oauth/token"
        )!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(
                name: "grant_type",
                value: "authorization_code"
            ),
            URLQueryItem(
                name: "code",
                value: code
            ),
            URLQueryItem(
                name: "code_verifier",
                value: verifier
            ),
            URLQueryItem(
                name: "redirect_uri",
                value: ItchOAuthConfig.redirectURI
            ),
            URLQueryItem(
                name: "client_id",
                value: ItchOAuthConfig.clientID
            )
        ]

        request.httpBody = body.percentEncodedQuery?.data(
            using: .utf8
        )

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let message = String(
                data: data,
                encoding: .utf8
            ) ?? "Token 交换失败"

            throw ItchAPIError.httpError(
                (response as? HTTPURLResponse)?.statusCode ?? -1,
                message
            )
        }

        let tokenResponse = try JSONDecoder.itchDecoder.decode(
            ItchTokenResponse.self,
            from: data
        )

        return tokenResponse.accessToken
    }

    func signOut() async {
        // Invalidate local authority before any network suspension. Every
        // account-owned request captured under the old generation is now stale.
        authOperationGeneration &+= 1
        let operation = authOperationGeneration
        isLoading = false
        // Close any pending browser authorization immediately. Its callback
        // will be treated as stale by the generation checks in signIn().
        webSession?.cancel()
        webSession = nil
        let token = readAccessToken()
        user = nil
        accountSession.activate(nil)
        deleteAccessToken()

        guard let token else { return }

        do {
            try await revokeAccessToken(token)
        } catch {
            // A later sign-in/restore owns the UI now; don't surface an old
            // sign-out failure over the newer authenticated session.
            guard operation == authOperationGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    static func revokeAccessTokenOnServer(_ token: String) async throws {
        var request = URLRequest(
            url: URL(string: "https://api.itch.io/oauth/revoke")!
        )

        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(
                name: "client_id",
                value: ItchOAuthConfig.clientID
            )
        ]

        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw ItchAPIError.httpError(http.statusCode, "撤销授权失败")
        }
    }

    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {

        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
            ?? ASPresentationAnchor()
    }
}

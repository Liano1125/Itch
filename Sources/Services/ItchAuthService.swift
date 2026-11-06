
import SwiftUI
import AuthenticationServices
import UIKit

@MainActor
final class ItchAuthService: NSObject, ObservableObject,
    ASWebAuthenticationPresentationContextProviding {

    @Published private(set) var user: ItchUser?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let api = ItchAPI()

    private var webSession: ASWebAuthenticationSession?

    var isSignedIn: Bool {
        user != nil
    }

    func restoreSession() async {
        guard let token = KeychainStore.read("access_token") else {
            return
        }

        do {
            user = try await api.fetchProfile(token: token)
        } catch {
            KeychainStore.delete("access_token")
            errorMessage = error.localizedDescription
        }
    }

    func signIn() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

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

            let callbackURL = try await authorize(
                url: authorizationURL
            )

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

            let token = try await exchangeCode(
                code,
                verifier: verifier
            )

            try KeychainStore.save(
                token,
                for: "access_token"
            )

            user = try await api.fetchProfile(token: token)

        } catch {
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
        guard let token = KeychainStore.read("access_token") else {
            user = nil
            return
        }

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

        request.httpBody = body.percentEncodedQuery?.data(
            using: .utf8
        )

        do {
            let (_, response) = try await URLSession.shared.data(
                for: request
            )

            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw ItchAPIError.httpError(
                    http.statusCode,
                    "撤销授权失败"
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        KeychainStore.delete("access_token")
        user = nil
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

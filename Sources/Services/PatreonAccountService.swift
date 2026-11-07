import Foundation
import Combine
import AuthenticationServices
import UIKit

struct PatreonAccount: Codable {
    let userID: String
    let name: String?
    let imageURL: URL?
    let profileURL: URL?
}

@MainActor
final class PatreonAccountService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PatreonAccountService()
    private let baseURL = URL(string: "https://itchpocket-patreon-api.kerfa405.workers.dev")!
    @Published private(set) var account: PatreonAccount?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private var session: ASWebAuthenticationSession?

    private override init() { super.init() }

    func restore() async {
        guard let token = KeychainStore.read("patreon_session_token") else { return }
        do {
            account = try await requestAccount(path: "/account/status", token: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connect() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let callback = try await authorize()
            guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  let handoff = components.queryItems?.first(where: { $0.name == "handoff" })?.value,
                  !handoff.isEmpty else {
                throw ServiceError.invalidResponse
            }
            struct RedeemRequest: Encodable { let handoff: String }
            struct RedeemResponse: Decodable { let sessionToken: String; let account: PatreonAccount }
            var request = URLRequest(url: baseURL.appendingPathComponent("oauth/redeem"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(RedeemRequest(handoff: handoff))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ServiceError.server("兑换授权凭证失败")
            }
            let result = try JSONDecoder().decode(RedeemResponse.self, from: data)
            try KeychainStore.save(result.sessionToken, for: "patreon_session_token")
            account = result.account
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() async {
        guard let token = KeychainStore.read("patreon_session_token") else {
            account = nil
            return
        }
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("account/disconnect"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ServiceError.server("断开 Patreon 连接失败")
            }
            KeychainStore.delete("patreon_session_token")
            account = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestAccount(path: String, token: String) async throws -> PatreonAccount {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.server("读取 Patreon 账户状态失败")
        }
        struct StatusResponse: Decodable { let account: PatreonAccount }
        return try JSONDecoder().decode(StatusResponse.self, from: data).account
    }

    private func authorize() async throws -> URL {
        let url = baseURL.appendingPathComponent("oauth/start")
        return try await withCheckedThrowingContinuation { continuation in
            let authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: "itchpocket") { callback, error in
                if let error { continuation.resume(throwing: error) }
                else if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: ServiceError.invalidResponse) }
            }
            authSession.presentationContextProvider = self
            authSession.prefersEphemeralWebBrowserSession = false
            session = authSession
            if !authSession.start() {
                session = nil
                continuation.resume(throwing: ServiceError.cannotStart)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private enum ServiceError: LocalizedError {
        case invalidResponse, cannotStart
        case server(String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Patreon 返回的数据无效"
            case .cannotStart: return "无法启动 Patreon 授权页面"
            case .server(let message): return message
            }
        }
    }
}

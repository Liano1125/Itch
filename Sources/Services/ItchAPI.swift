
import Foundation

enum ItchAPIError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case missingToken

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回的数据无法识别"
        case let .httpError(code, message):
            return "请求失败（HTTP \(code)）：\(message)"
        case .missingToken:
            return "尚未登录 itch.io"
        }
    }
}

final class ItchAPI {
    private let baseURL = URL(string: "https://api.itch.io")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchProfile(token: String) async throws -> ItchUser {
        let url = baseURL.appendingPathComponent("profile")
        let data = try await request(url: url, token: token)

        let response = try JSONDecoder.itchDecoder.decode(
            ItchProfileResponse.self,
            from: data
        )

        return response.user
    }

    func fetchCredentials(token: String) async throws -> ItchCredentialsInfo {
        let url = baseURL.appendingPathComponent("credentials/info")
        let data = try await request(url: url, token: token)

        return try JSONDecoder.itchDecoder.decode(
            ItchCredentialsInfo.self,
            from: data
        )
    }

    private func request(url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ItchAPIError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "未知错误"
            throw ItchAPIError.httpError(http.statusCode, message)
        }

        return data
    }
}

extension JSONDecoder {
    static var itchDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}


import Foundation
import CryptoKit
import Security

enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)

        let status = SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        )

        guard status == errSecSuccess else {
            fatalError("无法生成安全随机数")
        }

        return Data(bytes).base64URLString()
    }

    static func makeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(
            data: Data(verifier.utf8)
        )

        return Data(digest).base64URLString()
    }
}

private extension Data {
    func base64URLString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

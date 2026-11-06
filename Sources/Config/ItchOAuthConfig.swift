
import Foundation

enum ItchOAuthConfig {
    static let clientID = "bc1227e819e68a558428e01d3ebfe01b"

    static let redirectURI = "itchpocket://oauth/callback"

    static let scopes = [
        "profile:me",
        "profile:owned",
        "game:view:uploads"
    ].joined(separator: " ")
}

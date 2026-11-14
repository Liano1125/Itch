import Foundation

enum AppStateScopeKind: String, Codable, Equatable {
    case device
    case appGlobal
    case itchAccount
    case patreonAccount
    case legacyUnclassified
}

enum AppStateScopeConfidence: String, Codable, Equatable {
    case established
    case provisional
    case unknown
}

struct AppStateKeyClassification: Equatable {
    let key: String
    let family: String
    let scope: AppStateScopeKind
    let confidence: AppStateScopeConfidence

    /// Even a known account-scoped key does not prove which account owns a
    /// historical V3 row. Migration must not bind it to the active session.
    var requiresOwnershipReview: Bool {
        scope == .itchAccount || scope == .patreonAccount || scope == .legacyUnclassified
    }
}

/// Source-reviewed key registry for V3 AppState migration planning.
///
/// This registry classifies key semantics only. It does not read or mutate
/// persisted rows, derive account ownership, or authorize migration.
enum AppStateScopeRegistry {
    static let registryVersion = 1

    static func classify(_ key: String) -> AppStateKeyClassification {
        switch key {
        case "devlogSync.lastDate":
            return make(key, family: "devlogSync.lastDate", scope: .itchAccount, confidence: .provisional)
        case "devlogSync.lastMessage":
            return make(key, family: "devlogSync.lastMessage", scope: .itchAccount, confidence: .provisional)
        case "devlogSync.lastResults":
            return make(key, family: "devlogSync.lastResults", scope: .itchAccount, confidence: .provisional)
        case "itchPocket.devlogAutoSync.lastAttempt":
            return make(key, family: "devlogAutoSync.lastAttempt", scope: .itchAccount, confidence: .provisional)
        case "itchPocket.sparkLastSyncAt.v2":
            return make(key, family: "sparkLastSyncAt", scope: .device, confidence: .established)
        case "itchPocket.avatarResolver.version":
            return make(key, family: "avatarResolver.version", scope: .appGlobal, confidence: .established)
        default:
            break
        }

        let prefixes: [(String, String, AppStateScopeKind, AppStateScopeConfidence)] = [
            ("gameDetail.fetchStatus.", "gameDetail.fetchStatus", .appGlobal, .established),
            ("gameDetail.lastSuccessfulFetch.", "gameDetail.lastSuccessfulFetch", .appGlobal, .established),
            ("detailPrefetch.lastSuccess.", "detailPrefetch.lastSuccess.legacyAlias", .appGlobal, .provisional),
            ("avatarFailure.", "avatarFailure", .appGlobal, .established)
        ]

        for (prefix, family, scope, confidence) in prefixes
        where key.hasPrefix(prefix) && key.count > prefix.count {
            return make(key, family: family, scope: scope, confidence: confidence)
        }

        return make(
            key,
            family: "unknown",
            scope: .legacyUnclassified,
            confidence: .unknown
        )
    }

    private static func make(
        _ key: String,
        family: String,
        scope: AppStateScopeKind,
        confidence: AppStateScopeConfidence
    ) -> AppStateKeyClassification {
        AppStateKeyClassification(
            key: key,
            family: family,
            scope: scope,
            confidence: confidence
        )
    }
}

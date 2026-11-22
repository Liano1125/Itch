import Foundation

/// Enforces the V4 product decision that Patreon must be connected again
/// after the fresh-store cutover. The old Keychain session is discarded once;
/// subsequent V4 launches preserve credentials created by a new login.
enum V4PatreonReauthenticationGate {
    static let completionKey = "v4_patreon_reauthentication_reset_completed"
    private static let completedValue = "completed"

    static func resetLegacySessionIfNeeded() throws {
        try resetIfNeeded(
            readMarker: { KeychainStore.read(completionKey) },
            deleteLegacyToken: { try KeychainStore.deleteChecked("patreon_session_token") },
            saveMarker: { value, key in
                try KeychainStore.save(value, for: key)
            }
        )
    }

    static func resetIfNeeded(
        readMarker: () -> String?,
        deleteLegacyToken: () throws -> Void,
        saveMarker: (String, String) throws -> Void
    ) throws {
        guard readMarker() != completedValue else { return }
        // Never persist the completion marker unless the old credential is
        // confirmed absent; otherwise a failed delete could preserve a session
        // that the user explicitly chose not to migrate.
        try deleteLegacyToken()
        try saveMarker(completedValue, completionKey)
    }
}

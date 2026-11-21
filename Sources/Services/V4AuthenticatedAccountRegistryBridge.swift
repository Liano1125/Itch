import Foundation
import SwiftData

/// Bridges an already-authenticated in-memory itch session to the V4 account
/// registry. Construct this only with a ModelContext backed by ItchPocketSchemaV4;
/// the production V3 container deliberately does not contain DBAccount.
@MainActor
final class V4AuthenticatedAccountRegistryBridge {
    enum BridgeError: LocalizedError, Equatable {
        case signedOut
        case staleSession

        var errorDescription: String? {
            switch self {
            case .signedOut:
                return "An authenticated itch account is required."
            case .staleSession:
                return "The authentication session changed before the account could be recorded."
            }
        }
    }

    private let session: ItchAccountSession
    private let repository: V4AccountRegistryRepository

    init(session: ItchAccountSession, context: ModelContext) {
        self.session = session
        self.repository = V4AccountRegistryRepository(context: context)
    }

    /// Persist only the exact identity captured for this request generation.
    /// A sign-out or account switch invalidates the context and blocks the write.
    @discardableResult
    func recordAuthenticatedSession(
        _ requestContext: ItchAccountRequestContext,
        at date: Date = .now
    ) throws -> DBAccount {
        guard session.isCurrent(requestContext),
              let identity = session.identity,
              identity.id == requestContext.accountID else {
            throw BridgeError.staleSession
        }
        return try repository.recordAuthenticatedIdentity(identity, at: date)
    }
}

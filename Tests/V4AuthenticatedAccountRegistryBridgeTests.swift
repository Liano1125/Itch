import XCTest
import SwiftData
@testable import itchPocket

final class V4AuthenticatedAccountRegistryBridgeTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([DBAccount.self])
        let configuration = ModelConfiguration(
            "itchPocket-v4-auth-bridge-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    func testPersistsOnlyCurrentAuthenticatedIdentity() throws {
        let session = ItchAccountSession()
        let identity = ItchAccountIdentity(
            itchUserID: 801,
            username: "bridge-user"
        )
        session.activate(identity)
        let request = try XCTUnwrap(session.captureRequestContext())
        let context = try makeContainer().mainContext
        let bridge = V4AuthenticatedAccountRegistryBridge(
            session: session,
            context: context
        )

        let account = try bridge.recordAuthenticatedSession(
            request,
            at: Date(timeIntervalSince1970: 1_710_000_000)
        )

        XCTAssertEqual(account.id, "itch:801")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccount>()), 1)
    }

    @MainActor
    func testRejectsContextAfterSignOutWithoutWriting() throws {
        let session = ItchAccountSession()
        session.activate(ItchAccountIdentity(itchUserID: 802, username: "user-a"))
        let request = try XCTUnwrap(session.captureRequestContext())
        session.activate(nil)

        let context = try makeContainer().mainContext
        let bridge = V4AuthenticatedAccountRegistryBridge(session: session, context: context)

        XCTAssertThrowsError(try bridge.recordAuthenticatedSession(request))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccount>()), 0)
    }

    @MainActor
    func testRejectsOldAccountContextAfterAccountSwitch() throws {
        let session = ItchAccountSession()
        session.activate(ItchAccountIdentity(itchUserID: 803, username: "user-a"))
        let requestA = try XCTUnwrap(session.captureRequestContext())
        session.activate(ItchAccountIdentity(itchUserID: 804, username: "user-b"))

        let context = try makeContainer().mainContext
        let bridge = V4AuthenticatedAccountRegistryBridge(session: session, context: context)

        XCTAssertThrowsError(try bridge.recordAuthenticatedSession(requestA))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccount>()), 0)
    }

    @MainActor
    func testRejectsUnauthenticatedSession() throws {
        let session = ItchAccountSession()
        let context = try makeContainer().mainContext
        let bridge = V4AuthenticatedAccountRegistryBridge(session: session, context: context)

        XCTAssertThrowsError(try bridge.recordAuthenticatedSession(
            ItchAccountRequestContext(accountID: "itch:805", generation: 0)
        ))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccount>()), 0)
    }
}

import XCTest
@testable import itchPocket

final class ItchAccountIdentityTests: XCTestCase {
    func testStableIdentityUsesNumericItchUserIDNotUsername() {
        let first = ItchAccountIdentity(itchUserID: 42, username: "old-name")
        let renamed = ItchAccountIdentity(
            itchUserID: 42,
            username: "new-name",
            displayName: "New Name"
        )

        XCTAssertEqual(first.id, "itch:42")
        XCTAssertEqual(renamed.id, first.id)
    }

    func testDifferentNumericUserIDsNeverShareIdentity() {
        let first = ItchAccountIdentity(itchUserID: 42, username: "same-name")
        let second = ItchAccountIdentity(itchUserID: 43, username: "same-name")

        XCTAssertNotEqual(first.id, second.id)
    }

    @MainActor
    func testAccountSwitchInvalidatesEarlierRequestGeneration() {
        let session = ItchAccountSession()
        session.activate(ItchAccountIdentity(itchUserID: 1, username: "account-a"))
        let requestFromA = session.requestGeneration()

        session.activate(ItchAccountIdentity(itchUserID: 2, username: "account-b"))

        XCTAssertFalse(session.isCurrent(requestFromA))
        XCTAssertTrue(session.isCurrent(session.requestGeneration()))
    }

    @MainActor
    func testRefreshingSameAccountDoesNotInvalidateInFlightRequests() {
        let session = ItchAccountSession()
        session.activate(ItchAccountIdentity(itchUserID: 1, username: "before"))
        let request = session.requestGeneration()

        session.activate(ItchAccountIdentity(itchUserID: 1, username: "after"))

        XCTAssertTrue(session.isCurrent(request))
        XCTAssertEqual(session.identity?.username, "after")
    }

    @MainActor
    func testSigningOutInvalidatesInFlightRequests() {
        let session = ItchAccountSession()
        session.activate(ItchAccountIdentity(itchUserID: 1, username: "account-a"))
        let request = session.requestGeneration()

        session.activate(nil)

        XCTAssertNil(session.identity)
        XCTAssertFalse(session.isCurrent(request))
    }
}

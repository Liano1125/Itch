import XCTest
import SwiftData
@testable import itchPocket

final class V4AuthenticationLifecycleCoordinatorTests: XCTestCase {
    @MainActor
    private func makeSupportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v4-auth-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    func testRegistersAuthenticatedSessionAndReusesInjectedRuntime() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let session = ItchAccountSession()
        var factoryCalls = 0
        let coordinator = V4AuthenticationLifecycleCoordinator { injectedSession in
            factoryCalls += 1
            return try V4AppDependencies.open(in: supportDirectory, session: injectedSession)
        }

        session.activate(ItchAccountIdentity(itchUserID: 9401, username: "lifecycle-user"))
        coordinator.synchronizeAuthenticatedSession(using: session)

        XCTAssertEqual(coordinator.registeredAccountID, "itch:9401")
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(factoryCalls, 1)
        let libraryStore = try XCTUnwrap(coordinator.personalLibraryStore)

        coordinator.synchronizeAuthenticatedSession(using: session)
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(coordinator.personalLibraryStore === libraryStore)
    }

    @MainActor
    func testAccountSwitchRegistersNewIdentityWithoutDeletingPreviousAccount() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let session = ItchAccountSession()
        var runtime: V4AppDependencies?
        let coordinator = V4AuthenticationLifecycleCoordinator { injectedSession in
            let opened = try V4AppDependencies.open(in: supportDirectory, session: injectedSession)
            runtime = opened
            return opened
        }

        session.activate(ItchAccountIdentity(itchUserID: 9402, username: "account-a"))
        coordinator.synchronizeAuthenticatedSession(using: session)
        XCTAssertEqual(coordinator.registeredAccountID, "itch:9402")
        let firstLibraryStore = try XCTUnwrap(coordinator.personalLibraryStore)

        session.activate(ItchAccountIdentity(itchUserID: 9403, username: "account-b"))
        coordinator.synchronizeAuthenticatedSession(using: session)

        XCTAssertEqual(coordinator.registeredAccountID, "itch:9403")
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertNotNil(coordinator.personalLibraryStore)
        XCTAssertFalse(coordinator.personalLibraryStore === firstLibraryStore)
        XCTAssertEqual(try runtime?.registeredAccounts().map(\\.id).sorted(), ["itch:9402", "itch:9403"])
    }

    @MainActor
    func testSignOutClearsActiveProjectionButPreservesRegisteredAccount() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let session = ItchAccountSession()
        var runtime: V4AppDependencies?
        let coordinator = V4AuthenticationLifecycleCoordinator { injectedSession in
            let opened = try V4AppDependencies.open(in: supportDirectory, session: injectedSession)
            runtime = opened
            return opened
        }

        session.activate(ItchAccountIdentity(itchUserID: 9404, username: "signed-out-user"))
        coordinator.synchronizeAuthenticatedSession(using: session)
        XCTAssertNotNil(coordinator.personalLibraryStore)
        session.activate(nil)
        coordinator.synchronizeAuthenticatedSession(using: session)

        XCTAssertNil(coordinator.registeredAccountID)
        XCTAssertNil(coordinator.personalLibraryStore)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(try runtime?.registeredAccounts().map(\\.id), ["itch:9404"])
    }

    @MainActor
    func testFactoryFailureIsReportedAndCanBeRetried() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let session = ItchAccountSession()
        var shouldFail = true
        let coordinator = V4AuthenticationLifecycleCoordinator { injectedSession in
            if shouldFail { throw TestError.openFailed }
            return try V4AppDependencies.open(in: supportDirectory, session: injectedSession)
        }

        session.activate(ItchAccountIdentity(itchUserID: 9405, username: "retry-user"))
        coordinator.synchronizeAuthenticatedSession(using: session)
        XCTAssertNil(coordinator.registeredAccountID)
        XCTAssertNil(coordinator.personalLibraryStore)
        XCTAssertNotNil(coordinator.errorMessage)

        shouldFail = false
        coordinator.synchronizeAuthenticatedSession(using: session)
        XCTAssertEqual(coordinator.registeredAccountID, "itch:9405")
        XCTAssertNotNil(coordinator.personalLibraryStore)
        XCTAssertNil(coordinator.errorMessage)
    }

    private enum TestError: LocalizedError {
        case openFailed

        var errorDescription: String? { "V4 runtime unavailable" }
    }
}

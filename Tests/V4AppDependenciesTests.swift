import XCTest
import SwiftData
@testable import itchPocket

final class V4AppDependenciesTests: XCTestCase {
    @MainActor
    private func makeSupportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v4-dependencies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @MainActor
    func testOpenCreatesAnEmptyV4StoreWithoutImportingLegacyData() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let dependencies = try V4AppDependencies.open(in: supportDirectory)
        let accounts = try dependencies.registeredAccounts()

        XCTAssertTrue(accounts.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: supportDirectory
                    .appendingPathComponent(V4FreshStoreBootstrap.directoryName, isDirectory: true)
                    .appendingPathComponent(V4FreshStoreBootstrap.storeFileName)
                    .path
            )
        )
    }

    @MainActor
    func testProductionActivationPreparesPatreonBeforeReturningDependencies() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        var preparationCount = 0

        let dependencies = try V4AppDependencies.openForProductionActivation(
            in: supportDirectory,
            prepareForActivation: { openedDependencies in
                preparationCount += 1
                XCTAssertTrue(try openedDependencies.registeredAccounts().isEmpty)
            }
        )

        XCTAssertEqual(preparationCount, 1)
        XCTAssertTrue(try dependencies.registeredAccounts().isEmpty)
    }

    @MainActor
    func testProductionActivationFailsClosedWhenPatreonPreparationFails() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        XCTAssertThrowsError(
            try V4AppDependencies.openForProductionActivation(
                in: supportDirectory,
                prepareForActivation: { _ in
                    throw TestActivationError.patreonResetFailed
                }
            )
        )
    }

    @MainActor
    func testOpenKeepsTheInjectedSessionInstance() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let session = ItchAccountSession()
        let identity = ItchAccountIdentity(itchUserID: 8101, username: "injected-session")
        session.activate(identity)

        let dependencies = try V4AppDependencies.open(
            in: supportDirectory,
            session: session
        )

        XCTAssertTrue(dependencies.session === session)
        XCTAssertEqual(dependencies.session.identity?.id, identity.id)
    }

    @MainActor
    func testAuthenticatedSessionIsPersistedOnlyForCurrentSessionContext() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let session = ItchAccountSession()
        let dependencies = try V4AppDependencies.open(
            in: supportDirectory,
            session: session
        )
        let identity = ItchAccountIdentity(itchUserID: 8102, username: "current-account")
        session.activate(identity)
        let currentContext = try XCTUnwrap(session.captureRequestContext())

        let account = try dependencies.recordAuthenticatedSession(
            currentContext,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(account.id, identity.id)
        XCTAssertEqual(try dependencies.registeredAccounts().map(\.id), [identity.id])

        let staleContext = try XCTUnwrap(session.captureRequestContext())
        session.activate(ItchAccountIdentity(itchUserID: 8103, username: "different-account"))
        XCTAssertThrowsError(try dependencies.recordAuthenticatedSession(staleContext))
        XCTAssertEqual(try dependencies.registeredAccounts().map(\.id), [identity.id])
    }

    @MainActor
    func testAccountRepositoriesRequireARegisteredAccount() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let session = ItchAccountSession()
        let dependencies = try V4AppDependencies.open(
            in: supportDirectory,
            session: session
        )

        XCTAssertThrowsError(try dependencies.libraryRepository(for: "itch:8104"))
        XCTAssertThrowsError(try dependencies.calendarRepository(for: "itch:8104"))
        XCTAssertThrowsError(try dependencies.updateWatchRepository(for: "itch:8104"))

        session.activate(ItchAccountIdentity(itchUserID: 8104, username: "registered-account"))
        let requestContext = try XCTUnwrap(session.captureRequestContext())
        _ = try dependencies.recordAuthenticatedSession(requestContext)

        XCTAssertNoThrow(try dependencies.libraryRepository())
        XCTAssertNoThrow(try dependencies.calendarRepository())
        XCTAssertNoThrow(try dependencies.updateWatchRepository())
    }

    @MainActor
    func testDependencyGraphCreatesAllV4StoresAgainstTheSameSession() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let session = ItchAccountSession()
        let dependencies = try V4AppDependencies.open(
            in: supportDirectory,
            session: session
        )

        let library = dependencies.makePersonalLibraryStore()
        let calendar = dependencies.makeCalendarStore()
        let updateWatch = dependencies.makeUpdateWatchStore()

        XCTAssertThrowsError(try library.reload())
        XCTAssertThrowsError(try calendar.reload())
        XCTAssertThrowsError(try updateWatch.reload())

        session.activate(ItchAccountIdentity(itchUserID: 8105, username: "store-graph"))
        let requestContext = try XCTUnwrap(session.captureRequestContext())
        _ = try dependencies.recordAuthenticatedSession(requestContext)

        XCTAssertNoThrow(try library.reload())
        XCTAssertNoThrow(try calendar.reload())
        XCTAssertNoThrow(try updateWatch.reload())
        XCTAssertTrue(library.entries.isEmpty)
        XCTAssertTrue(calendar.events.isEmpty)
        XCTAssertTrue(updateWatch.watches.isEmpty)
    }

    private enum TestActivationError: Error {
        case patreonResetFailed
    }
}

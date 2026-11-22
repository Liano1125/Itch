import XCTest
import SwiftData
@testable import itchPocket

final class V4PersonalLibraryStoreTests: XCTestCase {
    @MainActor
    private func makeSupportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v4-library-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @MainActor
    func testLibraryEntriesRemainIsolatedWhenSwitchingAccounts() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let session = ItchAccountSession()
        let dependencies = try V4AppDependencies.open(
            in: supportDirectory,
            session: session
        )
        let context = dependencies.modelContext
        context.insert(DBGame(id: "shared-game", title: "Shared Game"))
        try context.save()

        let accountA = ItchAccountIdentity(itchUserID: 8201, username: "account-a")
        session.activate(accountA)
        let contextA = try XCTUnwrap(session.captureRequestContext())
        _ = try dependencies.recordAuthenticatedSession(contextA)

        let store = V4PersonalLibraryStore(dependencies: dependencies)
        let dateA = Date(timeIntervalSince1970: 1_800_000_100)
        try store.upsert(StoredAccountLibraryEntry(
            gameID: "shared-game",
            status: "playing",
            isFavorite: true,
            notes: "A private note",
            addedAt: dateA,
            updatedAt: dateA
        ))
        XCTAssertEqual(store.entries.map(\.notes), ["A private note"])

        let accountB = ItchAccountIdentity(itchUserID: 8202, username: "account-b")
        session.activate(accountB)
        let contextB = try XCTUnwrap(session.captureRequestContext())
        _ = try dependencies.recordAuthenticatedSession(contextB)

        try store.reload()
        XCTAssertTrue(store.entries.isEmpty)

        let dateB = Date(timeIntervalSince1970: 1_800_000_200)
        try store.upsert(StoredAccountLibraryEntry(
            gameID: "shared-game",
            status: "completed",
            isFavorite: false,
            notes: "B private note",
            addedAt: dateB,
            updatedAt: dateB
        ))
        XCTAssertEqual(store.entries.map(\.notes), ["B private note"])

        session.activate(accountA)
        try store.reload()
        XCTAssertEqual(store.entries.map(\.notes), ["A private note"])
        XCTAssertEqual(store.entries.map(\.status), ["playing"])

        session.activate(accountB)
        try store.reload()
        XCTAssertEqual(store.entries.map(\.notes), ["B private note"])
        XCTAssertEqual(store.entries.map(\.status), ["completed"])
    }

    @MainActor
    func testStoreRejectsLibraryAccessWhileSignedOut() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let dependencies = try V4AppDependencies.open(in: supportDirectory)
        let store = V4PersonalLibraryStore(dependencies: dependencies)

        XCTAssertThrowsError(try store.reload())
        XCTAssertThrowsError(try store.upsert(StoredAccountLibraryEntry(
            gameID: "missing",
            status: "playing",
            isFavorite: false,
            notes: "",
            addedAt: .now,
            updatedAt: .now
        )))
        XCTAssertTrue(store.entries.isEmpty)
    }
}

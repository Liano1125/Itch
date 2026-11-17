import XCTest
@testable import itchPocket

final class V4MigrationOwnerLockTests: XCTestCase {
    private func temporaryLockURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("V4OwnerLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("control/migration-owner.lock")
    }

    func testIndependentOpenDescriptorsCannotAcquireSameOwnerLock() throws {
        let lockURL = try temporaryLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent().deletingLastPathComponent()) }

        let first = try V4MigrationOwnerLock.acquire(at: lockURL)
        XCTAssertThrowsError(try V4MigrationOwnerLock.acquire(at: lockURL)) {
            XCTAssertEqual($0 as? V4MigrationOwnerLock.LockError, .alreadyHeld)
        }

        first.release()
        let second = try V4MigrationOwnerLock.acquire(at: lockURL)
        second.release()
    }

    func testLeaseDeinitializationReleasesKernelLock() throws {
        let lockURL = try temporaryLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent().deletingLastPathComponent()) }

        var lease: V4MigrationOwnerLock.Lease? = try V4MigrationOwnerLock.acquire(at: lockURL)
        XCTAssertNotNil(lease)
        lease = nil

        let replacement = try V4MigrationOwnerLock.acquire(at: lockURL)
        replacement.release()
    }

    func testLockFileIsNotRemovedOnRelease() throws {
        let lockURL = try temporaryLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent().deletingLastPathComponent()) }

        let lease = try V4MigrationOwnerLock.acquire(at: lockURL)
        lease.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }
}

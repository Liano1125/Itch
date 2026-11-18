import Foundation
import Darwin

/// A kernel-enforced, cross-process exclusive lock for V4 migration ownership.
///
/// The lock file is intentionally persistent: unlinking it while another
/// process may have it open can create two different inodes and split the lock.
enum V4MigrationOwnerLock {
    enum LockError: Error, Equatable {
        case alreadyHeld
        case openFailed(Int32)
        case lockFailed(Int32)
        case invalidLockFile
        case leaseNotActive
    }

    final class Lease: @unchecked Sendable {
        private let descriptor: Int32
        private let lockFilePath: String
        private let stateLock = NSLock()
        private var released = false

        fileprivate init(descriptor: Int32, lockFilePath: String) {
            self.descriptor = descriptor
            self.lockFilePath = lockFilePath
        }

        /// Confirms this live lease protects the exact stable lock path expected by the caller.
        func validateOwnership(at lockFileURL: URL) throws {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !released, lockFileURL.standardizedFileURL.path == lockFilePath else {
                throw LockError.leaseNotActive
            }

            // A matching path string is not sufficient: replacing the lock file
            // would let another process lock a new inode at the same path.
            var descriptorInfo = stat()
            guard fstat(descriptor, &descriptorInfo) == 0,
                  (descriptorInfo.st_mode & S_IFMT) == S_IFREG else {
                throw LockError.leaseNotActive
            }
            var pathInfo = stat()
            let pathStatus = lockFilePath.withCString { lstat($0, &pathInfo) }
            guard pathStatus == 0,
                  (pathInfo.st_mode & S_IFMT) == S_IFREG,
                  descriptorInfo.st_dev == pathInfo.st_dev,
                  descriptorInfo.st_ino == pathInfo.st_ino else {
                throw LockError.leaseNotActive
            }
        }

        /// Idempotent. The kernel also releases flock when the owning process exits.
        func release() {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !released else { return }
            released = true
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }

        deinit {
            release()
        }
    }

    /// Acquires a non-blocking exclusive advisory lock.
    ///
    /// Every process and every migration entry point must use the same stable
    /// lock-file URL. Do not delete or replace the lock file while in use.
    static func acquire(at lockFileURL: URL) throws -> Lease {
        let standardizedURL = lockFileURL.standardizedFileURL
        try FileManager.default.createDirectory(
            at: standardizedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = standardizedURL.path.withCString {
            open($0, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw LockError.openFailed(errno)
        }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG else {
            let code = errno
            _ = close(descriptor)
            throw LockError.invalidLockFile
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw LockError.alreadyHeld
            }
            throw LockError.lockFailed(code)
        }

        var pathInformation = stat()
        let pathStatus = standardizedURL.path.withCString { lstat($0, &pathInformation) }
        guard pathStatus == 0,
              (pathInformation.st_mode & S_IFMT) == S_IFREG,
              information.st_dev == pathInformation.st_dev,
              information.st_ino == pathInformation.st_ino else {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw LockError.invalidLockFile
        }

        return Lease(descriptor: descriptor, lockFilePath: standardizedURL.path)
    }
}

import Foundation
import Darwin

@main
struct V4MigrationOwnerLockProcessProbe {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 3, arguments[0] == "--hold" {
            let lockURL = URL(fileURLWithPath: arguments[1])
            let readyURL = URL(fileURLWithPath: arguments[2])
            let lease = try V4MigrationOwnerLock.acquire(at: lockURL)
            try Data("ready".utf8).write(to: readyURL, options: .atomic)
            withExtendedLifetime(lease) {
                while true { Thread.sleep(forTimeInterval: 0.1) }
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("V4OwnerLockProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lockURL = root.appendingPathComponent("control/migration-owner.lock")
        let readyURL = root.appendingPathComponent("child.ready")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--hold", lockURL.path, readyURL.path]
        try child.run()

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: readyURL.path), Date() < deadline {
            if !child.isRunning {
                throw ProbeError.childExitedBeforeLock
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: readyURL.path) else {
            child.terminate()
            child.waitUntilExit()
            throw ProbeError.childReadyTimeout
        }

        do {
            let unexpectedLease = try V4MigrationOwnerLock.acquire(at: lockURL)
            unexpectedLease.release()
            child.terminate()
            child.waitUntilExit()
            throw ProbeError.parentAcquiredWhileChildHeldLock
        } catch V4MigrationOwnerLock.LockError.alreadyHeld {
            // Expected: the independent child process owns the kernel lock.
        }

        child.terminate()
        child.waitUntilExit()

        let recoveredLease = try V4MigrationOwnerLock.acquire(at: lockURL)
        recoveredLease.release()
        print("PASS: independent process contention and SIGTERM lock release")
    }

    enum ProbeError: Error {
        case childExitedBeforeLock
        case childReadyTimeout
        case parentAcquiredWhileChildHeldLock
    }
}

import Darwin
import Foundation

enum LegacyMigrationLockError: Error, CustomStringConvertible {
    case incompatiblePath(String)
    case timedOut(String)
    case unavailable(String, String)

    var description: String {
        switch self {
        case .incompatiblePath(let path):
            return "simlease: legacy migration lock at \(path) is not a directory"
        case .timedOut(let path):
            return "simlease: timed out waiting for legacy migration lock at \(path)"
        case .unavailable(let path, let detail):
            return "simlease: legacy migration lock at \(path) is unavailable: \(detail)"
        }
    }
}

/// Briefly speaks the schema-1 directory-lock protocol while fencing the first
/// schema-2 write. Normal v2 transactions use `FileLock` on a different path.
final class LegacyMigrationLock {
    private static let retryIntervalMicroseconds: useconds_t = 25_000

    private var held = false
    private let path: URL

    init(path: URL) {
        self.path = path
    }

    func acquire(timeout: TimeInterval = 20) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let deadline = LegacyMigrationDeadline(timeout: timeout)

        while true {
            do {
                try FileManager.default.createDirectory(
                    at: path,
                    withIntermediateDirectories: false
                )
                held = true
                return
            } catch {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: path.path,
                    isDirectory: &isDirectory
                )
                if !exists {
                    guard !deadline.hasExpired else {
                        throw LegacyMigrationLockError.timedOut(path.path)
                    }
                    continue
                }
                guard isDirectory.boolValue else {
                    throw LegacyMigrationLockError.incompatiblePath(path.path)
                }

                guard !deadline.hasExpired else {
                    throw LegacyMigrationLockError.timedOut(path.path)
                }
                usleep(Self.retryIntervalMicroseconds)
            }
        }
    }

    func refreshTimestamp() throws {
        guard held else { return }
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: path.path
        )
    }

    func release() {
        guard held else { return }
        held = false
        try? FileManager.default.removeItem(at: path)
    }

    deinit {
        release()
    }
}

private struct LegacyMigrationDeadline {
    private let uptimeNanoseconds: UInt64

    init(timeout: TimeInterval) {
        let now = DispatchTime.now().uptimeNanoseconds
        let nonnegativeTimeout = max(0, timeout.isFinite ? timeout : 20)
        let maximumDelta = UInt64.max - now
        let requestedNanoseconds = nonnegativeTimeout * 1_000_000_000
        let delta = requestedNanoseconds >= Double(maximumDelta)
            ? maximumDelta
            : UInt64(requestedNanoseconds)
        uptimeNanoseconds = now + delta
    }

    var hasExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= uptimeNanoseconds
    }
}

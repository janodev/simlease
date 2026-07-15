import CSimLeaseSystem
import Darwin
import Foundation

public enum LockError: Error, CustomStringConvertible {
    case alreadyHeld(String)
    case couldNotLock(String, Int32)
    case couldNotOpen(String, Int32)
    case timedOut(String)
    case waitFailed(String, Int32)

    public var description: String {
        switch self {
        case .alreadyHeld(let path):
            return "simlease: lock is already held by this instance at \(path)"
        case .couldNotLock(let path, let code):
            return "simlease: could not lock \(path): \(Self.message(for: code))"
        case .couldNotOpen(let path, let code):
            return "simlease: could not open lock at \(path): \(Self.message(for: code))"
        case .timedOut(let path):
            return "simlease: could not acquire lock at \(path)"
        case .waitFailed(let path, let code):
            return "simlease: failed while waiting for lock at \(path): \(Self.message(for: code))"
        }
    }

    private static func message(for code: Int32) -> String {
        String(cString: strerror(code))
    }
}

public final class FileLock {
    let path: URL

    private static let retryIntervalNanoseconds: UInt64 = 25_000_000

    private var descriptor: Int32 = -1
    private let stateLock = NSLock()

    /// `staleAfter` remains in the signature for source compatibility. Kernel locks
    /// are released when their file descriptor closes and are never stolen by age.
    public init(path: URL, staleAfter _: TimeInterval = 10) {
        self.path = path
    }

    public func acquire(timeout: TimeInterval = 20) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard descriptor == -1 else {
            throw LockError.alreadyHeld(path.path)
        }

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var openError = EINVAL
        let openedDescriptor: Int32 = path.withUnsafeFileSystemRepresentation { fileSystemPath in
            guard let fileSystemPath else { return -1 }
            let result = Darwin.open(
                fileSystemPath,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            if result < 0 {
                openError = errno
            }
            return result
        }
        guard openedDescriptor >= 0 else {
            throw LockError.couldNotOpen(path.path, openError)
        }

        var closeOnExit = true
        defer {
            if closeOnExit {
                Self.close(openedDescriptor)
            }
        }

        let deadline = Deadline(timeout: timeout)
        while true {
            if simlease_flock(openedDescriptor, LOCK_EX | LOCK_NB) == 0 {
                descriptor = openedDescriptor
                closeOnExit = false
                return
            }

            let lockError = errno
            if lockError == EINTR {
                continue
            }
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                throw LockError.couldNotLock(path.path, lockError)
            }
            guard !deadline.hasExpired else {
                throw LockError.timedOut(path.path)
            }

            try waitBeforeRetry(until: deadline)
        }
    }

    public func release() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard descriptor >= 0 else { return }
        let heldDescriptor = descriptor
        descriptor = -1
        Self.unlock(heldDescriptor)
        Self.close(heldDescriptor)
    }

    deinit {
        release()
    }

    private func waitBeforeRetry(until deadline: Deadline) throws {
        var nanoseconds = min(Self.retryIntervalNanoseconds, deadline.remainingNanoseconds)
        while nanoseconds > 0 {
            var request = timespec(
                tv_sec: Int(nanoseconds / 1_000_000_000),
                tv_nsec: Int(nanoseconds % 1_000_000_000)
            )
            var remainder = timespec()
            if Darwin.nanosleep(&request, &remainder) == 0 {
                return
            }

            let sleepError = errno
            guard sleepError == EINTR else {
                throw LockError.waitFailed(path.path, sleepError)
            }
            guard !deadline.hasExpired else { return }

            let remainderNanoseconds = UInt64(remainder.tv_sec) * 1_000_000_000
                + UInt64(remainder.tv_nsec)
            nanoseconds = min(remainderNanoseconds, deadline.remainingNanoseconds)
        }
    }

    /// Never retry `close` after `EINTR`: the descriptor's state is unspecified and
    /// retrying could close an unrelated descriptor that another thread just opened.
    private static func close(_ descriptor: Int32) {
        _ = Darwin.close(descriptor)
    }

    private static func unlock(_ descriptor: Int32) {
        while simlease_flock(descriptor, LOCK_UN) != 0 {
            guard errno == EINTR else { return }
        }
    }
}

private struct Deadline {
    private let uptimeNanoseconds: UInt64

    init(timeout: TimeInterval) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard timeout.isFinite, !timeout.isNaN else {
            uptimeNanoseconds = timeout == .infinity ? UInt64.max : now
            return
        }

        let nonnegativeTimeout = max(0, timeout)
        let maximumDelta = UInt64.max - now
        let requestedNanoseconds = nonnegativeTimeout * 1_000_000_000
        let delta = requestedNanoseconds >= Double(maximumDelta)
            ? maximumDelta
            : UInt64(requestedNanoseconds)
        uptimeNanoseconds = now + delta
    }

    var hasExpired: Bool {
        remainingNanoseconds == 0
    }

    var remainingNanoseconds: UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= uptimeNanoseconds ? 0 : uptimeNanoseconds - now
    }
}

import Darwin
import Foundation
@testable import SimLeaseCore
import Testing
import XCTest

@Suite("Kernel-backed file lock")
struct FileLockTests {
    @Test("Release keeps one inode and permits reacquisition")
    func releaseKeepsLockFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("lock")

        let first = FileLock(path: path)
        try first.acquire()
        var isDirectory: ObjCBool = true
        #expect(FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory))
        #expect(!isDirectory.boolValue)

        first.release()
        #expect(FileManager.default.fileExists(atPath: path.path))

        let second = FileLock(path: path)
        try second.acquire(timeout: 0)
        second.release()
    }

    @Test("Zero timeout probes exactly once")
    func zeroTimeoutProbe() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("lock")
        let owner = FileLock(path: path)
        try owner.acquire()
        defer { owner.release() }

        let contender = FileLock(path: path)
        expectTimeout {
            try contender.acquire(timeout: 0)
        }

        owner.release()
        try contender.acquire(timeout: 0)
        contender.release()
    }

    @Test("An old timestamp never permits stealing a live lock")
    func oldTimestampDoesNotPermitStealing() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("lock")
        let owner = FileLock(path: path)
        try owner.acquire()
        defer { owner.release() }

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: path.path
        )

        let contender = FileLock(path: path, staleAfter: 0)
        expectTimeout {
            try contender.acquire(timeout: 0.075)
        }
    }

    @Test("Open failures are distinct from contention")
    func openFailureIsNotTimeout() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("lock")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)

        do {
            try FileLock(path: path).acquire(timeout: 0)
            Issue.record("Expected opening a directory as a lock file to fail")
        } catch LockError.couldNotOpen(let errorPath, _) {
            #expect(errorPath == path.path)
        } catch {
            Issue.record("Expected couldNotOpen, received \(error)")
        }
    }

    @Test("A separate process cannot enter while the lock is held")
    func subprocessContention() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("lock")
        let owner = FileLock(path: path)
        try owner.acquire()
        defer { owner.release() }

        let child = try launchHelper(mode: .expectTimeout, lockPath: path)
        child.process.waitUntilExit()
        let output = child.readOutput()

        #expect(
            child.process.terminationReason == .exit
                && child.process.terminationStatus == EXIT_SUCCESS,
            "Subprocess did not observe contention:\n\(output)"
        )
    }

    @Test("SIGKILL releases subprocess ownership immediately")
    func crashReleasesLock() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("lock")
        let readyPath = directory.appendingPathComponent("ready")
        let child = try launchHelper(mode: .hold, lockPath: path, readyPath: readyPath)
        defer {
            if child.process.isRunning {
                _ = Darwin.kill(child.process.processIdentifier, SIGKILL)
                child.process.waitUntilExit()
            }
        }

        try waitForReadyFile(at: readyPath, child: child)

        let contender = FileLock(path: path)
        expectTimeout {
            try contender.acquire(timeout: 0)
        }

        let killed = Darwin.kill(child.process.processIdentifier, SIGKILL)
        #expect(killed == 0)
        child.process.waitUntilExit()
        let output = child.readOutput()
        #expect(
            child.process.terminationReason == .uncaughtSignal
                && child.process.terminationStatus == SIGKILL,
            "Lock owner did not terminate with SIGKILL:\n\(output)"
        )

        try contender.acquire(timeout: 2)
        contender.release()
    }

    @Test("Deinitialization closes the owning descriptor")
    func deinitializationReleasesLock() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("lock")

        do {
            let owner = FileLock(path: path)
            try owner.acquire()
        }

        let contender = FileLock(path: path)
        try contender.acquire(timeout: 0)
        contender.release()
    }

    private func expectTimeout(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected lock acquisition to time out")
        } catch LockError.timedOut {
            // Expected contention result.
        } catch {
            Issue.record("Expected timedOut, received \(error)")
        }
    }

    private func launchHelper(
        mode: FileLockHelperMode,
        lockPath: URL,
        readyPath: URL? = nil
    ) throws -> FileLockHelperProcess {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "SimLeaseCoreTests.FileLockSubprocessHelperTests/testRunFileLockHelper",
            Bundle(for: FileLockSubprocessHelperTests.self).bundleURL.path
        ]
        process.standardOutput = output
        process.standardError = output

        var environment = ProcessInfo.processInfo.environment
        environment[FileLockHelperEnvironment.mode] = mode.rawValue
        environment[FileLockHelperEnvironment.lockPath] = lockPath.path
        environment[FileLockHelperEnvironment.readyPath] = readyPath?.path
        process.environment = environment

        try process.run()
        return FileLockHelperProcess(process: process, output: output)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simlease-file-lock-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForReadyFile(at path: URL, child: FileLockHelperProcess) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !FileManager.default.fileExists(atPath: path.path) {
            guard child.process.isRunning else {
                child.process.waitUntilExit()
                throw FileLockHelperFailure.earlyExit(child.readOutput())
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw FileLockHelperFailure.readinessTimedOut
            }
            usleep(10_000)
        }
    }
}

private enum FileLockHelperEnvironment {
    static let lockPath = "SIMLEASE_TEST_LOCK_PATH"
    static let mode = "SIMLEASE_TEST_LOCK_MODE"
    static let readyPath = "SIMLEASE_TEST_LOCK_READY_PATH"
}

private enum FileLockHelperFailure: Error, CustomStringConvertible {
    case earlyExit(String)
    case readinessTimedOut

    var description: String {
        switch self {
        case .earlyExit(let output):
            return "File-lock helper exited before becoming ready:\n\(output)"
        case .readinessTimedOut:
            return "File-lock helper did not become ready"
        }
    }
}

private enum FileLockHelperMode: String {
    case expectTimeout
    case hold
}

private struct FileLockHelperProcess {
    let process: Process
    let output: Pipe

    func readOutput() -> String {
        String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "<non-UTF-8 output>"
    }
}

/// This XCTest case is intentionally a subprocess entry point. The behavior tests
/// above execute with Swift Testing; `xctest -XCTest` launches only this helper in
/// a genuinely independent process.
final class FileLockSubprocessHelperTests: XCTestCase {
    func testRunFileLockHelper() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawMode = environment[FileLockHelperEnvironment.mode] else {
            return
        }
        guard let mode = FileLockHelperMode(rawValue: rawMode),
              let lockPath = environment[FileLockHelperEnvironment.lockPath] else {
            XCTFail("Invalid file-lock helper environment")
            return
        }

        let lock = FileLock(path: URL(fileURLWithPath: lockPath))
        switch mode {
        case .expectTimeout:
            XCTAssertThrowsError(try lock.acquire(timeout: 0)) { error in
                guard case LockError.timedOut = error else {
                    return XCTFail("Expected timedOut, received \(error)")
                }
            }
        case .hold:
            guard let readyPath = environment[FileLockHelperEnvironment.readyPath] else {
                return XCTFail("Missing helper readiness path")
            }
            try lock.acquire(timeout: 2)
            _ = FileManager.default.createFile(atPath: readyPath, contents: Data())
            while true {
                pause()
            }
        }
    }
}

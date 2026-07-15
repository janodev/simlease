import Darwin
import Foundation
@testable import SimLeaseCore
import Testing
import XCTest

@Suite("Registry migration compatibility")
struct RegistryMigrationCompatibilityTests {
    @Test("An old v1 directory is never stolen by age")
    func oldLegacyDirectoryFailsClosed() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try fixture.writeSchemaOneRegistry()
        try FileManager.default.createDirectory(
            at: fixture.paths.legacyLock,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: fixture.paths.legacyLock.path
        )

        do {
            try RegistryTransaction.withLock(
                paths: fixture.paths,
                migrationTimeout: 0.075
            ) {}
            Issue.record("Expected migration to time out behind the legacy owner")
        } catch LegacyMigrationLockError.timedOut(let path) {
            #expect(path == fixture.paths.legacyLock.path)
        } catch {
            Issue.record("Expected timedOut, received \(error)")
        }

        #expect(try fixture.persistedSchema() == 1)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: fixture.paths.legacyLock.path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }

    @Test("An incompatible legacy-lock path blocks migration without unlinking")
    func incompatibleLegacyPathFailsClosed() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try fixture.writeSchemaOneRegistry()
        try Data("unknown owner".utf8).write(to: fixture.paths.legacyLock)

        do {
            try RegistryTransaction.withLock(paths: fixture.paths) {}
            Issue.record("Expected migration to reject a non-directory legacy path")
        } catch LegacyMigrationLockError.incompatiblePath(let path) {
            #expect(path == fixture.paths.legacyLock.path)
        } catch {
            Issue.record("Expected incompatiblePath, received \(error)")
        }

        #expect(try fixture.persistedSchema() == 1)
        #expect(
            try String(contentsOf: fixture.paths.legacyLock, encoding: .utf8) == "unknown owner"
        )
    }

    @Test("A held v1 directory lock delays the schema-2 fence")
    func heldLegacyLockDelaysMigration() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try fixture.writeSchemaOneRegistry()

        let helper = try fixture.launchLegacyHelper(mode: .hold)
        defer { helper.terminateIfRunning() }
        try fixture.waitForReadyFile(child: helper)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            _ = FileManager.default.createFile(
                atPath: fixture.releasePath.path,
                contents: Data()
            )
        }
        let start = DispatchTime.now().uptimeNanoseconds
        try RegistryTransaction.withLock(paths: fixture.paths) {}
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        helper.process.waitUntilExit()
        let output = helper.readOutput()

        #expect(
            helper.process.terminationReason == .exit
                && helper.process.terminationStatus == EXIT_SUCCESS,
            "Legacy helper failed:\n\(output)"
        )
        #expect(elapsed >= 150_000_000)
        #expect(try fixture.persistedSchema() == Registry.currentSchema)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.legacyLock.path))
    }

    @Test("A post-migration v1 lock cycle cannot split the v2 flock inode")
    func legacyLockCannotSplitCurrentLock() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try fixture.writeSchemaOneRegistry()
        try RegistryTransaction.withLock(paths: fixture.paths) {}

        let owner = FileLock(path: fixture.paths.lock)
        try owner.acquire()
        defer { owner.release() }
        let inodeBefore = try fixture.inode(at: fixture.paths.lock)

        let helper = try fixture.launchLegacyHelper(mode: .acquireAndRelease)
        helper.process.waitUntilExit()
        let output = helper.readOutput()
        #expect(
            helper.process.terminationReason == .exit
                && helper.process.terminationStatus == EXIT_SUCCESS,
            "Legacy helper failed:\n\(output)"
        )

        #expect(try fixture.inode(at: fixture.paths.lock) == inodeBefore)
        let contender = FileLock(path: fixture.paths.lock)
        do {
            try contender.acquire(timeout: 0)
            Issue.record("Expected the original v2 owner to retain exclusivity")
            contender.release()
        } catch LockError.timedOut {
            // The original v2 inode remains authoritative.
        } catch {
            Issue.record("Expected lock contention, received \(error)")
        }
    }
}

private struct MigrationFixture {
    let directory: URL
    let paths: SimLeasePaths
    let readyPath: URL
    let releasePath: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simlease-registry-migration-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        paths = SimLeasePaths(
            registry: directory.appendingPathComponent("registry.json"),
            lock: directory.appendingPathComponent("registry.lock"),
            legacyLock: directory.appendingPathComponent("lock")
        )
        readyPath = directory.appendingPathComponent("legacy-ready")
        releasePath = directory.appendingPathComponent("legacy-release")
    }

    func inode(at path: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard let number = attributes[.systemFileNumber] as? NSNumber else {
            throw MigrationFixtureError.missingInode(path.path)
        }
        return number.uint64Value
    }

    func launchLegacyHelper(mode: LegacyLockHelperMode) throws -> LegacyLockHelperProcess {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "SimLeaseCoreTests.LegacyLockSubprocessHelperTests/testRunLegacyLockHelper",
            Bundle(for: LegacyLockSubprocessHelperTests.self).bundleURL.path
        ]
        process.standardOutput = output
        process.standardError = output

        var environment = ProcessInfo.processInfo.environment
        environment[LegacyLockHelperEnvironment.lockPath] = paths.legacyLock.path
        environment[LegacyLockHelperEnvironment.mode] = mode.rawValue
        environment[LegacyLockHelperEnvironment.readyPath] = readyPath.path
        environment[LegacyLockHelperEnvironment.releasePath] = releasePath.path
        process.environment = environment
        try process.run()
        return LegacyLockHelperProcess(process: process, output: output)
    }

    func persistedSchema() throws -> Int {
        let data = try Data(contentsOf: paths.registry)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let document = object as? [String: Any],
              let schema = document["schema"] as? Int else {
            throw MigrationFixtureError.missingSchema
        }
        return schema
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func waitForReadyFile(child: LegacyLockHelperProcess) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !FileManager.default.fileExists(atPath: readyPath.path) {
            guard child.process.isRunning else {
                child.process.waitUntilExit()
                throw MigrationFixtureError.earlyExit(child.readOutput())
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw MigrationFixtureError.readinessTimedOut
            }
            usleep(10_000)
        }
    }

    func writeSchemaOneRegistry() throws {
        let contents = #"{"schema": 1, "leases": {}}"#
        try contents.write(to: paths.registry, atomically: true, encoding: .utf8)
    }
}

private enum MigrationFixtureError: Error {
    case earlyExit(String)
    case missingInode(String)
    case missingSchema
    case readinessTimedOut
}

private enum LegacyLockHelperEnvironment {
    static let lockPath = "SIMLEASE_TEST_LEGACY_LOCK_PATH"
    static let mode = "SIMLEASE_TEST_LEGACY_LOCK_MODE"
    static let readyPath = "SIMLEASE_TEST_LEGACY_LOCK_READY_PATH"
    static let releasePath = "SIMLEASE_TEST_LEGACY_LOCK_RELEASE_PATH"
}

private enum LegacyLockHelperMode: String {
    case acquireAndRelease
    case hold
}

private struct LegacyLockHelperProcess {
    let process: Process
    let output: Pipe

    func readOutput() -> String {
        String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "<non-UTF-8 output>"
    }

    func terminateIfRunning() {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}

/// This helper intentionally copies the released schema-1 mkdir/stale-lock
/// protocol and executes in an independent process.
final class LegacyLockSubprocessHelperTests: XCTestCase {
    func testRunLegacyLockHelper() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawMode = environment[LegacyLockHelperEnvironment.mode] else {
            return
        }
        guard let mode = LegacyLockHelperMode(rawValue: rawMode),
              let lockPath = environment[LegacyLockHelperEnvironment.lockPath] else {
            return XCTFail("Invalid legacy-lock helper environment")
        }

        let lock = ReleasedV1DirectoryLock(path: URL(fileURLWithPath: lockPath))
        try lock.acquire()
        switch mode {
        case .acquireAndRelease:
            lock.release()
        case .hold:
            guard let readyPath = environment[LegacyLockHelperEnvironment.readyPath],
                  let releasePath = environment[LegacyLockHelperEnvironment.releasePath] else {
                return XCTFail("Missing legacy-lock helper paths")
            }
            _ = FileManager.default.createFile(atPath: readyPath, contents: Data())
            while !FileManager.default.fileExists(atPath: releasePath) {
                usleep(10_000)
            }
            lock.release()
        }
    }
}

private final class ReleasedV1DirectoryLock {
    private var held = false
    private let path: URL
    private let staleAfter: TimeInterval = 10

    init(path: URL) {
        self.path = path
    }

    func acquire(timeout: TimeInterval = 20) throws {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                try fileManager.createDirectory(at: path, withIntermediateDirectories: false)
                held = true
                return
            } catch {
                if let modified = (try? fileManager.attributesOfItem(atPath: path.path))?[
                    .modificationDate
                ] as? Date,
                    Date().timeIntervalSince(modified) > staleAfter {
                    try? fileManager.removeItem(at: path)
                    continue
                }
                if Date() > deadline {
                    throw ReleasedV1DirectoryLockError.timedOut(path.path)
                }
                usleep(200_000)
            }
        }
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

private enum ReleasedV1DirectoryLockError: Error {
    case timedOut(String)
}

import Darwin
import Foundation
@testable import SimLeaseCore
import Testing

private enum CLIFixtureError: Error {
    case missingExecutable(String)
}

private final class CLITestBundleToken: NSObject {}

@Suite(.serialized)
struct SimleaseCLIIntegrationTests {
    struct CommandResult {
        let status: Int32
        let stderr: String
        let stdout: String
    }

    final class Fixture {
        let childLog: URL
        let childPID: URL
        let directory: URL
        let executable: URL
        let fakeLog: URL
        let fakeXcrun: URL
        let stateDirectory: URL

        init() throws {
            // SwiftPM places products beside the test bundle for every configuration and scratch path.
            let productsDirectory = Bundle(for: CLITestBundleToken.self).bundleURL
                .deletingLastPathComponent()
            executable = productsDirectory.appendingPathComponent("simlease")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw CLIFixtureError.missingExecutable(executable.path)
            }

            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("simlease-cli-tests-\(UUID().uuidString)")
            let bin = directory.appendingPathComponent("bin")
            stateDirectory = directory.appendingPathComponent("state")
            childLog = directory.appendingPathComponent("child.log")
            childPID = directory.appendingPathComponent("child.pid")
            fakeLog = directory.appendingPathComponent("simctl.log")
            fakeXcrun = bin.appendingPathComponent("xcrun")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try writeExecutable(Self.fakeXcrunScript, to: fakeXcrun)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        func run(childExit: Int32 = 0, bootstatusExit: Int32 = 0,
                 deleteExit: Int32 = 0) throws -> CommandResult {
            let child = directory.appendingPathComponent("child")
            try writeExecutable(Self.childScript, to: child)

            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "run", "--label", "cli-integration", "--", child.path, "--child-flag"
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(fakeXcrun.deletingLastPathComponent().path):\(environment["PATH"] ?? "")"
            environment["SIMLEASE_CHILD_EXIT"] = "\(childExit)"
            environment["SIMLEASE_CHILD_LOG"] = childLog.path
            environment["SIMLEASE_FAKE_BOOTSTATUS_EXIT"] = "\(bootstatusExit)"
            environment["SIMLEASE_FAKE_DELETE_EXIT"] = "\(deleteExit)"
            environment["SIMLEASE_FAKE_LOG"] = fakeLog.path
            environment["SIMLEASE_HOME"] = stateDirectory.path
            process.environment = environment
            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout
            try process.run()
            process.waitUntilExit()
            return CommandResult(
                status: process.terminationStatus,
                stderr: String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                stdout: String(
                    data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        }

        func startLongRunning() throws -> Process {
            let child = directory.appendingPathComponent("long-child")
            try writeExecutable(Self.longRunningChildScript, to: child)

            let process = Process()
            process.executableURL = executable
            process.arguments = ["run", "--label", "signal-integration", "--", child.path]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(fakeXcrun.deletingLastPathComponent().path):\(environment["PATH"] ?? "")"
            environment["SIMLEASE_CHILD_LOG"] = childLog.path
            environment["SIMLEASE_CHILD_PID"] = childPID.path
            environment["SIMLEASE_FAKE_BOOTSTATUS_EXIT"] = "0"
            environment["SIMLEASE_FAKE_LOG"] = fakeLog.path
            environment["SIMLEASE_HOME"] = stateDirectory.path
            process.environment = environment
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            return process
        }

        func runGC() throws -> CommandResult {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["gc"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(fakeXcrun.deletingLastPathComponent().path):\(environment["PATH"] ?? "")"
            environment["SIMLEASE_FAKE_BOOTSTATUS_EXIT"] = "0"
            environment["SIMLEASE_FAKE_LOG"] = fakeLog.path
            environment["SIMLEASE_HOME"] = stateDirectory.path
            process.environment = environment
            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout
            try process.run()
            process.waitUntilExit()
            return CommandResult(
                status: process.terminationStatus,
                stderr: String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                stdout: String(
                    data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        }

        private func writeExecutable(_ contents: String, to url: URL) throws {
            try Data(contents.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: url.path)
        }

        static let childScript = """
        #!/bin/sh
        set -eu
        {
          printf '%s\n' "$SIMULATOR_ID"
          printf '%s\n' "$SIMULATOR_UDID"
          printf '%s\n' "$SIMLEASE_SESSION_ID"
          printf '%s\n' "$1"
        } > "$SIMLEASE_CHILD_LOG"
        exit "${SIMLEASE_CHILD_EXIT:-0}"
        """

        static let fakeXcrunScript = """
        #!/bin/sh
        set -eu
        printf '%s\n' "$*" >> "$SIMLEASE_FAKE_LOG"
        test "$1" = "simctl"
        shift
        case "$1" in
          list)
            case "$3" in
              devices) printf '%s%s\n' \
                '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[' \
                '{"udid":"FAKE-SESSION-UDID","name":"🔒 fake session · iPhone 17 Pro",' \
                '"state":"Booted","isAvailable":true}]}}' ;;
              devicetypes) printf '%s%s\n' \
                '{"devicetypes":[{"name":"iPhone 17 Pro",' \
                '"identifier":"dt-17"}]}' ;;
              runtimes) printf '%s%s\n' \
                '{"runtimes":[{"identifier":"rt-27","name":"iOS 27.0",' \
                '"version":"27.0","isAvailable":true}]}' ;;
              *) exit 64 ;;
            esac
            ;;
          create) printf '%s\n' 'FAKE-SESSION-UDID' ;;
          boot) ;;
          bootstatus) exit "${SIMLEASE_FAKE_BOOTSTATUS_EXIT:-0}" ;;
          shutdown) ;;
          delete) exit "${SIMLEASE_FAKE_DELETE_EXIT:-0}" ;;
          *) exit 64 ;;
        esac
        """

        static let longRunningChildScript = """
        #!/bin/sh
        set -eu
        trap 'exit 0' INT TERM
        printf '%s\n' "$$" > "$SIMLEASE_CHILD_PID"
        : > "$SIMLEASE_CHILD_LOG"
        while true; do sleep 1; done
        """
    }

    @Test
    func runExportsSessionEnvironmentAndCleansUp() throws {
        let fixture = try Fixture()
        let result = try fixture.run()

        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        let childLines = try String(contentsOf: fixture.childLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(childLines.count == 4)
        #expect(childLines[0] == "FAKE-SESSION-UDID")
        #expect(childLines[1] == "FAKE-SESSION-UDID")
        #expect(!childLines[2].isEmpty)
        #expect(childLines[3] == "--child-flag")
        #expect(result.stderr.contains("Created private iPhone 17 Pro"))
        #expect(result.stderr.contains("Deleted private iPhone 17 Pro"))

        let calls = try String(contentsOf: fixture.fakeLog, encoding: .utf8)
        #expect(calls.contains("simctl boot FAKE-SESSION-UDID"))
        #expect(calls.contains("simctl bootstatus FAKE-SESSION-UDID -b"))
        #expect(calls.contains("simctl shutdown FAKE-SESSION-UDID"))
        #expect(calls.contains("simctl delete FAKE-SESSION-UDID"))
        #expect(try RegistryStore.load(
            at: fixture.stateDirectory.appendingPathComponent("registry.json")).leases.isEmpty)
    }

    @Test
    func childFailurePreservesExitStatusAndStillCleansUp() throws {
        let fixture = try Fixture()
        let result = try fixture.run(childExit: 42)

        #expect(result.status == 42)
        let calls = try String(contentsOf: fixture.fakeLog, encoding: .utf8)
        #expect(calls.contains("simctl delete FAKE-SESSION-UDID"))
        #expect(try RegistryStore.load(
            at: fixture.stateDirectory.appendingPathComponent("registry.json")).leases.isEmpty)
    }

    @Test
    func childFailureStillWinsWhenCleanupAlsoFails() throws {
        let fixture = try Fixture()
        let result = try fixture.run(childExit: 42, deleteExit: 72)

        #expect(result.status == 42)
        #expect(result.stderr.contains("Cleanup") || result.stderr.contains("delete"))
        let registry = try RegistryStore.load(
            at: fixture.stateDirectory.appendingPathComponent("registry.json"))
        #expect(registry.leases["FAKE-SESSION-UDID"]?.sessionState == .quarantined)
    }

    @Test
    func bootReadinessFailureSkipsChildAndStillCleansUp() throws {
        let fixture = try Fixture()
        let result = try fixture.run(bootstatusExit: 71)

        #expect(result.status != 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.childLog.path))
        #expect(result.stderr.contains("bootstatus"))
        let calls = try String(contentsOf: fixture.fakeLog, encoding: .utf8)
        #expect(calls.contains("simctl shutdown FAKE-SESSION-UDID"))
        #expect(calls.contains("simctl delete FAKE-SESSION-UDID"))
    }

    @Test
    func terminationSignalIsForwardedBeforeCleanup() throws {
        let fixture = try Fixture()
        let process = try fixture.startLongRunning()
        defer {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            if let childPID = try? String(contentsOf: fixture.childPID, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(childPID) {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }

        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: fixture.childLog.path), Date() < readyDeadline {
            usleep(20_000)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.childLog.path))

        _ = Darwin.kill(process.processIdentifier, SIGTERM)
        let exitDeadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < exitDeadline {
            usleep(20_000)
        }
        if process.isRunning {
            Issue.record("simlease did not finish after forwarding SIGTERM")
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        #expect(process.terminationStatus == 128 + SIGTERM)
        let calls = try String(contentsOf: fixture.fakeLog, encoding: .utf8)
        #expect(calls.contains("simctl delete FAKE-SESSION-UDID"))
        #expect(try RegistryStore.load(
            at: fixture.stateDirectory.appendingPathComponent("registry.json")).leases.isEmpty)
    }

    @Test
    func sigkillLeavesDeleteOnlySessionForGarbageCollection() throws {
        let fixture = try Fixture()
        let process = try fixture.startLongRunning()
        defer {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            if let childPID = try? String(contentsOf: fixture.childPID, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(childPID) {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }

        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: fixture.childLog.path), Date() < readyDeadline {
            usleep(20_000)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.childLog.path))

        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        let abandoned = try RegistryStore.load(
            at: fixture.stateDirectory.appendingPathComponent("registry.json"))
        #expect(abandoned.leases["FAKE-SESSION-UDID"]?.sessionState == .running)

        let garbageCollection = try fixture.runGC()
        #expect(garbageCollection.status == 0)
        #expect(garbageCollection.stderr.contains("freed 1 lease"))
        #expect(try RegistryStore.load(
            at: fixture.stateDirectory.appendingPathComponent("registry.json")).leases.isEmpty)
        let calls = try String(contentsOf: fixture.fakeLog, encoding: .utf8)
        #expect(calls.contains("simctl delete FAKE-SESSION-UDID"))
    }
}

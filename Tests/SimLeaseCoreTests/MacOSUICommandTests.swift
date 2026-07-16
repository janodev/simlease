import Darwin
import Foundation
import Testing

private enum MacOSUITestError: Error {
    case missingExecutable(String)
    case processDidNotExit
    case timedOutWaitingForFile(String)
}

private final class MacOSUITestBundleToken: NSObject {}

@Suite(.serialized)
struct MacOSUICommandTests {
    struct CommandResult {
        let status: Int32
        let stderr: String
    }

    final class Fixture {
        let directory: URL
        let executable: URL
        let stateDirectory: URL

        init() throws {
            let productsDirectory = Bundle(for: MacOSUITestBundleToken.self).bundleURL
                .deletingLastPathComponent()
            executable = productsDirectory.appendingPathComponent("simlease")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw MacOSUITestError.missingExecutable(executable.path)
            }

            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("simlease-macos-ui-tests-\(UUID().uuidString)")
            stateDirectory = directory.appendingPathComponent("state")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        func run(command: [String], wait: String = "5") throws -> CommandResult {
            let process = configuredProcess(command: command, wait: wait)
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return CommandResult(
                status: process.terminationStatus,
                stderr: String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? "")
        }

        func start(command: [String], wait: String = "5") throws -> Process {
            let process = configuredProcess(command: command, wait: wait)
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            return process
        }

        func makeHolder() throws -> URL {
            try makeExecutable(Self.holderScript, name: "holder")
        }

        func makeProbe() throws -> URL {
            try makeExecutable(Self.probeScript, name: "probe")
        }

        private func configuredProcess(command: [String], wait: String) -> Process {
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "macos-ui", "--label", "cli-integration", "--agent", "test-agent",
                "--wait", wait, "--",
            ] + command
            var environment = ProcessInfo.processInfo.environment
            environment["SIMLEASE_HOME"] = stateDirectory.path
            process.environment = environment
            return process
        }

        private func makeExecutable(_ contents: String, name: String) throws -> URL {
            let file = directory.appendingPathComponent("\(name)-\(UUID().uuidString)")
            try Data(contents.utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: file.path)
            return file
        }

        static let holderScript = """
        #!/bin/sh
        set -eu
        {
          printf '%s\n' "$SIMLEASE_HOST_RESOURCE"
          printf '%s\n' "$SIMLEASE_MACOS_UI"
          printf '%s\n' "$SIMLEASE_SESSION_ID"
          printf '%s\n' "$$"
        } > "$3"
        : > "$1"
        while [ ! -e "$2" ]; do sleep 0.05; done
        """

        static let probeScript = """
        #!/bin/sh
        set -eu
        {
          printf '%s\n' "$SIMLEASE_HOST_RESOURCE"
          printf '%s\n' "$SIMLEASE_MACOS_UI"
          printf '%s\n' "$SIMLEASE_SESSION_ID"
          printf '%s\n' "$2"
        } > "$1"
        """
    }

    @Test
    func serializesCommandsAndExportsSessionEnvironment() throws {
        let fixture = try Fixture()
        let ready = fixture.directory.appendingPathComponent("host.ready")
        let release = fixture.directory.appendingPathComponent("host.release")
        let holderLog = fixture.directory.appendingPathComponent("host-holder.log")
        let probeLog = fixture.directory.appendingPathComponent("host-probe.log")
        let holderCommand = try fixture.makeHolder()
        let probeCommand = try fixture.makeProbe()
        let holder = try fixture.start(
            command: [holderCommand.path, ready.path, release.path, holderLog.path])
        defer {
            if holder.isRunning { _ = Darwin.kill(holder.processIdentifier, SIGKILL) }
        }
        try waitForFile(ready)

        let probe = try fixture.start(
            command: [probeCommand.path, probeLog.path, "probe-argument"])
        defer {
            if probe.isRunning { _ = Darwin.kill(probe.processIdentifier, SIGKILL) }
        }
        usleep(200_000)
        #expect(probe.isRunning)
        #expect(!FileManager.default.fileExists(atPath: probeLog.path))

        try Data().write(to: release)
        try waitForExit(holder)
        try waitForExit(probe)
        #expect(holder.terminationStatus == 0)
        #expect(probe.terminationStatus == 0)

        let holderLines = try lines(in: holderLog)
        let probeLines = try lines(in: probeLog)
        #expect(holderLines.count == 4)
        #expect(holderLines[0] == "macos-ui")
        #expect(holderLines[1] == "1")
        #expect(!holderLines[2].isEmpty)
        #expect(holderLines[3] == "\(holder.processIdentifier)")
        #expect(probeLines.count == 4)
        #expect(probeLines[0] == "macos-ui")
        #expect(probeLines[1] == "1")
        #expect(!probeLines[2].isEmpty)
        #expect(probeLines[3] == "probe-argument")
        #expect(holderLines[2] != probeLines[2])
        #expect(FileManager.default.fileExists(
            atPath: fixture.stateDirectory.appendingPathComponent("host-locks/macos-ui.lock").path))
    }

    @Test
    func commandExitStatusIsPreserved() throws {
        let fixture = try Fixture()
        let result = try fixture.run(command: ["/bin/sh", "-c", "exit 42"])

        #expect(result.status == 42)
        #expect(result.stderr.contains("Acquired exclusive macOS UI access"))
    }

    @Test
    func killingCommandReleasesLock() throws {
        let fixture = try Fixture()
        let ready = fixture.directory.appendingPathComponent("crash.ready")
        let release = fixture.directory.appendingPathComponent("never.release")
        let holderLog = fixture.directory.appendingPathComponent("crash-holder.log")
        let holderCommand = try fixture.makeHolder()
        let holder = try fixture.start(
            command: [holderCommand.path, ready.path, release.path, holderLog.path])
        defer {
            if holder.isRunning { _ = Darwin.kill(holder.processIdentifier, SIGKILL) }
        }
        try waitForFile(ready)

        _ = Darwin.kill(holder.processIdentifier, SIGKILL)
        try waitForExit(holder)
        #expect(holder.terminationReason == .uncaughtSignal)
        #expect(holder.terminationStatus == SIGKILL)

        let contender = try fixture.run(command: ["/usr/bin/true"], wait: "2")
        #expect(contender.status == 0)
    }
}

private func lines(in file: URL) throws -> [String] {
    try String(contentsOf: file, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
}

private func waitForExit(_ process: Process, timeout: TimeInterval = 5) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        usleep(20_000)
    }
    guard !process.isRunning else { throw MacOSUITestError.processDidNotExit }
    process.waitUntilExit()
}

private func waitForFile(_ file: URL, timeout: TimeInterval = 5) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
        usleep(20_000)
    }
    guard FileManager.default.fileExists(atPath: file.path) else {
        throw MacOSUITestError.timedOutWaitingForFile(file.path)
    }
}

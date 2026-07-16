import ArgumentParser
import Darwin
import Foundation
import SimLeaseCore

struct MacOSUI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macos-ui",
        abstract: "Run a command with exclusive access to macOS UI automation.")

    @Option(help: "Task label included in lock diagnostics (default: git branch).")
    var label: String?

    @Option(help: "Agent name included in lock diagnostics (default: detected from env).")
    var agent: String?

    @Option(help: "Maximum wait: seconds, 90m, 2h or forever (default: forever).")
    var wait = "forever"

    @Argument(parsing: .remaining, help: "Command and arguments to run.")
    var command: [String] = []

    func validate() throws {
        if command.isEmpty {
            throw ValidationError(
                "provide a command after '--', for example: simlease macos-ui -- make test-ui")
        }
        _ = try parseWait(wait)
    }

    func run() throws {
        let resolvedLabel = label ?? defaultLabel()
        let resolvedAgent = agent ?? defaultAgent()
        let lock = FileLock(path: SimLeasePaths.default().macOSUILock, inheritOnExec: true)
        stderrPrint(
            "⏳ Waiting for exclusive macOS UI access for \"\(resolvedLabel)\" "
                + "(\(resolvedAgent))")
        try lock.acquire(timeout: parseWait(wait))

        let sessionID = UUID().uuidString
        stderrPrint(
            "🔒 Acquired exclusive macOS UI access for \"\(resolvedLabel)\" "
                + "[session \(sessionID.prefix(8))]")
        try replaceCurrentProcess(
            arguments: command,
            environment: [
                "SIMLEASE_HOST_RESOURCE": "macos-ui",
                "SIMLEASE_MACOS_UI": "1",
                "SIMLEASE_SESSION_ID": sessionID,
            ])
    }
}

private struct ExecFailure: Error, CustomStringConvertible {
    let code: Int32
    let executable: String

    var description: String {
        "could not execute \(executable): \(String(cString: strerror(code)))"
    }
}

private func replaceCurrentProcess(
    arguments: [String],
    environment additions: [String: String]
) throws -> Never {
    for (key, value) in additions {
        guard setenv(key, value, 1) == 0 else {
            throw ExecFailure(code: errno, executable: arguments[0])
        }
    }

    let executable = "/usr/bin/env"
    let argumentStrings = [executable] + arguments
    var pointers: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
    pointers.append(nil)
    defer {
        for case let pointer? in pointers {
            free(pointer)
        }
    }

    _ = pointers.withUnsafeMutableBufferPointer { buffer in
        execv(executable, buffer.baseAddress)
    }
    throw ExecFailure(code: errno, executable: arguments[0])
}

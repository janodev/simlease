import Foundation

public struct ProcessResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunner {
    func run(_ arguments: [String]) throws -> ProcessResult
}

public struct ShellRunner: ProcessRunner {
    public init() {}

    public func run(_ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

public struct Device: Equatable {
    public let udid: String
    public let name: String
    public let state: String
    public let runtime: String
    public let isAvailable: Bool
}

public enum SimctlError: Error, CustomStringConvertible {
    case commandFailed(String, String)
    case malformedResponse(String, String)

    public var description: String {
        switch self {
        case .commandFailed(let command, let detail):
            return "simctl \(command) failed: \(detail)"
        case .malformedResponse(let command, let detail):
            return "simctl \(command) returned a malformed response: \(detail)"
        }
    }
}

public struct Simctl {
    let runner: ProcessRunner

    public init(runner: ProcessRunner = ShellRunner()) {
        self.runner = runner
    }

    @discardableResult
    func runChecked(_ arguments: [String]) throws -> ProcessResult {
        let result = try runner.run(["xcrun", "simctl"] + arguments)
        return try check(result, for: arguments)
    }

    @discardableResult
    func check(_ result: ProcessResult, for arguments: [String]) throws -> ProcessResult {
        guard result.status == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty
                ? "exit status \(result.status)"
                : "exit status \(result.status): \(stderr)"
            throw SimctlError.commandFailed(arguments.joined(separator: " "), detail)
        }
        return result
    }

    func listJSON(_ what: String, extra: [String] = []) throws -> [String: Any] {
        let arguments = ["list", "-j", what] + extra
        let result = try runChecked(arguments)
        let data = Data(result.stdout.utf8)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SimctlError.malformedResponse(
                arguments.joined(separator: " "),
                "invalid JSON (\(error.localizedDescription))")
        }
        guard let dictionary = object as? [String: Any] else {
            throw SimctlError.malformedResponse(
                arguments.joined(separator: " "),
                "expected a top-level object")
        }
        return dictionary
    }

    func listValue<Value>(_ what: String, extra: [String] = [], key: String,
                          as _: Value.Type = Value.self) throws -> Value {
        let response = try listJSON(what, extra: extra)
        guard let value = response[key] as? Value else {
            throw SimctlError.malformedResponse(
                (["list", "-j", what] + extra).joined(separator: " "),
                "expected '\(key)' with the documented shape")
        }
        return value
    }

    public func devices(availableOnly: Bool) throws -> [Device] {
        let extra = availableOnly ? ["available"] : []
        let data: [String: [[String: Any]]] = try listValue(
            "devices", extra: extra, key: "devices")
        var result: [Device] = []
        for (runtime, list) in data {
            for entry in list {
                guard let udid = entry["udid"] as? String, !udid.isEmpty,
                      let name = entry["name"] as? String, !name.isEmpty,
                      let state = entry["state"] as? String, !state.isEmpty else {
                    throw SimctlError.malformedResponse(
                        (["list", "-j", "devices"] + extra).joined(separator: " "),
                        "a device entry in '\(runtime)' is missing its UDID, name, or state")
                }
                result.append(Device(
                    udid: udid,
                    name: name,
                    state: state,
                    runtime: runtime,
                    isAvailable: entry["isAvailable"] as? Bool ?? true))
            }
        }
        return result.sorted { $0.udid < $1.udid }
    }

    public func create(name: String, deviceTypeID: String, runtimeID: String) throws -> String {
        let result = try runChecked(["create", name, deviceTypeID, runtimeID])
        let udid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else {
            throw SimctlError.malformedResponse("create", "expected a non-empty simulator UDID")
        }
        return udid
    }

    public func deleteChecked(_ udid: String) throws {
        let arguments = ["delete", udid]
        let result = try runner.run(["xcrun", "simctl"] + arguments)
        if result.status != 0, !result.indicatesMissingDevice {
            try check(result, for: arguments)
        }
    }

    public func shutdownChecked(_ udid: String) throws {
        let arguments = ["shutdown", udid]
        let result = try runner.run(["xcrun", "simctl"] + arguments)
        if result.status != 0,
           !result.indicatesAlreadyShutdown,
           !result.indicatesMissingDevice {
            try check(result, for: arguments)
        }
    }

    public func bootChecked(_ udid: String) throws {
        try runChecked(["boot", udid])
    }

    public func bootAndWait(_ udid: String) throws {
        let bootArguments = ["boot", udid]
        let bootResult = try runner.run(["xcrun", "simctl"] + bootArguments)
        if bootResult.status != 0, !bootResult.indicatesAlreadyBooted {
            try check(bootResult, for: bootArguments)
        }
        try runChecked(["bootstatus", udid, "-b"])
    }

    @discardableResult
    public func delete(_ udid: String) -> Bool {
        reportNonFatalFailure {
            try deleteChecked(udid)
        }
    }

    @discardableResult
    public func shutdown(_ udid: String) -> Bool {
        reportNonFatalFailure {
            try shutdownChecked(udid)
        }
    }

    @discardableResult
    public func boot(_ udid: String) -> Bool {
        reportNonFatalFailure {
            try bootChecked(udid)
        }
    }

    @discardableResult
    public func rename(_ udid: String, to name: String) -> Bool {
        reportNonFatalFailure {
            try runChecked(["rename", udid, name])
        }
    }

    public func preferredDeviceType(from preferred: [String]) throws -> (name: String, id: String)? {
        let list: [[String: Any]] = try listValue("devicetypes", key: "devicetypes")
        var byName: [String: String] = [:]
        for deviceType in list {
            if let name = deviceType["name"] as? String, let id = deviceType["identifier"] as? String {
                byName[name] = id
            }
        }
        for name in preferred {
            if let id = byName[name] { return (name, id) }
        }
        for deviceType in list {
            if let name = deviceType["name"] as? String, name.contains("iPhone"),
               let id = deviceType["identifier"] as? String {
                return (name, id)
            }
        }
        return nil
    }

    public func latestIOSRuntime() throws -> String? {
        let list: [[String: Any]] = try listValue("runtimes", key: "runtimes")
        return list
            .filter {
                ($0["isAvailable"] as? Bool ?? false) && ($0["name"] as? String ?? "").hasPrefix("iOS")
            }
            .sorted {
                ($0["version"] as? String ?? "").compare(
                    $1["version"] as? String ?? "", options: .numeric) == .orderedDescending
            }
            .first?["identifier"] as? String
    }

    private func reportNonFatalFailure(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            FileHandle.standardError.write(
                Data("simlease: \(error) (non-fatal)\n".utf8))
            return false
        }
    }
}

private extension ProcessResult {
    var combinedOutput: String {
        (stdout + "\n" + stderr).lowercased()
    }

    var indicatesAlreadyBooted: Bool {
        combinedOutput.contains("current state: booted") || combinedOutput.contains("already booted")
    }

    var indicatesAlreadyShutdown: Bool {
        combinedOutput.contains("current state: shutdown") || combinedOutput.contains("already shutdown")
    }

    var indicatesMissingDevice: Bool {
        combinedOutput.contains("invalid device")
            || combinedOutput.contains("unable to find device")
            || combinedOutput.contains("device not found")
    }
}

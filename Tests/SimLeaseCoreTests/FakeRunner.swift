import Foundation
@testable import SimLeaseCore

final class FakeRunner: ProcessRunner, @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake-runner")
    private var _responses: [String: ProcessResult] = [:]
    private var _calls: [[String]] = []
    private var _runHook: (([String]) -> Void)?

    var responses: [String: ProcessResult] {
        get { queue.sync { _responses } }
        set { queue.sync { _responses = newValue } }
    }

    var calls: [[String]] { queue.sync { _calls } }

    func setResponse(_ prefix: String, _ result: ProcessResult) {
        queue.sync { _responses[prefix] = result }
    }

    func setRunHook(_ hook: @escaping ([String]) -> Void) {
        queue.sync { _runHook = hook }
    }

    func run(_ arguments: [String]) throws -> ProcessResult {
        let snapshot = queue.sync {
            _calls.append(arguments)
            return (responses: _responses, runHook: _runHook)
        }
        snapshot.runHook?(arguments)
        let key = arguments.joined(separator: " ")
        for (prefix, result) in snapshot.responses where key.hasPrefix(prefix) {
            return result
        }
        return ProcessResult(status: 0, stdout: "", stderr: "")
    }
}

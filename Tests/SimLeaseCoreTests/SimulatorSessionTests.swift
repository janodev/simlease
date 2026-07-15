import Foundation
@testable import SimLeaseCore
import Testing

@Suite(.serialized)
struct SimulatorSessionTests {
    final class Fixture {
        let directory: URL
        var now = Date(timeIntervalSince1970: 2_000_000)
        let runner = FakeRunner()

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            stubDevices([])
            runner.setResponse(
                "xcrun simctl list -j devicetypes",
                ProcessResult(
                    status: 0,
                    stdout: #"{"devicetypes":[{"name":"iPhone 17 Pro","identifier":"dt-17"}]}"#,
                    stderr: ""))
            runner.setResponse(
                "xcrun simctl list -j runtimes",
                ProcessResult(
                    status: 0,
                    stdout: """
                    {"runtimes":[{"identifier":"rt-27","name":"iOS 27.0",\
                    "version":"27.0","isAvailable":true}]}
                    """,
                    stderr: ""))
            runner.setResponse(
                "xcrun simctl create",
                ProcessResult(status: 0, stdout: "SESSION-1\n", stderr: ""))
        }

        var paths: SimLeasePaths {
            SimLeasePaths(
                registry: directory.appendingPathComponent("registry.json"),
                lock: directory.appendingPathComponent("registry.lock"),
                deviceLocks: directory.appendingPathComponent("device-locks"))
        }

        func allocator() -> Allocator {
            Allocator(
                simctl: Simctl(runner: runner),
                paths: paths,
                now: { self.now })
        }

        func manager() -> SessionManager {
            SessionManager(
                simctl: Simctl(runner: runner),
                paths: paths,
                now: { self.now })
        }

        func request() -> SessionRequest {
            SessionRequest(
                label: "session-test",
                agent: "codex",
                workdir: directory.path,
                deviceName: "iPhone 17 Pro")
        }

        func stubDevices(_ devices: [(udid: String, name: String, state: String)]) {
            let entries = devices.map { device in
                "{\"udid\":\"\(device.udid)\",\"name\":\"\(device.name)\","
                    + "\"state\":\"\(device.state)\",\"isAvailable\":true}"
            }.joined(separator: ",")
            let json = "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-0\":[\(entries)]}}"
            runner.setResponse(
                "xcrun simctl list -j devices",
                ProcessResult(status: 0, stdout: json, stderr: ""))
        }
    }

    @Test
    func sessionCreatesPrivateSimulatorAndDeletesItOnFinish() throws {
        let fixture = try Fixture()
        let session = try fixture.manager().start(fixture.request())

        #expect(session.udid == "SESSION-1")
        let lease = try #require(RegistryStore.load(at: fixture.paths.registry).leases[session.udid])
        #expect(lease.created)
        #expect(lease.sessionID == session.id)
        #expect(lease.sessionState == .created)
        #expect(lease.workdir == fixture.directory.path)
        #expect(
            Allocator.lockedName(for: lease)
                == "🔒 session-test [\(session.id.prefix(8))] · iPhone 17 Pro")
        #expect(fixture.runner.calls.contains { call in
            call.prefix(4) == ["xcrun", "simctl", "create", "🔒 session-test [\(session.id.prefix(8))] · iPhone 17 Pro"]
        })

        try session.transition(to: .running)
        #expect(try RegistryStore.load(
            at: fixture.paths.registry).leases[session.udid]?.sessionState == .running)

        try session.finish()

        #expect(try RegistryStore.load(at: fixture.paths.registry).leases.isEmpty)
        #expect(fixture.runner.calls.contains(["xcrun", "simctl", "shutdown", "SESSION-1"]))
        #expect(fixture.runner.calls.contains(["xcrun", "simctl", "delete", "SESSION-1"]))
    }

    @Test
    func activeSessionCannotExpireOrBeReleasedExternally() throws {
        let fixture = try Fixture()
        let session = try fixture.manager().start(fixture.request())
        fixture.now = fixture.now.addingTimeInterval(10_000)
        fixture.stubDevices([(
            udid: session.udid,
            name: "🔒 session-test · iPhone 17 Pro",
            state: "Booted")])

        #expect(try fixture.allocator().gc().isEmpty)
        do {
            _ = try fixture.allocator().release(workdir: nil, udid: session.udid, label: nil)
            Issue.record("Expected an active session release to fail")
        } catch let error as AllocatorError {
            guard case .activeSession(let udid) = error else {
                Issue.record("Unexpected allocator error: \(error)")
                return
            }
            #expect(udid == session.udid)
        }

        try session.finish()
    }

    @Test
    func sameWorkdirCanOwnIndependentSessions() throws {
        let fixture = try Fixture()
        let first = try fixture.manager().start(fixture.request())
        fixture.runner.setResponse(
            "xcrun simctl create",
            ProcessResult(status: 0, stdout: "SESSION-2\n", stderr: ""))
        let second = try fixture.manager().start(fixture.request())

        #expect(first.id != second.id)
        #expect(first.udid != second.udid)
        #expect(try RegistryStore.load(at: fixture.paths.registry).leases.count == 2)

        try first.finish()
        try second.finish()
    }

    @Test
    func abandonedSessionIsDeleteOnlyGarbageCollected() throws {
        let fixture = try Fixture()
        var session: SimulatorSession? = try fixture.manager().start(fixture.request())
        let udid = try #require(session?.udid)
        session = nil
        fixture.stubDevices([(
            udid: udid,
            name: "🔒 abandoned · iPhone 17 Pro",
            state: "Shutdown")])

        #expect(try fixture.allocator().gc() == [udid])
        #expect(fixture.runner.calls.contains(["xcrun", "simctl", "delete", udid]))
        #expect(try RegistryStore.load(at: fixture.paths.registry).leases.isEmpty)
    }

    @Test
    func failedCleanupRetainsOwnershipMetadataForRetry() throws {
        let fixture = try Fixture()
        let session = try fixture.manager().start(fixture.request())
        fixture.runner.setResponse(
            "xcrun simctl delete SESSION-1",
            ProcessResult(status: 70, stdout: "", stderr: "busy"))

        do {
            try session.finish()
            Issue.record("Expected cleanup to fail")
        } catch {
            let lease = try #require(
                RegistryStore.load(at: fixture.paths.registry).leases[session.udid])
            #expect(lease.sessionState == .quarantined)
            #expect(lease.sessionFailure?.contains("busy") == true)
        }

        fixture.runner.setResponse(
            "xcrun simctl delete SESSION-1",
            ProcessResult(status: 0, stdout: "", stderr: ""))
        try session.finish()
        #expect(try RegistryStore.load(at: fixture.paths.registry).leases.isEmpty)
    }

    @Test
    func failedAbandonedCleanupRemainsQuarantined() throws {
        let fixture = try Fixture()
        var session: SimulatorSession? = try fixture.manager().start(fixture.request())
        let udid = try #require(session?.udid)
        session = nil
        fixture.stubDevices([(
            udid: udid,
            name: "🔒 abandoned · iPhone 17 Pro",
            state: "Shutdown")])
        fixture.runner.setResponse(
            "xcrun simctl delete SESSION-1",
            ProcessResult(status: 70, stdout: "", stderr: "busy"))

        #expect(try fixture.allocator().gc().isEmpty)
        let lease = try #require(RegistryStore.load(at: fixture.paths.registry).leases[udid])
        #expect(lease.sessionState == .quarantined)
        #expect(lease.sessionFailure?.contains("automatic cleanup failed") == true)
    }
}

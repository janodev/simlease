import XCTest
@testable import SimLeaseCore

final class SimctlTests: XCTestCase {
    func testDevicesParsesFlattenedList() throws {
        let json = """
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
            {"udid": "AAA", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true},
            {"udid": "BBB", "name": "iPhone 16 Pro", "state": "Shutdown", "isAvailable": true}
        ]}}
        """
        let runner = FakeRunner()
        runner.setResponse("xcrun simctl list -j devices",
                           ProcessResult(status: 0, stdout: json, stderr: ""))
        let devices = try Simctl(runner: runner).devices(availableOnly: false)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first(where: { $0.udid == "AAA" })?.state, "Booted")
    }

    func testCreateReturnsTrimmedUDID() throws {
        let runner = FakeRunner()
        runner.setResponse("xcrun simctl create",
                           ProcessResult(status: 0, stdout: "NEW-UDID\n", stderr: ""))
        let udid = try Simctl(runner: runner)
            .create(name: "X", deviceTypeID: "dt", runtimeID: "rt")
        XCTAssertEqual(udid, "NEW-UDID")
    }

    func testCreateRejectsEmptyUDID() {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl create",
            ProcessResult(status: 0, stdout: "\n", stderr: ""))

        XCTAssertThrowsError(
            try Simctl(runner: runner).create(name: "X", deviceTypeID: "dt", runtimeID: "rt")) {
                XCTAssertTrue(String(describing: $0).contains("expected a non-empty simulator UDID"))
            }
    }

    func testLatestIOSRuntimePicksHighestVersion() throws {
        let json = """
        {"runtimes": [
            {"identifier": "old", "name": "iOS 17.5", "version": "17.5", "isAvailable": true},
            {"identifier": "new", "name": "iOS 26.0", "version": "26.0", "isAvailable": true},
            {"identifier": "tv", "name": "tvOS 26.0", "version": "26.0", "isAvailable": true}
        ]}
        """
        let runner = FakeRunner()
        runner.setResponse("xcrun simctl list -j runtimes",
                           ProcessResult(status: 0, stdout: json, stderr: ""))
        XCTAssertEqual(try Simctl(runner: runner).latestIOSRuntime(), "new")
    }

    func testPreferredDeviceTypePicksFirstMatch() throws {
        let json = """
        {"devicetypes": [
            {"name": "iPhone 15 Pro", "identifier": "dt-15"},
            {"name": "iPhone 17 Pro", "identifier": "dt-17"}
        ]}
        """
        let runner = FakeRunner()
        runner.setResponse("xcrun simctl list -j devicetypes",
                           ProcessResult(status: 0, stdout: json, stderr: ""))
        let result = try Simctl(runner: runner)
            .preferredDeviceType(from: ["iPhone 17 Pro", "iPhone 16 Pro"])
        XCTAssertEqual(result?.id, "dt-17")
    }

    func testListRejectsNonzeroExitStatus() {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl list -j devices",
            ProcessResult(status: 72, stdout: #"{"devices": {}}"#, stderr: "service unavailable\n"))

        XCTAssertThrowsError(try Simctl(runner: runner).devices(availableOnly: false)) { error in
            XCTAssertEqual(
                String(describing: error),
                "simctl list -j devices failed: exit status 72: service unavailable")
        }
    }

    func testListRejectsInvalidJSON() {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl list -j runtimes",
            ProcessResult(status: 0, stdout: "not-json", stderr: ""))

        XCTAssertThrowsError(try Simctl(runner: runner).latestIOSRuntime()) { error in
            XCTAssertTrue(String(describing: error).contains("returned a malformed response"))
            XCTAssertTrue(String(describing: error).contains("invalid JSON"))
        }
    }

    func testListRejectsUnexpectedDocumentShape() {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl list -j devicetypes",
            ProcessResult(status: 0, stdout: #"{"devicetypes": {}}"#, stderr: ""))

        XCTAssertThrowsError(try Simctl(runner: runner).preferredDeviceType(from: [])) { error in
            XCTAssertTrue(String(describing: error).contains("expected 'devicetypes'"))
        }
    }

    func testDevicesRejectsEntryWithoutUDID() {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl list -j devices",
            ProcessResult(
                status: 0,
                stdout: #"{"devices":{"iOS-26-0":[{"name":"iPhone 17 Pro","state":"Shutdown"}]}}"#,
                stderr: ""))

        XCTAssertThrowsError(try Simctl(runner: runner).devices(availableOnly: false)) { error in
            XCTAssertTrue(String(describing: error).contains("missing its UDID, name, or state"))
        }
    }

    func testBootAndWaitChecksBothCommands() throws {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl boot DEVICE",
            ProcessResult(status: 0, stdout: "", stderr: ""))
        runner.setResponse(
            "xcrun simctl bootstatus DEVICE -b",
            ProcessResult(status: 0, stdout: "Finished\n", stderr: ""))

        try Simctl(runner: runner).bootAndWait("DEVICE")

        XCTAssertEqual(runner.calls, [
            ["xcrun", "simctl", "boot", "DEVICE"],
            ["xcrun", "simctl", "bootstatus", "DEVICE", "-b"],
        ])
    }

    func testBootAndWaitStopsWhenBootFails() {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl boot DEVICE",
            ProcessResult(status: 149, stdout: "", stderr: "boot refused"))

        XCTAssertThrowsError(try Simctl(runner: runner).bootAndWait("DEVICE")) { error in
            XCTAssertEqual(
                String(describing: error),
                "simctl boot DEVICE failed: exit status 149: boot refused")
        }
        XCTAssertEqual(runner.calls, [["xcrun", "simctl", "boot", "DEVICE"]])
    }

    func testBootAndWaitAcceptsAlreadyBootedDevice() throws {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl boot DEVICE",
            ProcessResult(
                status: 149,
                stdout: "",
                stderr: "Unable to boot device in current state: Booted"))
        runner.setResponse(
            "xcrun simctl bootstatus DEVICE -b",
            ProcessResult(status: 0, stdout: "Finished\n", stderr: ""))

        try Simctl(runner: runner).bootAndWait("DEVICE")

        XCTAssertEqual(runner.calls, [
            ["xcrun", "simctl", "boot", "DEVICE"],
            ["xcrun", "simctl", "bootstatus", "DEVICE", "-b"],
        ])
    }

    func testBootAndWaitReportsBootstatusFailure() {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl boot DEVICE",
            ProcessResult(status: 0, stdout: "", stderr: ""))
        runner.setResponse(
            "xcrun simctl bootstatus DEVICE -b",
            ProcessResult(status: 60, stdout: "", stderr: "timed out"))

        XCTAssertThrowsError(try Simctl(runner: runner).bootAndWait("DEVICE")) { error in
            XCTAssertEqual(
                String(describing: error),
                "simctl bootstatus DEVICE -b failed: exit status 60: timed out")
        }
    }

    func testCheckedLifecycleOperationsThrow() {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl shutdown DEVICE",
            ProcessResult(status: 70, stdout: "", stderr: "shutdown failed"))
        runner.setResponse(
            "xcrun simctl delete DEVICE",
            ProcessResult(status: 71, stdout: "", stderr: "delete failed"))
        let simctl = Simctl(runner: runner)

        XCTAssertThrowsError(try simctl.shutdownChecked("DEVICE"))
        XCTAssertThrowsError(try simctl.deleteChecked("DEVICE"))
    }

    func testShutdownCheckedAcceptsAlreadyShutdownDevice() throws {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl shutdown DEVICE",
            ProcessResult(
                status: 149,
                stdout: "",
                stderr: "Unable to shutdown device in current state: Shutdown"))

        try Simctl(runner: runner).shutdownChecked("DEVICE")
    }

    func testDeleteCheckedAcceptsVanishedDevice() throws {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl delete DEVICE",
            ProcessResult(status: 2, stdout: "", stderr: "Invalid device: DEVICE"))

        try Simctl(runner: runner).deleteChecked("DEVICE")
    }

    func testCompatibilityLifecycleOperationsReturnFailure() {
        let runner = FakeRunner()
        runner.setResponse(
            "xcrun simctl shutdown DEVICE",
            ProcessResult(status: 70, stdout: "", stderr: "shutdown failed"))
        runner.setResponse(
            "xcrun simctl delete DEVICE",
            ProcessResult(status: 71, stdout: "", stderr: "delete failed"))
        runner.setResponse(
            "xcrun simctl rename DEVICE New Name",
            ProcessResult(status: 72, stdout: "", stderr: "rename failed"))
        let simctl = Simctl(runner: runner)

        XCTAssertFalse(simctl.shutdown("DEVICE"))
        XCTAssertFalse(simctl.delete("DEVICE"))
        XCTAssertFalse(simctl.rename("DEVICE", to: "New Name"))
    }

    func testCompatibilityLifecycleOperationsReturnSuccess() {
        let simctl = Simctl(runner: FakeRunner())

        XCTAssertTrue(simctl.boot("DEVICE"))
        XCTAssertTrue(simctl.shutdown("DEVICE"))
        XCTAssertTrue(simctl.delete("DEVICE"))
        XCTAssertTrue(simctl.rename("DEVICE", to: "New Name"))
    }
}

@testable import SimLeaseCore
import XCTest

final class RegistryTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func testLoadMissingFileReturnsEmptyRegistry() throws {
        let reg = try RegistryStore.load(at: dir.appendingPathComponent("registry.json"))
        XCTAssertEqual(reg.schema, 1)
        XCTAssertTrue(reg.leases.isEmpty)
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = dir.appendingPathComponent("registry.json")
        var reg = Registry.empty
        reg.leases["UDID-1"] = Lease(
            label: "APP-1 checkout", agent: "claude-code", workdir: "/tmp/wt",
            originalName: "iPhone 17 Pro", renamed: true, created: false,
            claimedAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_007_200))
        try RegistryStore.save(reg, to: url)
        XCTAssertEqual(try RegistryStore.load(at: url), reg)
    }

    func testSavedJSONUsesSnakeCase() throws {
        let url = dir.appendingPathComponent("registry.json")
        var reg = Registry.empty
        reg.leases["U"] = Lease(
            label: "x", agent: "a", workdir: "/w", originalName: "iPhone",
            renamed: false, created: true, claimedAt: Date(), expiresAt: Date())
        try RegistryStore.save(reg, to: url)
        let text = try String(contentsOf: url)
        XCTAssertTrue(text.contains("original_name"))
        XCTAssertTrue(text.contains("expires_at"))
    }

    func testCorruptFileIsBackedUpAndFailsClosed() throws {
        let url = dir.appendingPathComponent("registry.json")
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RegistryStore.load(at: url)) { error in
            guard case RegistryError.corrupt(let path) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, url.path)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{not json")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.path + ".corrupt"))
        XCTAssertThrowsError(try RegistryStore.load(at: url))
    }

    func testUnsupportedSchemaThrows() throws {
        let url = dir.appendingPathComponent("registry.json")
        try #"{"schema": 99, "leases": {}}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RegistryStore.load(at: url))
    }
}

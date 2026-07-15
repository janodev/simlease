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
        XCTAssertEqual(reg.schema, Registry.currentSchema)
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
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("original_name"))
        XCTAssertTrue(text.contains("expires_at"))
        XCTAssertTrue(text.contains(#""schema" : 2"#))
    }

    func testSchemaOneRegistryMigratesAndSavesAsSchemaTwo() throws {
        let url = dir.appendingPathComponent("registry.json")
        let legacyRegistry = """
        {
          "schema": 1,
          "leases": {
            "LEGACY-UDID": {
              "agent": "legacy-agent",
              "claimed_at": "2001-01-01T00:00:00Z",
              "created": false,
              "expires_at": "2001-01-01T02:00:00Z",
              "label": "legacy lease",
              "original_name": "iPhone 17 Pro",
              "renamed": true,
              "workdir": "/tmp/legacy"
            }
          }
        }
        """
        try legacyRegistry.write(to: url, atomically: true, encoding: .utf8)

        let migrated = try RegistryStore.load(at: url)

        XCTAssertEqual(migrated.schema, Registry.currentSchema)
        let lease = try XCTUnwrap(migrated.leases["LEGACY-UDID"])
        XCTAssertEqual(lease.agent, "legacy-agent")
        XCTAssertNil(lease.sessionID)
        XCTAssertNil(lease.sessionState)
        try RegistryStore.save(migrated, to: url)
        let savedText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(savedText.contains(#""schema" : 2"#))
        XCTAssertEqual(try RegistryStore.load(at: url), migrated)
    }

    func testSaveAlwaysWritesCurrentSchema() throws {
        let url = dir.appendingPathComponent("registry.json")
        try RegistryStore.save(Registry(schema: 1, leases: [:]), to: url)

        let stored = try RegistryStore.load(at: url)

        XCTAssertEqual(stored.schema, Registry.currentSchema)
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

    func testSchemaZeroThrows() throws {
        let url = dir.appendingPathComponent("registry.json")
        try #"{"schema": 0, "leases": {}}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RegistryStore.load(at: url))
    }
}

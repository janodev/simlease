import Foundation
@testable import SimLeaseCore
import Testing

@Suite("Registry failure handling")
struct RegistryFailureTests {
    @Test
    func existingUnreadablePathNeverLooksLikeAnEmptyRegistry() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let registry = directory.appendingPathComponent("registry.json")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try RegistryStore.load(at: registry)
            Issue.record("Expected an existing unreadable registry path to fail closed")
        } catch let error as RegistryError {
            guard case .unreadable(let path, _) = error else {
                Issue.record("Unexpected registry error: \(error)")
                return
            }
            #expect(path == registry.path)
        }
    }

    @Test
    func invalidParentPathNeverLooksLikeAMissingRegistry() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidParent = directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: invalidParent)
        let registry = invalidParent.appendingPathComponent("registry.json")

        do {
            _ = try RegistryStore.load(at: registry)
            Issue.record("Expected an invalid parent path to fail closed")
        } catch let error as RegistryError {
            guard case .unreadable(let path, _) = error else {
                Issue.record("Unexpected registry error: \(error)")
                return
            }
            #expect(path == registry.path)
        }
    }
}

import Darwin
import Foundation

public enum SessionState: String, Codable, Equatable, Sendable {
    case booting
    case cleaning
    case created
    case quarantined
    case running
}

public struct Lease: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case agent
        case claimedAt
        case created
        case expiresAt
        case label
        case originalName
        case renamed
        case sessionFailure
        case sessionID = "sessionId"
        case sessionState
        case workdir
    }

    public var label: String
    public var agent: String
    public var workdir: String
    public var originalName: String
    public var renamed: Bool
    public var created: Bool
    public var sessionFailure: String?
    public var sessionID: String?
    public var sessionState: SessionState?
    public var claimedAt: Date
    public var expiresAt: Date

    public init(label: String, agent: String, workdir: String, originalName: String,
                renamed: Bool, created: Bool, sessionID: String? = nil,
                sessionState: SessionState? = nil, sessionFailure: String? = nil,
                claimedAt: Date, expiresAt: Date) {
        self.label = label
        self.agent = agent
        self.workdir = workdir
        self.originalName = originalName
        self.renamed = renamed
        self.created = created
        self.sessionFailure = sessionFailure
        self.sessionID = sessionID
        self.sessionState = sessionState
        self.claimedAt = claimedAt
        self.expiresAt = expiresAt
    }
}

public struct Registry: Codable, Equatable, Sendable {
    public static let currentSchema = 2

    public var schema: Int
    public var leases: [String: Lease]

    public static let empty = Registry(schema: currentSchema, leases: [:])
}

public enum RegistryError: Error, CustomStringConvertible {
    case corrupt(String)
    case unreadable(String, String)
    case unsupportedSchema(Int)

    public var description: String {
        switch self {
        case .corrupt(let path):
            return "registry at \(path) is corrupt; original retained and allocation blocked"
        case .unreadable(let path, let detail):
            return "registry at \(path) is unreadable; allocation blocked: \(detail)"
        case .unsupportedSchema(let version):
            return "registry schema \(version) is unsupported by this version of simlease"
        }
    }
}

public enum RegistryStore {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func load(at url: URL) throws -> Registry {
        guard var registry = try loadStored(at: url) else { return .empty }
        registry.schema = Registry.currentSchema
        return registry
    }

    static func migrateIfNeeded(
        at url: URL,
        legacyLock legacyLockURL: URL,
        timeout: TimeInterval = 20
    ) throws {
        if try loadStored(at: url)?.schema == Registry.currentSchema {
            return
        }

        let legacyLock = LegacyMigrationLock(path: legacyLockURL)
        try legacyLock.acquire(timeout: timeout)
        defer { legacyLock.release() }

        let storedRegistry = try loadStored(at: url)
        guard storedRegistry?.schema != Registry.currentSchema else { return }
        var registry = storedRegistry ?? .empty
        registry.schema = Registry.currentSchema
        try legacyLock.refreshTimestamp()
        try save(registry, to: url)
    }

    private static func loadStored(at url: URL) throws -> Registry? {
        guard try pathExists(at: url) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RegistryError.unreadable(url.path, error.localizedDescription)
        }
        do {
            let registry = try decoder.decode(Registry.self, from: data)
            guard (1 ... Registry.currentSchema).contains(registry.schema) else {
                throw RegistryError.unsupportedSchema(registry.schema)
            }
            return registry
        } catch let error as RegistryError {
            throw error
        } catch {
            let backupPath = url.path + ".corrupt"
            try? FileManager.default.removeItem(atPath: backupPath)
            try? FileManager.default.copyItem(atPath: url.path, toPath: backupPath)
            FileHandle.standardError.write(Data(
                "simlease: registry is corrupt; original retained and allocation blocked\n".utf8))
            throw RegistryError.corrupt(url.path)
        }
    }

    public static func save(_ registry: Registry, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var currentRegistry = registry
        currentRegistry.schema = Registry.currentSchema
        let data = try encoder.encode(currentRegistry)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private static func pathExists(at url: URL) throws -> Bool {
        var information = stat()
        var failure = EINVAL
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            let result = lstat(path, &information)
            if result != 0 { failure = errno }
            return result
        }
        if result == 0 { return true }
        if failure == ENOENT { return false }
        throw RegistryError.unreadable(url.path, String(cString: strerror(failure)))
    }
}

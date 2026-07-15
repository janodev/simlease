import Foundation

public enum SessionState: String, Codable, Equatable {
    case booting
    case cleaning
    case created
    case quarantined
    case running
}

public struct Lease: Codable, Equatable {
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

public struct Registry: Codable, Equatable {
    public var schema: Int
    public var leases: [String: Lease]

    public static let empty = Registry(schema: 1, leases: [:])
}

public enum RegistryError: Error, CustomStringConvertible {
    case corrupt(String)
    case unsupportedSchema(Int)

    public var description: String {
        switch self {
        case .corrupt(let path):
            return "registry at \(path) is corrupt; original retained and allocation blocked"
        case .unsupportedSchema(let version):
            return "registry schema \(version) is newer than this simlease understands — upgrade simlease"
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
        guard let data = try? Data(contentsOf: url) else { return .empty }
        do {
            let registry = try decoder.decode(Registry.self, from: data)
            guard registry.schema <= 1 else { throw RegistryError.unsupportedSchema(registry.schema) }
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
        let data = try encoder.encode(registry)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

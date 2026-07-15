import Foundation

enum RegistryTransaction {
    static func withLock<Result>(
        paths: SimLeasePaths,
        migrationTimeout: TimeInterval = 20,
        _ body: () throws -> Result
    ) throws -> Result {
        let lock = FileLock(path: paths.lock)
        try lock.acquire()
        defer { lock.release() }

        try RegistryStore.migrateIfNeeded(
            at: paths.registry,
            legacyLock: paths.legacyLock,
            timeout: migrationTimeout
        )
        return try body()
    }
}

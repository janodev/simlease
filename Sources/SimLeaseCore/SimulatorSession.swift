import Foundation

public struct SessionRequest {
    public var agent: String
    public var deviceName: String?
    public var label: String
    public var workdir: String

    public init(label: String, agent: String, workdir: String, deviceName: String? = nil) {
        self.agent = agent
        self.deviceName = deviceName
        self.label = label
        self.workdir = workdir
    }
}

public enum SimulatorSessionError: Error, CustomStringConvertible {
    case ownershipLost(String)

    public var description: String {
        switch self {
        case .ownershipLost(let udid):
            return "simlease: session ownership metadata was replaced for simulator \(udid)"
        }
    }
}

public final class SimulatorSession {
    public let deviceName: String
    public let id: String
    public let udid: String

    private let deviceLock: FileLock
    private var finished = false
    private let paths: SimLeasePaths
    private let simctl: Simctl

    init(id: String, udid: String, deviceName: String, deviceLock: FileLock,
         paths: SimLeasePaths, simctl: Simctl) {
        self.deviceLock = deviceLock
        self.deviceName = deviceName
        self.id = id
        self.paths = paths
        self.simctl = simctl
        self.udid = udid
    }

    /// Deletes this session's disposable simulator and then releases ownership.
    ///
    /// If cleanup fails, the registry entry and kernel lock remain in place so
    /// another claimant cannot mistake the simulator for a reusable device.
    public func finish() throws {
        guard !finished else { return }

        try mutateRegistry { registry in
            guard var lease = registry.leases[udid] else { return false }
            guard lease.sessionID == id else {
                throw SimulatorSessionError.ownershipLost(udid)
            }
            lease.sessionFailure = nil
            lease.sessionState = .cleaning
            registry.leases[udid] = lease
            return true
        }

        do {
            try simctl.shutdownChecked(udid)
            try simctl.deleteChecked(udid)
        } catch {
            try? mutateRegistry { registry in
                guard var lease = registry.leases[udid], lease.sessionID == id else {
                    return false
                }
                lease.sessionFailure = String(describing: error)
                lease.sessionState = .quarantined
                registry.leases[udid] = lease
                return true
            }
            throw error
        }

        try mutateRegistry { registry in
            guard let lease = registry.leases[udid] else { return false }
            guard lease.sessionID == id else {
                throw SimulatorSessionError.ownershipLost(udid)
            }
            registry.leases.removeValue(forKey: udid)
            return true
        }
        finished = true
        deviceLock.release()
    }

    public func transition(to state: SessionState) throws {
        guard !finished else { return }

        try RegistryTransaction.withLock(paths: paths) {
            var registry = try RegistryStore.load(at: paths.registry)
            guard var lease = registry.leases[udid], lease.sessionID == id else {
                throw SimulatorSessionError.ownershipLost(udid)
            }
            lease.sessionFailure = nil
            lease.sessionState = state
            registry.leases[udid] = lease
            try RegistryStore.save(registry, to: paths.registry)
        }
    }

    deinit {
        deviceLock.release()
    }

    private func mutateRegistry(_ mutation: (inout Registry) throws -> Bool) throws {
        try RegistryTransaction.withLock(paths: paths) {
            var registry = try RegistryStore.load(at: paths.registry)
            if try mutation(&registry) {
                try RegistryStore.save(registry, to: paths.registry)
            }
        }
    }
}

public struct SessionManager {
    private let now: () -> Date
    private let paths: SimLeasePaths
    private let preferred: [String]
    private let simctl: Simctl

    public init(simctl: Simctl = Simctl(), paths: SimLeasePaths = .default(),
                preferred: [String] = Allocator.defaultPreferred,
                now: @escaping () -> Date = { Date() }) {
        self.now = now
        self.paths = paths
        self.preferred = preferred
        self.simctl = simctl
    }

    /// Creates a private simulator and keeps its per-device lock for the
    /// returned session's entire lifetime. Sessions never reuse pooled devices.
    public func start(_ request: SessionRequest) throws -> SimulatorSession {
        try RegistryTransaction.withLock(paths: paths) {
            var registry = try RegistryStore.load(at: paths.registry)
            let allocator = Allocator(
                simctl: simctl,
                paths: paths,
                preferred: preferred,
                now: now)
            let present = try simctl.devices(availableOnly: false)
            let registryBeforeReap = registry
            _ = allocator.reap(&registry, present: present)
            if registry != registryBeforeReap {
                try RegistryStore.save(registry, to: paths.registry)
            }

            let requestedNames = request.deviceName.map { [$0] } ?? preferred
            guard let deviceType = try simctl.preferredDeviceType(
                from: requestedNames,
                allowFallback: request.deviceName == nil),
                  let runtimeID = try simctl.latestIOSRuntime(supporting: deviceType.id) else {
                throw AllocatorError.noDeviceAvailable("no matching device type or iOS runtime found")
            }

            let id = UUID().uuidString
            let shortID = String(id.prefix(8))
            let displayLabel = "\(request.label) [\(shortID)]"
            let displayName = Allocator.lockedName(label: displayLabel, original: deviceType.name)
            let udid = try simctl.create(
                name: displayName,
                deviceTypeID: deviceType.id,
                runtimeID: runtimeID)
            let deviceLock = FileLock(path: paths.deviceLock(for: udid))

            do {
                try deviceLock.acquire(timeout: 0)
                registry.leases[udid] = Lease(
                    label: request.label,
                    agent: request.agent,
                    workdir: request.workdir,
                    originalName: deviceType.name,
                    renamed: true,
                    created: true,
                    sessionID: id,
                    sessionState: .created,
                    claimedAt: now(),
                    expiresAt: now().addingTimeInterval(7200))
                try RegistryStore.save(registry, to: paths.registry)
            } catch {
                deviceLock.release()
                try? simctl.shutdownChecked(udid)
                try? simctl.deleteChecked(udid)
                throw error
            }

            return SimulatorSession(
                id: id,
                udid: udid,
                deviceName: deviceType.name,
                deviceLock: deviceLock,
                paths: paths,
                simctl: simctl)
        }
    }
}

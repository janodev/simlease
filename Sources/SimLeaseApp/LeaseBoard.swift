import Foundation
import Observation
import SimLeaseCore

struct BoardRow: Equatable, Identifiable, Sendable {
    let id: String
    let lease: Lease
    let booted: Bool
    let expired: Bool
}

private enum RefreshResult: Sendable {
    case failure(String)
    case success([BoardRow])
}

@MainActor
@Observable
final class LeaseBoard {
    private(set) var cleanupError: String?
    private(set) var rows: [BoardRow] = []
    private(set) var statusError: String?

    @ObservationIgnored private var gcTask: Task<Void, Never>?
    @ObservationIgnored private var gcTimer: Timer?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private let statusLoader: @Sendable () throws -> [BoardRow]
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    init(
        statusLoader: (@Sendable () throws -> [BoardRow])? = nil,
        startAutomatically: Bool = true
    ) {
        self.statusLoader = statusLoader ?? { try LeaseBoard.loadRows() }
        guard startAutomatically else { return }
        refresh()
        watchRegistry()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        autoGC()
        gcTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoGC() }
        }
    }

    isolated deinit {
        gcTask?.cancel()
        gcTimer?.invalidate()
        refreshTask?.cancel()
        refreshTimer?.invalidate()
        watcher?.cancel()
    }

    func autoGC() {
        performGC()
    }

    func refresh() {
        guard refreshTask == nil else {
            refreshPending = true
            return
        }

        let statusLoader = statusLoader
        refreshTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    return RefreshResult.success(try statusLoader())
                } catch {
                    return RefreshResult.failure(String(describing: error))
                }
            }.value

            guard !Task.isCancelled, let self else { return }
            finishRefresh(result)
        }
    }

    nonisolated private static func loadRows() throws -> [BoardRow] {
        let now = Date()
        return try Allocator().status().map { row in
            BoardRow(
                id: row.udid,
                lease: row.lease,
                booted: row.state == "Booted",
                expired: row.lease.sessionID == nil && row.lease.expiresAt < now
            )
        }
    }

    private func finishRefresh(_ result: RefreshResult) {
        refreshTask = nil
        switch result {
        case .failure(let error):
            statusError = error
        case .success(let rows):
            self.rows = rows
            statusError = nil
        }

        guard refreshPending else { return }
        refreshPending = false
        refresh()
    }

    private func watchRegistry() {
        let url = SimLeasePaths.default().registry.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    func focus(_ row: BoardRow) {
        let title = row.lease.renamed
            ? Allocator.lockedName(for: row.lease)
            : row.lease.originalName
        Focus.bringToFront(udid: row.id, deviceDisplayName: title)
    }

    func release(_ row: BoardRow) {
        do {
            _ = try Allocator().release(workdir: nil, udid: row.id, label: nil)
            cleanupError = nil
        } catch {
            cleanupError = String(describing: error)
        }
        refresh()
    }

    func runGC() {
        performGC()
    }

    private func performGC() {
        guard gcTask == nil else { return }
        gcTask = Task { [weak self] in
            let failure = await Task.detached(priority: .utility) {
                do {
                    _ = try Allocator().gc()
                    return nil as String?
                } catch {
                    return String(describing: error)
                }
            }.value

            guard let self else { return }
            gcTask = nil
            cleanupError = failure
            refresh()
        }
    }
}

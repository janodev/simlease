import Foundation
import Observation
import SimLeaseCore

struct BoardRow: Equatable, Identifiable {
    let id: String
    let lease: Lease
    let booted: Bool
    let expired: Bool
}

@MainActor
@Observable
final class LeaseBoard {
    private(set) var cleanupError: String?
    private(set) var rows: [BoardRow] = []
    private(set) var statusError: String?

    @ObservationIgnored private var gcTask: Task<Void, Never>?
    @ObservationIgnored private var gcTimer: Timer?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    init() {
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

    deinit {
        gcTask?.cancel()
        gcTimer?.invalidate()
        refreshTimer?.invalidate()
        watcher?.cancel()
    }

    func autoGC() {
        performGC()
    }

    func refresh() {
        do {
            let result = try Allocator().status()
            let now = Date()
            rows = result.map { row in
                BoardRow(id: row.udid, lease: row.lease,
                         booted: row.state == "Booted",
                         expired: row.lease.sessionID == nil && row.lease.expiresAt < now)
            }
            statusError = nil
        } catch {
            statusError = String(describing: error)
        }
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

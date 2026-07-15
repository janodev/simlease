import AppKit
import SimLeaseCore
import SwiftUI

@main
struct SimLeaseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var board = LeaseBoard()

    var body: some Scene {
        MenuBarExtra("SimLease", systemImage: "iphone.gen3") {
            if let statusError = board.statusError {
                Menu("Status unavailable", systemImage: "exclamationmark.triangle.fill") {
                    Text(statusError)
                    Button("Copy Error", systemImage: "doc.on.doc") {
                        copy(statusError)
                    }
                }
            }
            if let cleanupError = board.cleanupError {
                Menu("Cleanup needs attention", systemImage: "exclamationmark.triangle.fill") {
                    Text(cleanupError)
                    Button("Copy Error", systemImage: "doc.on.doc") {
                        copy(cleanupError)
                    }
                    Button("Retry Cleanup", systemImage: "arrow.clockwise") {
                        board.runGC()
                    }
                }
            }
            if board.rows.isEmpty {
                Text("No simulators leased")
            }
            ForEach(board.rows) { row in
                Menu {
                    Button("Focus Window", systemImage: "macwindow") {
                        board.focus(row)
                    }
                    Button("Copy UDID", systemImage: "doc.on.doc") {
                        copy(row.id)
                    }
                    Divider()
                    if row.lease.sessionID == nil {
                        Button("Release Lease", systemImage: "lock.open") {
                            board.release(row)
                        }
                    } else if row.lease.sessionState == .quarantined {
                        Button("Retry Cleanup", systemImage: "arrow.clockwise") {
                            board.runGC()
                        }
                    } else {
                        Button("Managed by simlease run") {}
                            .disabled(true)
                    }
                } label: {
                    Text(rowTitle(row))
                }
            }
            Divider()
            Button("Run GC", systemImage: "trash") { board.runGC() }
            Button("Refresh", systemImage: "arrow.clockwise") { board.refresh() }
            Divider()
            Button("Quit SimLease", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .menuBarExtraStyle(.menu)
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func rowTitle(_ row: BoardRow) -> String {
        let dot = row.booted ? "🟢" : "⚪️"
        let expired = row.expired ? " (expired)" : ""
        let session = row.lease.sessionState.map { " [\($0.rawValue)]" } ?? ""
        return "\(dot) \(row.lease.label) — \(row.lease.originalName)\(expired)\(session) · \(row.lease.agent)"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

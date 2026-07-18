import Foundation
import os

/// Jetsam-debugging breadcrumbs. `os_proc_available_memory` reports how much of the process's
/// memory allowance remains before the OS kills it — logging it at each pipeline stage turns a
/// silent jetsam into a console trace that names the eater. Cheap enough to leave in release.
enum MemoryFootprint {
    // Same subsystem as the rest of the app's loggers — a split subsystem means a Console
    // filter on the usual one silently hides every mem[] line.
    private static let logger = Logger(subsystem: "com.continuity.app", category: "mem")

    /// Remaining allowance in MB. Used both for breadcrumbs and to GATE heavy work — heavy
    /// stages must check this and defer instead of trusting that the budget will stretch.
    static var headroomMB: Int { Int(os_proc_available_memory() / 1_048_576) }

    static func breadcrumb(_ label: String) {
        logger.info("mem[\(label, privacy: .public)] \(headroomMB, privacy: .public) MB headroom")
    }
}

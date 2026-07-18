import Foundation
import os

/// Jetsam-debugging breadcrumbs. `os_proc_available_memory` reports how much of the process's
/// memory allowance remains before the OS kills it — logging it at each pipeline stage turns a
/// silent jetsam into a console trace that names the eater. Cheap enough to leave in release.
enum MemoryFootprint {
    // Same subsystem as the rest of the app's loggers — a split subsystem means a Console
    // filter on the usual one silently hides every mem[] line.
    private static let logger = Logger(subsystem: "com.continuity.app", category: "mem")

    static func breadcrumb(_ label: String) {
        let remainingMB = Int(os_proc_available_memory() / 1_048_576)
        logger.info("mem[\(label, privacy: .public)] \(remainingMB, privacy: .public) MB headroom")
    }
}

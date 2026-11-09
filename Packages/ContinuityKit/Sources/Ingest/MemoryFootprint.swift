import Foundation
import ContinuityCore
import os

/// Jetsam-debugging breadcrumbs. `os_proc_available_memory` reports how much of the process's
/// memory allowance remains before the OS kills it — logging it at each pipeline stage turns a
/// silent jetsam into a console trace that names the eater. Cheap enough to leave in release.
///
/// Each sample is also mirrored into `MemoryBudgetRecorder` (RSS via `phys_footprint` when
/// available) so Export Diagnostics Report can show a stem/playback budget card.
enum MemoryFootprint {
    // Same subsystem as the rest of the app's loggers — a split subsystem means a Console
    // filter on the usual one silently hides every mem[] line.
    private static let logger = Logger(subsystem: "com.continuity.app", category: "mem")

    /// Remaining allowance in MB. Used both for breadcrumbs and to GATE heavy work — heavy
    /// stages must check this and defer instead of trusting that the budget will stretch.
    /// Kept on the Darwin `os` API directly (not `ProcessMemory`) so stem headroom gates cannot
    /// go soft if the Core probe is unavailable.
    static var headroomMB: Int { Int(os_proc_available_memory() / 1_048_576) }

    static func breadcrumb(_ label: String) {
        let headroom = headroomMB
        let rss = ProcessMemory.residentMB
        MemoryBudgetRecorder.shared.record(
            MemoryBreadcrumbSample(label: label, headroomMB: headroom, rssMB: rss)
        )
        if let rss {
            logger.info("mem[\(label, privacy: .public)] \(headroom, privacy: .public) MB headroom \(rss, privacy: .public) MB rss")
        } else {
            logger.info("mem[\(label, privacy: .public)] \(headroom, privacy: .public) MB headroom")
        }
    }
}

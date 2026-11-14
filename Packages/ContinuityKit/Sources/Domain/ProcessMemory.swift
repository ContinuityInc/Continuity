import Foundation
import Darwin
import os

/// Live process memory probes for diagnostics breadcrumbs.
///
/// Lives in Domain (iOS-only, Swift 5 language mode) — not ContinuityCore — because
/// `os_proc_available_memory` is `API_UNAVAILABLE(macos)` and `mach_task_self_` is not
/// concurrency-safe under Core's Swift 6 mode. Putting these here keeps
/// `cd Packages/ContinuityCore && swift test` clean on Mac while Ingest / Playback / App
/// (all already Domain clients) share one RSS/headroom reader.
public enum ProcessMemory {
    /// Remaining jetsam allowance (`os_proc_available_memory`) in MB.
    public static var headroomMB: Int {
        Int(os_proc_available_memory() / 1_048_576)
    }

    /// Resident footprint (`task_vm_info.phys_footprint`) in MB — the jetsam-relevant RSS.
    public static var residentMB: Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }
}

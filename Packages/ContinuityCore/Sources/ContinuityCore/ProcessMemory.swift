import Foundation

#if canImport(Darwin)
import Darwin
#if canImport(os)
import os
#endif
#endif

/// Live process memory probes for diagnostics breadcrumbs. Returns `nil` on platforms without
/// Darwin jetsam / task APIs (Linux CI) so ContinuityCore stays testable everywhere.
public enum ProcessMemory {
    /// Remaining jetsam allowance (`os_proc_available_memory`) in MB.
    public static var headroomMB: Int? {
        #if canImport(Darwin) && canImport(os)
        Int(os_proc_available_memory() / 1_048_576)
        #else
        nil
        #endif
    }

    /// Resident footprint (`task_vm_info.phys_footprint`) in MB — the jetsam-relevant RSS.
    public static var residentMB: Int? {
        #if canImport(Darwin)
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
        #else
        nil
        #endif
    }
}

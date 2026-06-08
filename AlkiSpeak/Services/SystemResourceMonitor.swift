import Darwin
import Foundation

actor SystemResourceMonitor {
    static let shared = SystemResourceMonitor()

    func snapshot() -> SystemResourceSnapshot {
        var hostInfo = host_basic_info()
        var hostInfoCount = mach_msg_type_number_t(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let hostResult = withUnsafeMutablePointer(to: &hostInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(hostInfoCount)) {
                host_info(mach_host_self(), HOST_BASIC_INFO, $0, &hostInfoCount)
            }
        }

        var vmStats = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }

        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let cpuResult = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &cpuInfoCount
        )

        var cpuPercent = 0.0
        if cpuResult == KERN_SUCCESS, let cpuInfo {
            let loads = UnsafeBufferPointer(
                start: cpuInfo,
                count: Int(cpuInfoCount)
            )
            var used: Int32 = 0
            var total: Int32 = 0
            for cpu in 0..<Int(cpuCount) {
                let offset = Int(CPU_STATE_MAX) * cpu
                let userTicks = loads[offset + Int(CPU_STATE_USER)]
                let systemTicks = loads[offset + Int(CPU_STATE_SYSTEM)]
                let niceTicks = loads[offset + Int(CPU_STATE_NICE)]
                let idleTicks = loads[offset + Int(CPU_STATE_IDLE)]
                used += userTicks + systemTicks + niceTicks
                total += userTicks + systemTicks + niceTicks + idleTicks
            }
            if total > 0 { cpuPercent = Double(used) / Double(total) * 100 }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        guard hostResult == KERN_SUCCESS, vmResult == KERN_SUCCESS else {
            return SystemResourceSnapshot(cpuPercent: cpuPercent, ramUsedMB: 0, ramAvailableMB: 0)
        }
        let pageSize = Double(hostInfo.max_mem) / Double(max(1, hostInfo.max_mem / UInt64(vm_page_size)))
        let available = Double(vmStats.free_count + vmStats.inactive_count) * pageSize
        let total = Double(hostInfo.max_mem)
        return SystemResourceSnapshot(
            cpuPercent: cpuPercent,
            ramUsedMB: (total - available) / 1_048_576,
            ramAvailableMB: available / 1_048_576
        )
    }

    func canProceed() -> Bool {
        let value = snapshot()
        return value.cpuPercent < 80 && value.ramAvailableMB > 500
    }
}

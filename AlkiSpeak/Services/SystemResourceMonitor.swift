import Darwin
import Foundation
import OSLog

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

enum PerformanceDiagnosticPhase: String, Codable, Hashable {
    case idle
    case engineStart
    case engineStop
    case remoteGeneration
    case localSpeech
    case playback
    case resourceWait
    case failure
}

struct PerformanceDiagnosticThresholds: Codable, Hashable {
    var cpuPercent: Double
    var ramAvailableMB: Double
    var processMemoryMB: Double

    static let live = PerformanceDiagnosticThresholds(
        cpuPercent: AppConfig.performanceDiagnosticCPUWarningPercent,
        ramAvailableMB: AppConfig.performanceDiagnosticRAMAvailableWarningMB,
        processMemoryMB: AppConfig.performanceDiagnosticProcessMemoryWarningMB
    )
}

struct PerformanceDiagnosticPhaseSummary: Codable, Hashable {
    var phase: PerformanceDiagnosticPhase
    var sampleCount: Int
    var averageCPUPercent: Double
    var peakCPUPercent: Double
    var averageProcessMemoryMB: Double
    var peakProcessMemoryMB: Double
    var minimumRAMAvailableMB: Double
    var spikeCount: Int
}

struct PerformanceDiagnosticSummary: Codable, Hashable {
    var sessionID: UUID
    var startedAt: Date
    var endedAt: Date?
    var sampleCount: Int
    var spikeCount: Int
    var logPath: String
    var thresholds: PerformanceDiagnosticThresholds
    var topCPUPhase: PerformanceDiagnosticPhaseSummary?
    var topProcessMemoryPhase: PerformanceDiagnosticPhaseSummary?
    var phases: [PerformanceDiagnosticPhaseSummary]
}

struct PerformanceDiagnosticEvent: Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case sessionStart
        case marker
        case sample
        case spike
        case sessionEnd
    }

    var timestamp: Date
    var kind: Kind
    var phase: PerformanceDiagnosticPhase?
    var jobID: UUID?
    var message: String?
    var system: SystemResourceSnapshot?
    var process: ResourceSnapshot?
    var context: [String: String]
}

final class NullPerformanceDiagnosticRecorder: PerformanceDiagnosticRecording {
    let logURL = URL(fileURLWithPath: "/dev/null")
    let summaryURL = URL(fileURLWithPath: "/dev/null")

    func startSession(context: [String: String]) {}
    func recordMarker(phase: PerformanceDiagnosticPhase, message: String, jobID: UUID?, context: [String: String]) {}
    func recordSample(
        phase: PerformanceDiagnosticPhase,
        jobID: UUID?,
        system: SystemResourceSnapshot,
        process: ResourceSnapshot,
        context: [String: String]
    ) {}
    func finishSession(context: [String: String]) {}
}

final class FilePerformanceDiagnosticRecorder: PerformanceDiagnosticRecording {
    let logURL: URL
    let summaryURL: URL

    private let directory: URL
    private let thresholds: PerformanceDiagnosticThresholds
    private let dateProvider: () -> Date
    private let fileManager: FileManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alki.Woadie", category: "PerformanceDiagnostics")
    private let lock = NSLock()
    private let encoder = JSONEncoder()

    private var sessionID = UUID()
    private var startedAt = Date()
    private var endedAt: Date?
    private var sampleCount = 0
    private var spikeCount = 0
    private var phaseStats: [PerformanceDiagnosticPhase: RunningPhaseStats] = [:]

    init(
        directory: URL,
        thresholds: PerformanceDiagnosticThresholds = .live,
        fileManager: FileManager = .default,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.thresholds = thresholds
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        self.logURL = directory.appendingPathComponent("latest.jsonl")
        self.summaryURL = directory.appendingPathComponent("latest-summary.json")
    }

    static func live() -> FilePerformanceDiagnosticRecorder {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return FilePerformanceDiagnosticRecorder(
            directory: base
                .appendingPathComponent("Woadie", isDirectory: true)
                .appendingPathComponent("Diagnostics", isDirectory: true)
        )
    }

    func startSession(context: [String: String]) {
        lock.lock()
        defer { lock.unlock() }

        sessionID = UUID()
        startedAt = dateProvider()
        endedAt = nil
        sampleCount = 0
        spikeCount = 0
        phaseStats = [:]

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: logURL, options: .atomic)
            try writeUnlocked(
                PerformanceDiagnosticEvent(
                    timestamp: startedAt,
                    kind: .sessionStart,
                    phase: .idle,
                    jobID: nil,
                    message: "Performance diagnostic session started.",
                    system: nil,
                    process: nil,
                    context: context
                )
            )
            try writeSummaryUnlocked()
            logger.info("Performance diagnostics writing to \(self.logURL.path, privacy: .public)")
        } catch {
            logger.error("Failed to start performance diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }

    func recordMarker(phase: PerformanceDiagnosticPhase, message: String, jobID: UUID?, context: [String: String]) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try writeUnlocked(
                PerformanceDiagnosticEvent(
                    timestamp: dateProvider(),
                    kind: .marker,
                    phase: phase,
                    jobID: jobID,
                    message: message,
                    system: nil,
                    process: nil,
                    context: context
                )
            )
        } catch {
            logger.error("Failed to write performance marker: \(error.localizedDescription, privacy: .public)")
        }
    }

    func recordSample(
        phase: PerformanceDiagnosticPhase,
        jobID: UUID?,
        system: SystemResourceSnapshot,
        process: ResourceSnapshot,
        context: [String: String]
    ) {
        lock.lock()
        defer { lock.unlock() }

        let processMemoryMB = Double(process.memoryBytes ?? 0) / 1_048_576
        var stats = phaseStats[phase] ?? RunningPhaseStats(phase: phase)
        stats.record(system: system, processMemoryMB: processMemoryMB)
        phaseStats[phase] = stats
        sampleCount += 1

        do {
            try writeUnlocked(
                PerformanceDiagnosticEvent(
                    timestamp: dateProvider(),
                    kind: .sample,
                    phase: phase,
                    jobID: jobID,
                    message: nil,
                    system: system,
                    process: process,
                    context: context
                )
            )

            let reasons = spikeReasons(system: system, processMemoryMB: processMemoryMB)
            if !reasons.isEmpty {
                spikeCount += 1
                phaseStats[phase]?.spikeCount += 1
                try writeUnlocked(
                    PerformanceDiagnosticEvent(
                        timestamp: dateProvider(),
                        kind: .spike,
                        phase: phase,
                        jobID: jobID,
                        message: reasons.joined(separator: ", "),
                        system: system,
                        process: process,
                        context: context
                    )
                )
                logger.warning("Performance spike phase=\(phase.rawValue, privacy: .public) reasons=\(reasons.joined(separator: ", "), privacy: .public)")
            }
            try writeSummaryUnlocked()
        } catch {
            logger.error("Failed to write performance sample: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finishSession(context: [String: String]) {
        lock.lock()
        defer { lock.unlock() }

        endedAt = dateProvider()
        do {
            try writeUnlocked(
                PerformanceDiagnosticEvent(
                    timestamp: endedAt ?? dateProvider(),
                    kind: .sessionEnd,
                    phase: .idle,
                    jobID: nil,
                    message: "Performance diagnostic session finished.",
                    system: nil,
                    process: nil,
                    context: context
                )
            )
            try writeSummaryUnlocked()
        } catch {
            logger.error("Failed to finish performance diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func spikeReasons(system: SystemResourceSnapshot, processMemoryMB: Double) -> [String] {
        var reasons: [String] = []
        if system.cpuPercent >= thresholds.cpuPercent {
            reasons.append(String(format: "system_cpu=%.1f%%", system.cpuPercent))
        }
        if system.ramAvailableMB <= thresholds.ramAvailableMB {
            reasons.append(String(format: "ram_available=%.0fMB", system.ramAvailableMB))
        }
        if processMemoryMB >= thresholds.processMemoryMB {
            reasons.append(String(format: "process_memory=%.0fMB", processMemoryMB))
        }
        return reasons
    }

    private func writeUnlocked(_ event: PerformanceDiagnosticEvent) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(event)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
    }

    private func writeSummaryUnlocked() throws {
        let summaries = phaseStats.values
            .map { $0.summary }
            .sorted { $0.phase.rawValue < $1.phase.rawValue }
        let summary = PerformanceDiagnosticSummary(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            sampleCount: sampleCount,
            spikeCount: spikeCount,
            logPath: logURL.path,
            thresholds: thresholds,
            topCPUPhase: summaries.max { $0.peakCPUPercent < $1.peakCPUPercent },
            topProcessMemoryPhase: summaries.max { $0.peakProcessMemoryMB < $1.peakProcessMemoryMB },
            phases: summaries
        )
        let data = try encoder.encode(summary)
        try data.write(to: summaryURL, options: .atomic)
    }

    private struct RunningPhaseStats {
        var phase: PerformanceDiagnosticPhase
        var sampleCount = 0
        var totalCPUPercent = 0.0
        var peakCPUPercent = 0.0
        var totalProcessMemoryMB = 0.0
        var peakProcessMemoryMB = 0.0
        var minimumRAMAvailableMB = Double.greatestFiniteMagnitude
        var spikeCount = 0

        mutating func record(system: SystemResourceSnapshot, processMemoryMB: Double) {
            sampleCount += 1
            totalCPUPercent += system.cpuPercent
            peakCPUPercent = max(peakCPUPercent, system.cpuPercent)
            totalProcessMemoryMB += processMemoryMB
            peakProcessMemoryMB = max(peakProcessMemoryMB, processMemoryMB)
            minimumRAMAvailableMB = min(minimumRAMAvailableMB, system.ramAvailableMB)
        }

        var summary: PerformanceDiagnosticPhaseSummary {
            let count = Double(max(sampleCount, 1))
            return PerformanceDiagnosticPhaseSummary(
                phase: phase,
                sampleCount: sampleCount,
                averageCPUPercent: totalCPUPercent / count,
                peakCPUPercent: peakCPUPercent,
                averageProcessMemoryMB: totalProcessMemoryMB / count,
                peakProcessMemoryMB: peakProcessMemoryMB,
                minimumRAMAvailableMB: minimumRAMAvailableMB == Double.greatestFiniteMagnitude ? 0 : minimumRAMAvailableMB,
                spikeCount: spikeCount
            )
        }
    }
}

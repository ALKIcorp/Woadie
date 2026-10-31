import Darwin
import Foundation
import OSLog

actor SystemResourceMonitor {
    static let shared = SystemResourceMonitor()

    private var previousTicks: [CPULoad.Ticks] = []
    private var lastCPUPercent = 0.0
    private var previousTicksAt = ContinuousClock.now

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
            var ticks: [CPULoad.Ticks] = []
            ticks.reserveCapacity(Int(cpuCount))
            for cpu in 0..<Int(cpuCount) {
                let offset = Int(CPU_STATE_MAX) * cpu
                // Mach reports the counters as signed 32-bit values that wrap;
                // reinterpret them as unsigned so the delta below can wrap too.
                ticks.append(CPULoad.Ticks(
                    user: UInt32(bitPattern: loads[offset + Int(CPU_STATE_USER)]),
                    system: UInt32(bitPattern: loads[offset + Int(CPU_STATE_SYSTEM)]),
                    nice: UInt32(bitPattern: loads[offset + Int(CPU_STATE_NICE)]),
                    idle: UInt32(bitPattern: loads[offset + Int(CPU_STATE_IDLE)])
                ))
            }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.size))
            // The counters are cumulative since boot, so the load right now is
            // the change since the previous reading, not the running totals.
            // Readings closer than a quarter second hold too few ticks to be
            // meaningful, so reuse the last figure and keep the older baseline.
            let now = ContinuousClock.now
            if previousTicks.isEmpty || now - previousTicksAt >= .milliseconds(250) {
                cpuPercent = CPULoad.percent(from: previousTicks, to: ticks) ?? lastCPUPercent
                previousTicks = ticks
                previousTicksAt = now
                lastCPUPercent = cpuPercent
            } else {
                cpuPercent = lastCPUPercent
            }
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

/// System-wide CPU load from Mach per-core tick counters.
enum CPULoad {
    struct Ticks: Equatable {
        var user: UInt32
        var system: UInt32
        var nice: UInt32
        var idle: UInt32
    }

    /// Percent of CPU time spent busy between two readings, or nil when there
    /// is no earlier reading (or no time has passed) to compare against.
    static func percent(from previous: [Ticks], to current: [Ticks]) -> Double? {
        guard !previous.isEmpty, previous.count == current.count else { return nil }
        var used: Int64 = 0
        var total: Int64 = 0
        for (old, new) in zip(previous, current) {
            let user = Int64(new.user &- old.user)
            let system = Int64(new.system &- old.system)
            let nice = Int64(new.nice &- old.nice)
            let idle = Int64(new.idle &- old.idle)
            used += user + system + nice
            total += user + system + nice + idle
        }
        guard total > 0 else { return nil }
        return Double(used) / Double(total) * 100
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
    /// File writes happen here, in order, so callers (often the main actor)
    /// never wait on disk. Only this queue touches `logHandle`.
    private let ioQueue = DispatchQueue(label: "com.alki.Woadie.diagnostics", qos: .utility)
    private var logHandle: FileHandle?
    private var lastSummaryWrite: ContinuousClock.Instant?
    private static let summaryInterval: Duration = .seconds(30)

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

        ioQueue.async { [self] in
            do {
                try? logHandle?.close()
                logHandle = nil
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data().write(to: logURL, options: .atomic)
                logHandle = try FileHandle(forWritingTo: logURL)
                logger.info("Performance diagnostics writing to \(self.logURL.path, privacy: .public)")
            } catch {
                logger.error("Failed to start performance diagnostics: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
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
            // The summary is rewritten whole, so refresh it at most every 30 s
            // while sampling; finishSession always writes the final one.
            if let lastSummaryWrite, ContinuousClock.now - lastSummaryWrite < Self.summaryInterval {
                return
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
            ioQueue.async { [self] in
                try? logHandle?.close()
                logHandle = nil
            }
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

    /// Waits until every queued write has reached disk.
    func flush() {
        ioQueue.sync {}
    }

    private func writeUnlocked(_ event: PerformanceDiagnosticEvent) throws {
        var line = try encoder.encode(event)
        line.append(0x0A)
        ioQueue.async { [self] in
            do {
                if logHandle == nil {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    if !fileManager.fileExists(atPath: logURL.path) {
                        fileManager.createFile(atPath: logURL.path, contents: nil)
                    }
                    logHandle = try FileHandle(forWritingTo: logURL)
                }
                try logHandle?.seekToEnd()
                try logHandle?.write(contentsOf: line)
            } catch {
                logger.error("Failed to write performance event: \(error.localizedDescription, privacy: .public)")
            }
        }
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
        lastSummaryWrite = .now
        ioQueue.async { [self] in
            do {
                try data.write(to: summaryURL, options: .atomic)
            } catch {
                logger.error("Failed to write performance summary: \(error.localizedDescription, privacy: .public)")
            }
        }
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

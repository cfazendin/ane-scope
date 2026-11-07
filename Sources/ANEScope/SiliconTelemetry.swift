import Foundation
import IOKit

typealias IOReportSubscriptionRef = OpaquePointer

@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(
    _ group: CFString?,
    _ subgroup: CFString?,
    _ a: UInt64,
    _ b: UInt64,
    _ c: UInt64
) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportMergeChannels")
private func IOReportMergeChannels(
    _ a: CFMutableDictionary,
    _ b: CFDictionary,
    _ c: CFTypeRef?
)

@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(
    _ a: UnsafeRawPointer?,
    _ desiredChannels: CFMutableDictionary,
    _ subbedChannels: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?,
    _ channelId: UInt64,
    _ b: CFTypeRef?
) -> IOReportSubscriptionRef?

@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(
    _ sub: IOReportSubscriptionRef,
    _ subbedChannels: CFMutableDictionary,
    _ a: CFTypeRef?
) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(
    _ s1: CFDictionary,
    _ s2: CFDictionary,
    _ a: CFTypeRef?
) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ ch: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetSubGroup")
private func IOReportChannelGetSubGroup(_ ch: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportStateGetCount")
private func IOReportStateGetCount(_ ch: CFDictionary) -> Int32

@_silgen_name("IOReportStateGetNameForIndex")
private func IOReportStateGetNameForIndex(_ ch: CFDictionary, _ idx: Int32) -> Unmanaged<CFString>?

@_silgen_name("IOReportStateGetResidency")
private func IOReportStateGetResidency(_ ch: CFDictionary, _ idx: Int32) -> Int64

@_silgen_name("IOReportSimpleGetIntegerValue")
private func IOReportSimpleGetIntegerValue(_ ch: CFDictionary, _ idx: Int32) -> Int64

public struct TelemetrySample: Identifiable, Sendable {
    public let id: Int
    public let timestamp: Date
    public let durationSeconds: Double
    /// Weighted average ANE L1 Apple Fabric bandwidth (GB/s) during the sample window
    public let aneFabricBandwidthGBps: Double
    /// ANE Apple Fabric Read bandwidth (GB/s) — weights & inputs streaming into ANE
    public let aneReadBandwidthGBps: Double
    /// ANE Apple Fabric Write bandwidth (GB/s) — activations & outputs streaming out of ANE
    public let aneWriteBandwidthGBps: Double
    /// Peak ANE L1 Apple Fabric bandwidth bucket (GB/s) hit during the sample window
    public let anePeakFabricBandwidthGBps: Double
    /// Weighted average ANE DRAM controller bandwidth (GB/s)
    public let aneDRAMBandwidthGBps: Double
    /// Percentage of ANE fabric traffic served by System Level Cache (SLC) without hitting DRAM
    public let aneSLCHitRatioPercent: Double
    /// GPU (AGX) Apple Fabric bandwidth (GB/s)
    public let gpuFabricBandwidthGBps: Double
    /// Total System Unified Memory (AMCC) DRAM bandwidth (GB/s)
    public let systemDRAMBandwidthGBps: Double
    /// Percentage of residency in active/overdrive ANE voltage states (VNOM / VMAX / VOVD)
    public let aneActiveResidencyPercent: Double
    /// Percentage of residency specifically in VMAX / VOVD overdrive states
    public let aneOverdriveResidencyPercent: Double
    /// Breakdown of ANE voltage floor states (e.g. VMIN, VNOM, VMAX, VOVD_TYP)
    public let aneVoltageStates: [(name: String, percent: Double)]
    /// Share of the window spent in each ANE fabric bandwidth bucket (32 buckets of 2 GB/s on an M5 Max)
    public let aneFabricBuckets: [(label: String, gbps: Double, percent: Double)]
    /// The ANE fabric channel the buckets come from: the busiest one (e.g. "ANE L1 RD+WR")
    public let aneFabricBucketsChannel: String
    /// Exact GPU power in Watts from IOReport Energy Model (nJ counter)
    public let gpuPowerWatts: Double
    /// Total CPU cluster power in Watts from PMP0 Energy histograms
    public let cpuPowerWatts: Double
    /// Performance / Super CPU cluster power (PACC) in Watts
    public let paccPowerWatts: Double
    /// Efficiency / Medium CPU cluster 0 power (MACC0) in Watts
    public let macc0PowerWatts: Double
    /// Efficiency / Medium CPU cluster 1 power (MACC1) in Watts
    public let macc1PowerWatts: Double
    /// CPU SRAM / L2 cache power (PACC SRAM + MACC0 SRAM + MACC1 SRAM) in Watts
    public let cpuSRAMPowerWatts: Double
    /// IORegistry H11ANEIn hardware power-gate state (true = Powered & Clocked, false = Power-Gated Sleep)
    public let anePowerGateAwake: Bool
    /// IORegistry H11ANEIn driver & exclave summary (e.g. "AppleH16ANEInterface • ane,t8132exclave • v256.17")
    public let aneDriverSummary: String
    /// IORegistry IOAccelerator (AGX) live Device Utilization %
    public let gpuUtilizationPercent: Int
    /// IORegistry IOAccelerator (AGX) live Renderer Utilization %
    public let gpuRendererUtilizationPercent: Int
    /// IORegistry IOAccelerator (AGX) live Tiler Utilization %
    public let gpuTilerUtilizationPercent: Int
    /// IORegistry IOAccelerator (AGX) In-Use Wired Unified Memory (GB)
    public let gpuInUseMemoryGB: Double
    /// IORegistry IOAccelerator (AGX) Allocated Pool Unified Memory (GB)
    public let gpuAllocatedMemoryGB: Double
}

public final class SiliconTelemetrySampler: @unchecked Sendable {
    private var subscription: IOReportSubscriptionRef?
    private var subscribedChannels: CFMutableDictionary?
    private var lastRawSample: CFDictionary?
    private var lastSampleTime: CFAbsoluteTime = 0
    private var sampleCounter: Int = 0
    private let lock = NSLock()

    // Cached IORegistry service handles & static driver metadata (avoids tree-walking IORegistry on every tick)
    private var aneServiceEntry: io_service_t = 0
    private var gpuServiceEntry: io_service_t = 0
    public private(set) var cachedANEDriverSummary: String = "AppleANEInterface"

    /// False when no IOReport subscription could be created; every counter then reads 0.
    public var isAvailable: Bool { subscription != nil }

    public init() {
        setupCachedIORegistryHandles()
        setupSubscription()
    }

    deinit {
        if aneServiceEntry != 0 { IOObjectRelease(aneServiceEntry) }
        if gpuServiceEntry != 0 { IOObjectRelease(gpuServiceEntry) }
    }

    private func setupCachedIORegistryHandles() {
        var aneIter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("H11ANEIn"), &aneIter) == KERN_SUCCESS {
            defer { IOObjectRelease(aneIter) }
            let entry = IOIteratorNext(aneIter)
            if entry != 0 {
                self.aneServiceEntry = entry
                var propsRef: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let props = propsRef?.takeRetainedValue() as? [String: Any] {
                    let kext = (props["CFBundleIdentifierKernel"] as? String)?
                        .replacingOccurrences(of: "com.apple.driver.", with: "") ?? "H11ANEIn"
                    let matched = (props["IONameMatched"] as? String) ?? "ane"
                    if let devProps = props["DeviceProperties"] as? [String: Any] {
                        let ver = devProps["ANEDevicePropertyANEVersion"] as? Int ?? 0
                        let minor = devProps["ANEDevicePropertyANEMinorVersion"] as? Int ?? 0
                        cachedANEDriverSummary = "\(kext) • \(matched) • v\(ver).\(minor)"
                    } else {
                        cachedANEDriverSummary = "\(kext) • \(matched)"
                    }
                }
            }
        }

        var gpuIter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &gpuIter) == KERN_SUCCESS {
            defer { IOObjectRelease(gpuIter) }
            let entry = IOIteratorNext(gpuIter)
            if entry != 0 {
                self.gpuServiceEntry = entry
            }
        }
    }

    private func setupSubscription() {
        // Subscribe ONLY to the specific subgroups we need (instead of all 979 channels),
        // then prune the channel array to the exact ~16 channels we display.
        let desiredQueries: [(group: String, subgroup: String?)] = [
            ("Energy Model", nil),
            ("PMP0", "AF BW"),
            ("PMP0", "DCS BW"),
            ("PMP0", "SOC Floor"),
            ("PMP0", "Energy"),
            ("PMP1", "AF BW"),
            ("PMP1", "DCS BW"),
            ("PMP1", "SOC Floor"),
            ("PMP1", "Energy"),
            ("PMP", "AF BW"),
            ("PMP", "DCS BW"),
            ("PMP", "SOC Floor"),
            ("PMP", "Energy")
        ]

        var mergedChannels: CFMutableDictionary?
        for q in desiredQueries {
            if let groupDict = IOReportCopyChannelsInGroup(
                q.group as CFString,
                q.subgroup as CFString?,
                0, 0, 0
            )?.takeRetainedValue() {
                if let existing = mergedChannels {
                    IOReportMergeChannels(existing, groupDict, nil)
                } else {
                    mergedChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, groupDict)
                }
            }
        }

        guard let desired = mergedChannels else { return }

        // Prune the channel list before creating the kernel subscription so the kernel only snapshots
        // the exact ~16 channels we care about (reduces kernel/userspace IPC & delta work by >98%)
        if let dict = desired as NSMutableDictionary?,
           let rawChannels = dict["IOReportChannels"] as? [CFDictionary] {
            let filtered = rawChannels.filter { item in
                let sg = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() as String? ?? ""
                let name = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String? ?? ""
                if name == "GPU Energy" { return true }
                if sg == "AF BW" && (name.hasPrefix("ANE") || name == "AGX RD+WR") { return true }
                if sg == "DCS BW" && (name.hasPrefix("ANE") || name == "AMCC RD+WR") { return true }
                if sg == "SOC Floor" && name.hasPrefix("ANE") && name.contains("AF-BW") { return true }
                if sg == "Energy" && (name.hasPrefix("PACC") || name.hasPrefix("MACC") || name.hasPrefix("EACC")) { return true }
                return false
            }
            if !filtered.isEmpty {
                dict["IOReportChannels"] = filtered
            }
        }

        var subbed: Unmanaged<CFMutableDictionary>?
        if let sub = IOReportCreateSubscription(nil, desired, &subbed, 0, nil),
           let subbedDict = subbed?.takeRetainedValue() {
            self.subscription = sub
            self.subscribedChannels = subbedDict
            self.lastRawSample = IOReportCreateSamples(sub, subbedDict, nil)?.takeRetainedValue()
            self.lastSampleTime = CFAbsoluteTimeGetCurrent()
        }
    }

    public struct RawSnapshot: @unchecked Sendable {
        fileprivate let sample: CFDictionary
        fileprivate let time: CFAbsoluteTime
    }

    public func takeSnapshot() -> RawSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let sub = subscription, let subbed = subscribedChannels,
              let s = IOReportCreateSamples(sub, subbed, nil)?.takeRetainedValue() else {
            return nil
        }
        return RawSnapshot(sample: s, time: CFAbsoluteTimeGetCurrent())
    }

    /// Telemetry between two snapshots. Returns an all-zero sample when either snapshot is missing
    /// (IOReport unavailable), so benchmarks still run without hardware counters.
    public func computeDelta(from start: RawSnapshot?, to end: RawSnapshot?) -> TelemetrySample {
        lock.lock()
        sampleCounter += 1
        let seq = sampleCounter
        lock.unlock()

        guard let start, let end else {
            return emptySample(id: seq, durationSeconds: 0)
        }
        let dt = max(end.time - start.time, 1e-4)
        guard let deltaDict = IOReportCreateSamplesDelta(start.sample, end.sample, nil)?.takeRetainedValue() as NSDictionary?,
              let channels = deltaDict["IOReportChannels"] as? [CFDictionary] else {
            return emptySample(id: seq, durationSeconds: dt)
        }
        return parseChannels(channels, sampleId: seq, durationSeconds: dt)
    }

    private func emptySample(id: Int, durationSeconds: Double) -> TelemetrySample {
        TelemetrySample(
            id: id,
            timestamp: Date(),
            durationSeconds: durationSeconds,
            aneFabricBandwidthGBps: 0,
            aneReadBandwidthGBps: 0,
            aneWriteBandwidthGBps: 0,
            anePeakFabricBandwidthGBps: 0,
            aneDRAMBandwidthGBps: 0,
            aneSLCHitRatioPercent: 0,
            gpuFabricBandwidthGBps: 0,
            systemDRAMBandwidthGBps: 0,
            aneActiveResidencyPercent: 0,
            aneOverdriveResidencyPercent: 0,
            aneVoltageStates: [],
            aneFabricBuckets: [],
            aneFabricBucketsChannel: "",
            gpuPowerWatts: 0,
            cpuPowerWatts: 0,
            paccPowerWatts: 0,
            macc0PowerWatts: 0,
            macc1PowerWatts: 0,
            cpuSRAMPowerWatts: 0,
            anePowerGateAwake: false,
            aneDriverSummary: cachedANEDriverSummary,
            gpuUtilizationPercent: 0,
            gpuRendererUtilizationPercent: 0,
            gpuTilerUtilizationPercent: 0,
            gpuInUseMemoryGB: 0,
            gpuAllocatedMemoryGB: 0
        )
    }

    public func sampleNext() -> TelemetrySample? {
        lock.lock()
        guard let sub = subscription,
              let subbed = subscribedChannels,
              let prev = lastRawSample,
              let current = IOReportCreateSamples(sub, subbed, nil)?.takeRetainedValue() else {
            lock.unlock()
            return nil
        }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(now - lastSampleTime, 1e-4)
        lastRawSample = current
        lastSampleTime = now
        sampleCounter += 1
        let seq = sampleCounter
        lock.unlock()

        guard let deltaDict = IOReportCreateSamplesDelta(prev, current, nil)?.takeRetainedValue() as NSDictionary?,
              let channels = deltaDict["IOReportChannels"] as? [CFDictionary] else {
            return nil
        }
        return parseChannels(channels, sampleId: seq, durationSeconds: dt)
    }

    private func parseChannels(_ channels: [CFDictionary], sampleId: Int, durationSeconds dt: Double) -> TelemetrySample {
        var aneFabricBW = 0.0
        var aneReadBW = 0.0
        var aneWriteBW = 0.0
        var anePeakFabricBW = 0.0
        var aneDRAMBW = 0.0
        var gpuFabricBW = 0.0
        var sysDRAMBW = 0.0
        var aneActivePct = 0.0
        var aneOverdrivePct = 0.0
        var aneVoltageBreakdown: [(name: String, percent: Double)] = []
        var aneFabricBuckets: [(label: String, gbps: Double, percent: Double)] = []
        var bucketsChannel = ""
        var bucketsChannelAverage = -1.0
        var gpuPowerW = 0.0
        var paccW = 0.0
        var macc0W = 0.0
        var macc1W = 0.0
        var sramW = 0.0
        var otherCPUW = 0.0

        for item in channels {
            let sg = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() as String? ?? ""
            let name = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String? ?? ""

            if name == "GPU Energy" {
                let nJ = IOReportSimpleGetIntegerValue(item, 0)
                if nJ > 0 {
                    gpuPowerW += (Double(nJ) * 1e-9) / dt
                }
            } else if sg == "AF BW" {
                if name.hasPrefix("ANE") && name.contains("RD+WR") {
                    let parsed = Self.parseBandwidthHistogram(item, idleFloorGBps: 2.0)
                    aneFabricBW += parsed.averageGBps
                    anePeakFabricBW = max(anePeakFabricBW, parsed.peakGBps)
                    // More than one ANE channel can report (L0 and L1 on an M5 Max) and most of the traffic
                    // can sit on one of them, so the histogram follows the busiest channel.
                    if parsed.averageGBps > bucketsChannelAverage {
                        aneFabricBuckets = parsed.buckets
                        bucketsChannel = name
                        bucketsChannelAverage = parsed.averageGBps
                    }
                } else if name.hasPrefix("ANE") && name.hasSuffix("RD") {
                    let parsed = Self.parseBandwidthHistogram(item, idleFloorGBps: 2.0)
                    aneReadBW += parsed.averageGBps
                } else if name.hasPrefix("ANE") && name.hasSuffix("WR") {
                    let parsed = Self.parseBandwidthHistogram(item, idleFloorGBps: 2.0)
                    aneWriteBW += parsed.averageGBps
                } else if name == "AGX RD+WR" {
                    let parsed = Self.parseBandwidthHistogram(item, idleFloorGBps: 1.0)
                    gpuFabricBW += parsed.averageGBps
                }
            } else if sg == "DCS BW" {
                if name.hasPrefix("ANE") && name.contains("RD+WR") {
                    let parsed = Self.parseBandwidthHistogram(item, idleFloorGBps: 2.0)
                    aneDRAMBW += parsed.averageGBps
                } else if name == "AMCC RD+WR" {
                    let parsed = Self.parseBandwidthHistogram(item, idleFloorGBps: 32.0)
                    sysDRAMBW += parsed.averageGBps
                }
            } else if sg == "SOC Floor" && name.hasPrefix("ANE") && name.contains("AF-BW") {
                let count = IOReportStateGetCount(item)
                var totalRes: Int64 = 0
                var activeRes: Int64 = 0
                var overdriveRes: Int64 = 0
                var rawStates: [(String, Int64)] = []
                for i in 0..<count {
                    let stName = (IOReportStateGetNameForIndex(item, i)?.takeUnretainedValue() as String? ?? "")
                        .trimmingCharacters(in: .whitespaces)
                    let res = IOReportStateGetResidency(item, i)
                    if res > 0 {
                        totalRes += res
                        if stName != "VMIN" {
                            activeRes += res
                        }
                        if stName.contains("VMAX") || stName.contains("VOVD") {
                            overdriveRes += res
                        }
                    }
                    rawStates.append((stName, max(0, res)))
                }
                if totalRes > 0 {
                    aneActivePct = max(aneActivePct, (Double(activeRes) / Double(totalRes)) * 100.0)
                    aneOverdrivePct = max(aneOverdrivePct, (Double(overdriveRes) / Double(totalRes)) * 100.0)
                    if aneVoltageBreakdown.isEmpty {
                        aneVoltageBreakdown = rawStates.map { ($0.0, (Double($0.1) / Double(totalRes)) * 100.0) }
                    }
                }
            } else if sg == "Energy" {
                if name.contains("SRAM") {
                    sramW += Self.parseWattHistogram(item)
                } else if name == "PACC" || name.hasPrefix("PACC") {
                    paccW += Self.parseWattHistogram(item)
                } else if name == "MACC0" {
                    macc0W += Self.parseWattHistogram(item)
                } else if name == "MACC1" {
                    macc1W += Self.parseWattHistogram(item)
                } else if name.hasPrefix("EACC") {
                    otherCPUW += Self.parseWattHistogram(item)
                }
            }
        }

        if aneFabricBW <= 0.0 {
            aneFabricBW = 0.0
            aneReadBW = 0.0
            aneWriteBW = 0.0
            anePeakFabricBW = 0.0
            aneDRAMBW = 0.0
            aneActivePct = 0.0
            aneOverdrivePct = 0.0
            if !aneVoltageBreakdown.isEmpty {
                aneVoltageBreakdown = aneVoltageBreakdown.map { state in
                    (state.name, state.name == "VMIN" ? 100.0 : 0.0)
                }
            }
        }

        let slcHitPct: Double = {
            guard aneFabricBW > 0.2 else { return 0.0 }
            let ratio = 1.0 - min(aneDRAMBW / aneFabricBW, 1.0)
            return max(0.0, min(100.0, ratio * 100.0))
        }()

        let totalCPUW = paccW + macc0W + macc1W + sramW + otherCPUW
        let ioreg = readFastIORegistryStats(aneActiveBandwidth: aneFabricBW)

        return TelemetrySample(
            id: sampleId,
            timestamp: Date(),
            durationSeconds: dt,
            aneFabricBandwidthGBps: aneFabricBW,
            aneReadBandwidthGBps: aneReadBW,
            aneWriteBandwidthGBps: aneWriteBW,
            anePeakFabricBandwidthGBps: anePeakFabricBW,
            aneDRAMBandwidthGBps: aneDRAMBW,
            aneSLCHitRatioPercent: slcHitPct,
            gpuFabricBandwidthGBps: gpuFabricBW,
            systemDRAMBandwidthGBps: sysDRAMBW,
            aneActiveResidencyPercent: aneActivePct,
            aneOverdriveResidencyPercent: aneOverdrivePct,
            aneVoltageStates: aneVoltageBreakdown,
            aneFabricBuckets: aneFabricBuckets,
            aneFabricBucketsChannel: bucketsChannel,
            gpuPowerWatts: gpuPowerW,
            cpuPowerWatts: totalCPUW,
            paccPowerWatts: paccW,
            macc0PowerWatts: macc0W,
            macc1PowerWatts: macc1W,
            cpuSRAMPowerWatts: sramW,
            anePowerGateAwake: ioreg.aneAwake,
            aneDriverSummary: cachedANEDriverSummary,
            gpuUtilizationPercent: ioreg.gpuUtilPct,
            gpuRendererUtilizationPercent: ioreg.gpuRendererPct,
            gpuTilerUtilizationPercent: ioreg.gpuTilerPct,
            gpuInUseMemoryGB: ioreg.gpuInUseGB,
            gpuAllocatedMemoryGB: ioreg.gpuAllocGB
        )
    }

    private func readFastIORegistryStats(aneActiveBandwidth: Double) -> (
        aneAwake: Bool,
        gpuUtilPct: Int,
        gpuRendererPct: Int,
        gpuTilerPct: Int,
        gpuInUseGB: Double,
        gpuAllocGB: Double
    ) {
        var aneAwake = aneActiveBandwidth > 0.1
        if aneServiceEntry != 0,
           let pm = IORegistryEntryCreateCFProperty(aneServiceEntry, "IOPowerManagement" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
           let pwrState = pm["CurrentPowerState"] as? Int {
            aneAwake = (pwrState > 0) || (aneActiveBandwidth > 0.1)
        }

        var gpuUtil = 0
        var gpuRend = 0
        var gpuTiler = 0
        var gpuInUseGB = 0.0
        var gpuAllocGB = 0.0

        if gpuServiceEntry != 0,
           let perf = IORegistryEntryCreateCFProperty(gpuServiceEntry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
            gpuUtil = perf["Device Utilization %"] as? Int ?? 0
            gpuRend = perf["Renderer Utilization %"] as? Int ?? 0
            gpuTiler = perf["Tiler Utilization %"] as? Int ?? 0
            if let inUseBytes = perf["In use system memory"] as? Int64 {
                gpuInUseGB = Double(inUseBytes) / (1024.0 * 1024.0 * 1024.0)
            } else if let inUseNum = perf["In use system memory"] as? NSNumber {
                gpuInUseGB = inUseNum.doubleValue / (1024.0 * 1024.0 * 1024.0)
            }
            if let allocBytes = perf["Alloc system memory"] as? Int64 {
                gpuAllocGB = Double(allocBytes) / (1024.0 * 1024.0 * 1024.0)
            } else if let allocNum = perf["Alloc system memory"] as? NSNumber {
                gpuAllocGB = allocNum.doubleValue / (1024.0 * 1024.0 * 1024.0)
            }
        }

        return (aneAwake, gpuUtil, gpuRend, gpuTiler, gpuInUseGB, gpuAllocGB)
    }

    private static func parseBandwidthHistogram(
        _ item: CFDictionary,
        idleFloorGBps: Double
    ) -> (
        averageGBps: Double,
        peakGBps: Double,
        buckets: [(label: String, gbps: Double, percent: Double)]
    ) {
        let count = IOReportStateGetCount(item)
        guard count > 0 else { return (0, 0, []) }
        var rawBuckets: [(label: String, gbps: Double, res: Double)] = []
        rawBuckets.reserveCapacity(Int(count))

        for i in 0..<count {
            let rawLabel = (IOReportStateGetNameForIndex(item, i)?.takeUnretainedValue() as String? ?? "")
                .trimmingCharacters(in: .whitespaces)
            let numericStr = rawLabel.replacingOccurrences(of: "GB/s", with: "")
                .trimmingCharacters(in: .whitespaces)
            let gbps = Double(numericStr) ?? 0.0
            let res = Double(max(0, IOReportStateGetResidency(item, i)))
            rawBuckets.append((rawLabel.isEmpty ? "\(Int(gbps))GB/s" : rawLabel, gbps, res))
        }
        rawBuckets.sort { $0.gbps < $1.gbps }

        // Each label is its bucket's upper edge: an idle ANE sits in the lowest bucket ("2GB/s" on an
        // M5 Max). Weighting buckets by their tops counted idle time as 2 GB/s whenever there was any
        // activity, so weight each bucket by its midpoint instead.
        var weightedSum = 0.0
        var totalSamples = 0.0
        var activeSamples = 0.0
        var peak = 0.0
        var lowerEdge = 0.0
        for bucket in rawBuckets {
            let midpoint = (lowerEdge + bucket.gbps) / 2
            lowerEdge = bucket.gbps
            guard bucket.res > 0 else { continue }
            weightedSum += midpoint * bucket.res
            totalSamples += bucket.res
            if bucket.gbps > idleFloorGBps {
                activeSamples += bucket.res
            }
            peak = max(peak, bucket.gbps)
        }
        guard totalSamples > 0 else { return (0, 0, []) }
        let normalizedBuckets = rawBuckets.map { b in
            (b.label, b.gbps, (b.res / totalSamples) * 100.0)
        }
        if activeSamples > 0 {
            return (weightedSum / totalSamples, peak, normalizedBuckets)
        }
        return (0.0, 0.0, normalizedBuckets)
    }

    private static func parseWattHistogram(_ item: CFDictionary) -> Double {
        let count = IOReportStateGetCount(item)
        guard count > 0 else { return 0 }
        var weightedSum = 0.0
        var totalSamples = 0.0
        for i in 0..<count {
            let label = (IOReportStateGetNameForIndex(item, i)?.takeUnretainedValue() as String? ?? "")
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "W", with: "")
            let watts = Double(label) ?? 0.0
            let res = Double(IOReportStateGetResidency(item, i))
            if res > 0 {
                weightedSum += watts * res
                totalSamples += res
            }
        }
        guard totalSamples > 0 else { return 0 }
        return weightedSum / totalSamples
    }
}

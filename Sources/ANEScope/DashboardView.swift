import SwiftUI
import Charts
import UniformTypeIdentifiers

public enum ScopeTab: String, CaseIterable, Identifiable {
    case liveScope = "Live Silicon Scope"
    case benchmarks = "Benchmarks & Compute Plan"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .liveScope: return "waveform.path.ecg.rectangle.fill"
        case .benchmarks: return "speedometer"
        }
    }
}

public struct DashboardView: View {
    @StateObject private var coordinator = BenchmarkCoordinator()
    @State private var selectedTab: ScopeTab = .liveScope
    @State private var isDropTargeted = false

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            headerBar

            switch selectedTab {
            case .liveScope:
                liveSiliconScopeTab
            case .benchmarks:
                benchmarksAndComputePlanTab
            }
        }
        .padding(16)
        .frame(minWidth: 1260, minHeight: 720)
        .background(Color(red: 0.05, green: 0.06, blue: 0.09))
        .preferredColorScheme(.dark)
        .task {
            coordinator.startLiveTelemetry()
        }
    }

    // MARK: - Top Header Bar with Tab Switcher

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.mint.opacity(0.9), Color.cyan.opacity(0.85), Color.indigo.opacity(0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                let s = coordinator.latestTelemetry
                let aneAwake = s?.anePowerGateAwake ?? false
                let driverSummary = s?.aneDriverSummary ?? coordinator.telemetrySampler.cachedANEDriverSummary
                HStack(spacing: 8) {
                    Text("ANE-Scope")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    badgePill("CoreAI: \(coordinator.hardware.coreAIArchitecture)", color: .mint)
                    badgePill(coordinator.hardware.aneShortName, color: .cyan)
                    badgePill(
                        aneAwake ? "ANE GATE: POWERED (1)" : "ANE GATE: SLEEP (0)",
                        color: aneAwake ? .green : .secondary
                    )
                }
                Text("\(coordinator.hardware.cpuBrand) (\(coordinator.hardware.unifiedMemoryGB) GB) • \(driverSummary)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Tab Picker
            HStack(spacing: 6) {
                ForEach(ScopeTab.allCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .bold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundStyle(selectedTab == tab ? Color.black : Color.white.opacity(0.85))
                        .background(
                            selectedTab == tab
                                ? AnyShapeStyle(LinearGradient(colors: [Color.mint, Color.cyan], startPoint: .leading, endPoint: .trailing))
                                : AnyShapeStyle(Color.white.opacity(0.06)),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Live Status & Quick Controls
            HStack(spacing: 8) {
                Button {
                    Task { await coordinator.triggerQuickANEPulse() }
                } label: {
                    Label(coordinator.isRunning ? "Running..." : "Pulse ANE", systemImage: "bolt.horizontal.fill")
                        .font(.system(size: 11.5, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)
                .disabled(coordinator.isRunning)

                Button {
                    coordinator.resetSessionStats()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11.5, weight: .bold))
                        .padding(5)
                }
                .buttonStyle(.bordered)
                .help("Reset Session Peaks & Oscilloscope History")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(cardBackground)
    }

    // MARK: - TAB 1: LIVE SILICON SCOPE (Main Hardware Cockpit + Interactive ANE Chat)

    private var liveSiliconScopeTab: some View {
        VStack(spacing: 10) {
            liveReadoutStrip
            dualOscilloscopeRow
            middleSpectrumAndBurstRow
            neuralEnginePromptCard
        }
    }

    private var liveReadoutStrip: some View {
        let s = coordinator.latestTelemetry
        let aneBW = s?.aneFabricBandwidthGBps ?? 0
        let aneRD = s?.aneReadBandwidthGBps ?? 0
        let aneWR = s?.aneWriteBandwidthGBps ?? 0
        let anePeak = s?.anePeakFabricBandwidthGBps ?? 0
        let aneDRAM = s?.aneDRAMBandwidthGBps ?? 0
        let slcHit = s?.aneSLCHitRatioPercent ?? 0
        let aneOvd = s?.aneOverdriveResidencyPercent ?? 0
        let aneAct = s?.aneActiveResidencyPercent ?? 0
        let gpuW = s?.gpuPowerWatts ?? 0
        let gpuBW = s?.gpuFabricBandwidthGBps ?? 0
        let gpuUtil = s?.gpuUtilizationPercent ?? 0
        let gpuInUseGB = s?.gpuInUseMemoryGB ?? 0
        let gpuAllocGB = s?.gpuAllocatedMemoryGB ?? 0
        let cpuW = s?.cpuPowerWatts ?? 0
        let paccW = s?.paccPowerWatts ?? 0
        let maccW = (s?.macc0PowerWatts ?? 0) + (s?.macc1PowerWatts ?? 0)
        let sramW = s?.cpuSRAMPowerWatts ?? 0
        let sysDRAM = s?.systemDRAMBandwidthGBps ?? 0
        let totalW = gpuW + cpuW

        // Busy signals that work on any chip: AGX utilization for the GPU, and CPU power measured
        // against this session's CPU peak. Fixed wattage thresholds only suit one chip.
        let gpuBusy = gpuUtil >= 50
        let cpuBusy = cpuW >= max(coordinator.peakCPUPowerWatts * 0.5, 5.0)
        let engineState: (label: String, color: Color) = {
            if aneBW > 1.0 && gpuBusy {
                return ("HYBRID (ANE + GPU)", .purple)
            } else if aneBW > 0.5 {
                return ("ANE ACTIVE", .mint)
            } else if gpuBusy {
                return ("GPU COMPUTE", .orange)
            } else if cpuBusy {
                return ("CPU ACTIVE", .indigo)
            } else {
                return ("SILICON IDLE", .secondary)
            }
        }()

        return HStack(spacing: 10) {
            scopeMetricCard(
                title: "ANE APPLE FABRIC BW",
                primary: String(format: "%.1f GB/s", aneBW),
                secondary: String(format: "RD: %.1f • WR: %.1f GB/s", aneRD, aneWR),
                tertiary: String(format: "Peak: %.1f GB/s (Bucket %.0f)", coordinator.peakANEFabricBW, max(anePeak, coordinator.peakANEBucketGBps)),
                progress: gaugeFraction(aneBW, peak: coordinator.peakANEFabricBW, floor: 4),
                color: .mint,
                icon: "memorychip.fill"
            )

            scopeMetricCard(
                title: "ANE DRAM & SLC CACHE",
                primary: String(format: "%.1f GB/s", aneDRAM),
                secondary: String(format: "SLC Cache Hit: %.0f%%", slcHit),
                tertiary: String(format: "Moved: %.2f GB AF / %.2f GB DRAM", coordinator.cumulativeANEFabricGB, coordinator.cumulativeANEDRAMGB),
                progress: gaugeFraction(aneDRAM, peak: coordinator.peakANEDRAMBW, floor: 4),
                color: .cyan,
                icon: "arrow.left.arrow.right.square.fill"
            )

            scopeMetricCard(
                title: "ANE VOLTAGE OVERDRIVE",
                primary: String(format: "%.1f%%", aneOvd),
                secondary: String(format: "VNOM+ Active: %.1f%%", aneAct),
                tertiary: String(format: "Peak VMAX: %.1f%% • Active: %.1fs", coordinator.peakANEOverdrivePct, coordinator.totalANEActiveSeconds),
                progress: min(aneOvd / 100.0, 1.0),
                color: .green,
                icon: "bolt.circle.fill"
            )

            scopeMetricCard(
                title: "GPU0 POWER & UMA",
                primary: String(format: "%.2f W", gpuW),
                secondary: String(format: "Util: %d%% • AGX: %.1f GB/s", gpuUtil, gpuBW),
                tertiary: String(format: "UMA: %.2f GB In-Use / %.1f GB Pool", gpuInUseGB, gpuAllocGB),
                progress: gaugeFraction(gpuW, peak: coordinator.peakGPUPowerWatts, floor: 5),
                color: .orange,
                icon: "gauge.with.dots.needle.67percent"
            )

            scopeMetricCard(
                title: "CPU & SRAM POWER",
                primary: String(format: "%.2f W", cpuW),
                secondary: String(format: "PACC: %.1fW • MACC: %.1fW", paccW, maccW),
                tertiary: String(format: "L2/SRAM: %.2fW • Peak: %.1fW", sramW, coordinator.peakCPUPowerWatts),
                progress: gaugeFraction(cpuW, peak: coordinator.peakCPUPowerWatts, floor: 5),
                color: .purple,
                icon: "cpu"
            )

            scopeMetricCard(
                title: "UNIFIED MEMORY & STATE",
                primary: engineState.label,
                secondary: String(format: "AMCC DRAM: %.1f GB/s", sysDRAM),
                tertiary: String(format: "Compute: %.2fW • Peak GPU: %.1fW", totalW, coordinator.peakGPUPowerWatts),
                progress: gaugeFraction(totalW, peak: coordinator.peakGPUPowerWatts + coordinator.peakCPUPowerWatts, floor: 10),
                color: engineState.color,
                icon: "sparkles.tv.fill"
            )
        }
    }

    private func scopeMetricCard(
        title: String,
        primary: String,
        secondary: String,
        tertiary: String,
        progress: Double,
        color: Color,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                Spacer()
            }
            Text(primary)
                .font(.system(size: 19, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.65), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(3, geo.size.width * CGFloat(max(0, min(progress, 1)))))
                }
            }
            .frame(height: 5)
            // Shrink long readouts to fit rather than cutting them off with "…".
            Text(secondary)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(tertiary)
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
    }

    // MARK: - Row 2: Dual High-Frequency Oscilloscopes

    private var dualOscilloscopeRow: some View {
        // Plot each sample by its position in the window, not by its id. Ids keep growing all session (and
        // skip values when a benchmark takes a reading), and the chart's x range started at 0, so the
        // trace got squeezed into a thinner and thinner strip on the right.
        let history = Array(coordinator.telemetryHistory.enumerated())
        let window = 0...(BenchmarkCoordinator.historyLength - 1)
        return HStack(spacing: 10) {
            // Left Oscilloscope: Neural Engine Interconnect Bandwidth (Fabric vs DRAM vs Peak Bucket)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("NEURAL ENGINE INTERCONNECT OSCILLOSCOPE (GB/s)", systemImage: "waveform.path.ecg")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    HStack(spacing: 10) {
                        legendDot("ANE Fabric Avg", color: .mint)
                        legendDot("ANE DRAM BW", color: .cyan)
                        legendDot("Peak Bucket", color: .green.opacity(0.75))
                    }
                }

                Chart(history, id: \.element.id) { index, item in
                    AreaMark(
                        x: .value("Sample", index),
                        y: .value("ANE Fabric", item.aneFabricBandwidthGBps)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.mint.opacity(0.38), Color.mint.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Sample", index),
                        y: .value("ANE Fabric", item.aneFabricBandwidthGBps),
                        series: .value("Trace", "Fabric")
                    )
                    .foregroundStyle(Color.mint)
                    .lineStyle(StrokeStyle(lineWidth: 2.0))

                    LineMark(
                        x: .value("Sample", index),
                        y: .value("ANE DRAM", item.aneDRAMBandwidthGBps),
                        series: .value("Trace", "DRAM")
                    )
                    .foregroundStyle(Color.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))

                    LineMark(
                        x: .value("Sample", index),
                        y: .value("Peak Bucket", item.anePeakFabricBandwidthGBps),
                        series: .value("Trace", "PeakBucket")
                    )
                    .foregroundStyle(Color.green.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                }
                .chartYScale(domain: 0...max(68, coordinator.peakANEBucketGBps + 4))
                .chartXScale(domain: window)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(cardBackground)

            // Right Oscilloscope: Silicon Power (GPU W + CPU W) vs ANE VMAX Overdrive (%)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("SILICON POWER (W) vs ANE OVERDRIVE (%)", systemImage: "bolt.circle")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    HStack(spacing: 10) {
                        legendDot("ANE Overdrive (%)", color: .cyan)
                        legendDot("GPU0 Power (W)", color: .orange)
                        legendDot("CPU Power (W)", color: .purple)
                    }
                }

                Chart(history, id: \.element.id) { index, item in
                    AreaMark(
                        x: .value("Sample", index),
                        y: .value("Overdrive", item.aneOverdriveResidencyPercent)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.25), Color.cyan.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Sample", index),
                        y: .value("Overdrive", item.aneOverdriveResidencyPercent),
                        series: .value("Signal", "ANE Overdrive %")
                    )
                    .foregroundStyle(Color.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 2.0))

                    LineMark(
                        x: .value("Sample", index),
                        y: .value("GPU W", item.gpuPowerWatts),
                        series: .value("Signal", "GPU Watts")
                    )
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2.0))

                    LineMark(
                        x: .value("Sample", index),
                        y: .value("CPU W", item.cpuPowerWatts),
                        series: .value("Signal", "CPU Watts")
                    )
                    .foregroundStyle(Color.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
                // Percent tops out at 100, but an M5 Max GPU reaches about 100 W, so make room above that.
                .chartYScale(domain: 0...max(100, coordinator.peakGPUPowerWatts, coordinator.peakCPUPowerWatts))
                .chartXScale(domain: window)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(cardBackground)
        }
        // Shrinks on short windows; the higher layout priority keeps the scopes larger than the chat box.
        .frame(minHeight: 140, maxHeight: 215)
        .layoutPriority(1)
    }

    // MARK: - Row 3: 4 Deep Hardware Distribution & Activity Panels

    private var middleSpectrumAndBurstRow: some View {
        HStack(spacing: 10) {
            aneVoltageFloorPanel
            aneFabricBucketSpectrumPanel
            siliconClusterPowerPanel
            aneBurstDetectorPanel
        }
        .frame(minHeight: 140, maxHeight: 195)
        .layoutPriority(1)
    }

    // Panel 1: ANE Voltage Floor Residency (VMIN / VNOM / VMAX / VOVD)
    private var aneVoltageFloorPanel: some View {
        let rawStates = coordinator.latestTelemetry?.aneVoltageStates ?? []
        let displayStates: [(name: String, percent: Double)] = rawStates.isEmpty
            ? [("VMIN", 100.0), ("VNOM", 0.0), ("VMAX", 0.0), ("VOVD", 0.0)]
            : rawStates

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("ANE VOLTAGE FLOOR", systemImage: "bolt.horizontal.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                badgePill("SOC Floor", color: .cyan)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(displayStates.enumerated()), id: \.offset) { _, st in
                        let stColor: Color = {
                            if st.name.contains("VOVD") { return .pink }
                            if st.name.contains("VMAX") { return .cyan }
                            if st.name.contains("VNOM") { return .mint }
                            return .secondary
                        }()
                        spectrumBarRow(
                            label: st.name,
                            valueText: String(format: "%.1f%%", st.percent),
                            ratio: st.percent / 100.0,
                            color: stColor
                        )
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
    }

    // Panel 2: ANE Apple Fabric Bandwidth Bucket Histogram
    private var aneFabricBucketSpectrumPanel: some View {
        // IOReport splits ANE fabric bandwidth into many narrow buckets (32 of 2 GB/s on an M5 Max), so
        // group them into six ranges that fit the panel. Buckets are labeled by their upper edge and the
        // last range is open-ended, so every bucket lands in exactly one row.
        let ranges: [(label: String, upper: Double)] = [
            ("0–2 GB/s", 2), ("2–8 GB/s", 8), ("8–16 GB/s", 16),
            ("16–32 GB/s", 32), ("32–48 GB/s", 48), ("48+ GB/s", .infinity)
        ]
        let sample = coordinator.latestTelemetry
        let buckets = sample?.aneFabricBuckets ?? []
        let channel = sample?.aneFabricBucketsChannel ?? ""
        let rows = ranges.indices.map { i -> (label: String, upper: Double, percent: Double) in
            let lower = i == 0 ? -Double.infinity : ranges[i - 1].upper
            let percent: Double
            if buckets.isEmpty {
                percent = i == 0 ? 100 : 0  // No sample yet: show the ANE as idle.
            } else {
                percent = buckets.filter { $0.gbps > lower && $0.gbps <= ranges[i].upper }.reduce(0) { $0 + $1.percent }
            }
            return (ranges[i].label, ranges[i].upper, percent)
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("ANE FABRIC BW BUCKETS", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                badgePill(channel.isEmpty ? "AF BW RD+WR" : channel, color: .mint)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, b in
                        let color: Color = b.upper > 32 ? .mint : (b.upper > 8 ? .cyan : .secondary)
                        spectrumBarRow(
                            label: b.label,
                            valueText: String(format: "%.1f%%", b.percent),
                            ratio: b.percent / 100.0,
                            color: color
                        )
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
    }

    // Panel 3: Silicon Sub-Cluster Power Breakdown (PACC / MACC0 / MACC1 / SRAM / GPU0)
    private var siliconClusterPowerPanel: some View {
        let s = coordinator.latestTelemetry
        let paccW = s?.paccPowerWatts ?? 0
        let macc0W = s?.macc0PowerWatts ?? 0
        let macc1W = s?.macc1PowerWatts ?? 0
        let sramW = s?.cpuSRAMPowerWatts ?? 0
        let gpuW = s?.gpuPowerWatts ?? 0
        let totalW = paccW + macc0W + macc1W + sramW + gpuW
        // One shared scale so the rails can be compared with each other.
        let railScale = max(coordinator.peakGPUPowerWatts, coordinator.peakCPUPowerWatts)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("SILICON POWER RAILS", systemImage: "cpu.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                badgePill(String(format: "%.2f W", totalW), color: .orange)
            }

            ScrollView {
                VStack(spacing: 6) {
                    spectrumBarRow(
                        label: "PACC (Perf CPU)",
                        valueText: String(format: "%.2f W", paccW),
                        ratio: gaugeFraction(paccW, peak: railScale, floor: 5),
                        color: .purple
                    )
                    spectrumBarRow(
                        label: "MACC0 + MACC1 (CPU)",
                        valueText: String(format: "%.2f W", macc0W + macc1W),
                        ratio: gaugeFraction(macc0W + macc1W, peak: railScale, floor: 5),
                        color: .indigo
                    )
                    spectrumBarRow(
                        label: "CPU L2 / SRAM Rail",
                        valueText: String(format: "%.2f W", sramW),
                        ratio: gaugeFraction(sramW, peak: railScale, floor: 5),
                        color: .cyan
                    )
                    spectrumBarRow(
                        label: "GPU0 (AGX Neural)",
                        valueText: String(format: "%.2f W", gpuW),
                        ratio: gaugeFraction(gpuW, peak: railScale, floor: 5),
                        color: .orange
                    )
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
    }

    // Panel 4: Automatic ANE Inference Burst Detector (catches ANE work from any process, not just this app)
    private var aneBurstDetectorPanel: some View {
        let timeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("LIVE ANE BURST DETECTOR", systemImage: "waveform.badge.magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                badgePill("\(coordinator.aneBurstEvents.count) Bursts", color: .mint)
            }

            if coordinator.aneBurstEvents.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 18))
                        .foregroundStyle(.mint.opacity(0.6))
                    Text("Listening for ANE activity...\nPrompt the LLM below, run any Core ML app, or click 'Pulse ANE'.")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(coordinator.aneBurstEvents) { ev in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(timeFormatter.string(from: ev.timestamp))
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.mint)
                                    Text(String(format: "• %.2fs", ev.durationSeconds))
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    badgePill(String(format: "%.2f GB", ev.dataMovedGB), color: .cyan)
                                }
                                Text(String(
                                    format: "Avg %.1f GB/s (Peak %.0f) • %.0f%% VMAX • GPU %.2fW",
                                    ev.avgFabricGBps,
                                    ev.peakBucketGBps,
                                    ev.avgOverdrivePct,
                                    ev.avgGPUPowerWatts
                                ))
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            }
                            .padding(6)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
    }

    private func spectrumBarRow(label: String, valueText: String, ratio: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(valueText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, geo.size.width * CGFloat(max(0, min(ratio, 1)))))
                }
            }
            .frame(height: 5)
        }
    }

    // MARK: - Row 4 (Main Panel): Interactive On-Device Apple LLM Chat

    private var neuralEnginePromptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("INTERACTIVE ON-DEVICE APPLE LLM (FoundationModels -> \(coordinator.hardware.aneShortName.uppercased()))", systemImage: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                if let m = coordinator.lastLLMMetrics {
                    badgePill(String(format: "~%.1f tok/s", m.tokensPerSecond), color: .cyan)
                    badgePill(String(format: "TTFT: %.0f ms", m.timeToFirstChunkMs), color: .green)
                    badgePill(String(format: "ANE: %.1f GB/s", m.aneFabricBandwidthGBps), color: .mint)
                    badgePill(String(format: "VMAX: %.0f%%", m.aneOverdrivePercent), color: .purple)
                    badgePill(String(format: "GPU: %.2f W", m.gpuPowerWatts), color: .orange)
                } else {
                    badgePill(coordinator.foundationModelAvailability, color: .mint)
                }

                Button("Reset") {
                    coordinator.resetLLMSession()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(coordinator.isStreamingLLM)
            }

            HStack(spacing: 8) {
                TextField("Ask the On-Device Apple Neural Engine LLM (watch the oscilloscopes above spike as tokens stream)...", text: $coordinator.promptInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                    .onSubmit {
                        Task { await coordinator.sendPromptToNeuralEngine() }
                    }

                Button {
                    Task { await coordinator.sendPromptToNeuralEngine() }
                } label: {
                    if coordinator.isStreamingLLM {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 6)
                    } else {
                        Label("Run on ANE", systemImage: "paperplane.fill")
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)
                .disabled(coordinator.isStreamingLLM || coordinator.promptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ScrollView {
                HStack(alignment: .top, spacing: 10) {
                    if let image = coordinator.promptImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 120, maxHeight: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text(coordinator.llmResponseText.isEmpty ? responsePlaceholder : coordinator.llmResponseText)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(coordinator.llmResponseText.isEmpty ? Color.secondary : Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            // Always leave room for about four lines of the reply.
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
        .overlay {
            if isDropTargeted {
                // Dark enough to cover an earlier reply, so the hint stays readable.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.75))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.mint, lineWidth: 2))
                    .overlay(
                        Label(dropHint, systemImage: "photo")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.mint)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    )
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleImageDrop(providers)
        }
    }

    /// What the drop highlight says will happen.
    private var dropHint: String {
        guard coordinator.supportsImageInput else { return "This Mac's on-device model doesn't accept images" }
        if let question = coordinator.pendingImageQuestion {
            return "Drop an image to ask: “\(question)”"
        }
        return "Drop an image to have the on-device model describe it"
    }

    private var responsePlaceholder: String {
        let drop = coordinator.supportsImageInput ? " or drop an image here" : ""
        return "Type a prompt above\(drop), then watch live ANE Read/Write Fabric BW, SLC Cache Hit %, and VMAX Overdrive above as the on-device Apple LLM replies."
    }

    /// Takes an image file from Finder, or image data from apps like Photos and Safari, and asks the model
    /// about it (using an unsent question from the prompt box, if there is one).
    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first, !coordinator.isStreamingLLM else { return false }
        let coordinator = self.coordinator
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url,
                      (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true else { return }
                Task { @MainActor in await coordinator.describeImage(at: url) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { file, _ in
                // The provided file is deleted when this handler returns, so keep a copy.
                guard let file else { return }
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ANEScope-dropped-\(UUID().uuidString)")
                    .appendingPathExtension(file.pathExtension)
                guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else { return }
                Task { @MainActor in await coordinator.describeImage(at: copy) }
            }
            return true
        }
        return false
    }

    // MARK: - TAB 2: BENCHMARKS & MLCOMPUTEPLAN INSPECTOR

    private var benchmarksAndComputePlanTab: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    Task { await coordinator.runFullSuite() }
                } label: {
                    Label("Run Full Suite (ANE + GPU + Hybrid)", systemImage: "bolt.fill")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(coordinator.isRunning)

                targetButton("\(coordinator.hardware.aneShortName) (FP16)", icon: "brain.head.profile", target: "ANE", tint: .mint)
                targetButton("GPU Neural (FP16)", icon: "square.grid.3x3.middle.filled", target: "GPU_FP16", tint: .orange)
                targetButton("GPU Neural (INT8)", icon: "flame.fill", target: "GPU_INT8", tint: .pink)
                targetButton("Hybrid (ANE + GPU)", icon: "sparkles", target: "HYBRID", tint: .purple)
                targetButton("CPU Baseline (.cpuOnly)", icon: "tortoise.fill", target: "CPU", tint: .gray)

                Spacer()
            }
            .padding(12)
            .background(cardBackground)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("NEURAL HARDWARE BENCHMARK RESULTS", systemImage: "speedometer")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        // Match the engine, not badge text: the hybrid badge ("ANE0 + GPU0") also contains "ANE".
                        if let ane = coordinator.results.first(where: { $0.engine == .neuralEngine }),
                           let cpu = coordinator.results.first(where: { $0.engine == .cpu }),
                           cpu.throughputValue > 0 {
                            let speedup = ane.throughputValue / cpu.throughputValue
                            badgePill(String(format: "ANE is %.1f× faster than CPU", speedup), color: .green)
                        }
                    }

                    if coordinator.results.isEmpty {
                        VStack(spacing: 10) {
                            Spacer()
                            Image(systemName: "speedometer")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("Click 'Run Full Suite' or any individual target button above to benchmark ANE, Metal 4 GPU Neural Accelerators, and Hybrid execution.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(coordinator.results) { res in
                                    benchmarkResultRow(res)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(cardBackground)

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("MLComputePlan LAYER AUDIT", systemImage: "checkmark.shield.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                            Spacer()
                            if let art = coordinator.modelArtifact {
                                badgePill("\(art.aneAssignedCount)/\(art.layers.count) on ANE", color: .green)
                            }
                        }

                        if let art = coordinator.modelArtifact {
                            ScrollView {
                                VStack(spacing: 4) {
                                    ForEach(art.layers) { layer in
                                        HStack(spacing: 8) {
                                            Image(systemName: layer.isNeuralEngine ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                                .foregroundStyle(layer.isNeuralEngine ? Color.green : Color.yellow)
                                                .font(.system(size: 11))
                                            Text(String(format: "#%02d", layer.index))
                                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                            Text(layer.name)
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Spacer()
                                            badgePill(layer.preferredDevice, color: layer.isNeuralEngine ? .green : .orange)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                        } else {
                            Spacer()
                            Text("Run any ANE target or 'Pulse ANE' to synthesize & audit the 12-layer Core ML Spec v7 model.")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                            Spacer()
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(cardBackground)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("HARDWARE & COMPILER LOG", systemImage: "terminal.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(coordinator.logs.enumerated()), id: \.offset) { idx, line in
                                        Text(line)
                                            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                            .foregroundStyle(line.contains("Result") || line.contains("verified") ? Color.mint : Color.white.opacity(0.85))
                                            .textSelection(.enabled)
                                            .id(idx)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // Follow new lines. Watch the last line, not the count, which stops changing
                            // once the log reaches its 200-line cap.
                            .onChange(of: coordinator.logs.last, initial: true) {
                                proxy.scrollTo(coordinator.logs.count - 1, anchor: .bottom)
                            }
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(cardBackground)
                }
                .frame(width: 480)
            }
        }
    }

    private func targetButton(_ label: String, icon: String, target: String, tint: Color) -> some View {
        Button {
            Task { await coordinator.runSingleTarget(target) }
        } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(coordinator.isRunning)
    }

    private func benchmarkResultRow(_ res: BenchmarkResult) -> some View {
        let color = badgeColor(for: res.engineBadge)
        // Scale bars to the best result on this machine, not to one chip's peak.
        let maxThroughput = max(coordinator.results.map(\.throughputValue).max() ?? 1.0, 1e-6)
        let barRatio = min(res.throughputValue / maxThroughput, 1.0)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(res.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                badgePill(res.engineBadge, color: color)
                badgePill(res.precision, color: .secondary)
                if let verified = res.outputVerified {
                    badgePill(verified ? "Output verified" : "Output check failed", color: verified ? .green : .red)
                }
                Spacer()
                Text(String(format: "%.2f %@", res.throughputValue, res.throughputValue > 0 ? res.throughputUnit : ""))
                    .font(.system(size: 16, weight: .heavy, design: .monospaced))
                    .foregroundStyle(color)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.65), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, geo.size.width * CGFloat(barRatio)))
                }
            }
            .frame(height: 6)

            HStack(spacing: 14) {
                Text(res.subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f ms/op", res.latencyMsPerIter))
                Text(String(format: "ANE BW: %.1f GB/s (Peak %.0f)", res.aneFabricBandwidthGBps, res.anePeakFabricBandwidthGBps))
                    .foregroundStyle(res.aneFabricBandwidthGBps > 5 ? Color.mint : Color.secondary)
                Text(String(format: "ANE VMAX/VOVD: %.0f%%", res.aneOverdrivePercent))
                    .foregroundStyle(res.aneOverdrivePercent > 20 ? Color.cyan : Color.secondary)
                Text(String(format: "GPU: %.1f W", res.gpuPowerWatts))
                    .foregroundStyle(res.gpuPowerWatts > 15 ? Color.orange : Color.secondary)
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Styling Helpers

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(red: 0.09, green: 0.11, blue: 0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    /// How full to draw a gauge. Gauges scale to this session's peak rather than one chip's maximum,
    /// so they read the same on any Mac; `floor` stops idle noise from filling a gauge before anything has run.
    private func gaugeFraction(_ value: Double, peak: Double, floor: Double) -> Double {
        min(value / max(peak, floor), 1.0)
    }

    private func badgePill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func legendDot(_ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func badgeColor(for badge: String) -> Color {
        if badge.contains("ANE0 + GPU0") || badge.contains("HYBRID") { return .purple }
        if badge.contains("ANE") { return .mint }
        if badge.contains("GPU") { return .orange }
        return .gray
    }
}

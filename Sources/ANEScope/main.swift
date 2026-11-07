import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()

        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Open at 1260×880, shrunk to fit smaller screens (e.g. a 13-inch MacBook with the Dock showing).
        var contentRect = NSRect(x: 0, y: 0, width: 1260, height: 880)
        if let visible = NSScreen.main?.visibleFrame {
            let fit = NSWindow.contentRect(forFrameRect: visible, styleMask: style)
            contentRect.size.width = min(contentRect.width, fit.width)
            contentRect.size.height = min(contentRect.height, fit.height)
        }
        let window = NSWindow(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
        window.center()
        window.title = "ANE-Scope — Apple Neural Engine & Metal 4 GPU Monitor"
        let hostingView = NSHostingView(rootView: DashboardView())
        // Let the window shrink to the dashboard's minimum size, not just its ideal size.
        hostingView.sizingOptions = [.minSize]
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// The window is built by hand, so the menu bar has to be too. macOS sends ⌘Q, ⌘W and the
    /// copy and paste shortcuts through these items, so without them those keys do nothing.
    private func installMainMenu() {
        let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: "About ANE-Scope", action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ANE-Scope", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ANE-Scope", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "ANE-Scope"])
    }
}

@MainActor
func runCLIMode() async {
    let coordinator = BenchmarkCoordinator()
    let hw = coordinator.hardware
    print("================================================================================")
    print("  ANE-SCOPE — APPLE SILICON NEURAL ENGINE & METAL 4 GPU BENCHMARK & VERIFIER")
    print("================================================================================")
    print("  SoC / CPU           : \(hw.cpuBrand) (\(hw.unifiedMemoryGB) GB Unified Memory)")
    print("  OS                  : \(hw.osVersion)")
    print("  CoreAI Architecture : \(hw.coreAIArchitecture) (Units: \(hw.coreAIAvailableUnits.joined(separator: ", ")))")
    print("  Neural Engine       : \(hw.aneName) (ANE0)")
    print("  GPU                 : \(hw.gpuName) (\(hw.gpuShortName), Metal 4 MPP matmul2d + cooperative_tensor)")
    print("================================================================================\n")

    coordinator.echoLogsToStdout = true
    await coordinator.runFullSuite()

    func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return String(s.prefix(width)) }
        return s + String(repeating: " ", count: width - s.count)
    }

    if let art = coordinator.modelArtifact {
        print("\n--- MLComputePlan Hardware Audit (\(art.modelName)) ---")
        let build = art.usedCachedBuild ? "Loaded the cached build" : "Compiled in \(String(format: "%.2f", art.compileDurationSeconds))s"
        print("\(build) | \(art.aneAssignedCount)/\(art.layers.count) layers assigned to the \(hw.aneName) (\(hw.coreAIArchitecture))")
        for layer in art.layers {
            let idx = String(format: "%02d", layer.index)
            print("  [\(idx)] \(pad(layer.name, 14)) \(pad(layer.layerType, 28)) \(pad(layer.shapeDescription, 18)) -> \(layer.preferredDevice)")
        }
    }

    print("\n--- Benchmark Summary (\(hw.cpuBrand)) ---")
    print("--------------------------------------------------------------------------------------------------------------------")
    print("\(pad("Workload / Target Engine", 44)) | \(pad("Throughput", 14)) | \(pad("Latency", 10)) | \(pad("ANE Fabric BW", 14)) | \(pad("ANE VMAX%", 10)) | \(pad("GPU Power", 9))")
    print("--------------------------------------------------------------------------------------------------------------------")
    for r in coordinator.results {
        let tp = String(format: "%.2f %@", r.throughputValue, r.throughputUnit)
        let lat = String(format: "%.2f ms", r.latencyMsPerIter)
        let bw = String(format: "%.1f GB/s", r.aneFabricBandwidthGBps)
        let ovd = String(format: "%.1f%%", r.aneOverdrivePercent)
        let gpuW = String(format: "%.1f W", r.gpuPowerWatts)
        let title = r.outputVerified == false ? "\(r.title) [BAD OUTPUT]" : r.title
        print("\(pad(title, 44)) | \(pad(tp, 14)) | \(pad(lat, 10)) | \(pad(bw, 14)) | \(pad(ovd, 10)) | \(pad(gpuW, 9))")
    }
    print("--------------------------------------------------------------------------------------------------------------------")
}

@MainActor
func runPromptMode(prompt: String) async {
    let coordinator = BenchmarkCoordinator()
    let hw = coordinator.hardware
    print("================================================================================")
    print("  ON-DEVICE APPLE LLM (FoundationModels) WITH LIVE NEURAL ENGINE TELEMETRY")
    print("================================================================================")
    print("  Hardware            : \(hw.cpuBrand) | \(hw.aneShortName) (\(hw.coreAIArchitecture))")
    print("  LLM Availability    : \(coordinator.foundationModelAvailability)")
    print("  Prompt              : \(prompt)")
    print("================================================================================\n")

    await coordinator.sendPromptToNeuralEngine(prompt)

    print("Response:\n\(coordinator.llmResponseText)\n")

    if let m = coordinator.lastLLMMetrics {
        print("--- Live IOReport Hardware Telemetry During LLM Generation ---")
        print(String(format: "  Throughput / Latency : ~%d tokens in %.2fs (~%.1f tok/s | TTFT: %.0f ms)",
                     m.estimatedTokens, m.elapsedSeconds, m.tokensPerSecond, m.timeToFirstChunkMs))
        print(String(format: "  ANE0 Fabric BW       : %.1f GB/s avg (Peak Bucket: %.0f GB/s)",
                     m.aneFabricBandwidthGBps, m.anePeakFabricBandwidthGBps))
        print(String(format: "  ANE0 Voltage         : %.1f%% VMAX / VOVD Overdrive Residency",
                     m.aneOverdrivePercent))
        print(String(format: "  GPU0 Power           : %.2f W", m.gpuPowerWatts))
        print(String(format: "  CPU Power            : %.2f W", m.cpuPowerWatts))
        print("--------------------------------------------------------------")
    }
}

/// Prints live ANE, GPU and CPU telemetry until interrupted, as a table or (with `csv`) as CSV.
func runMonitorMode(csv: Bool, intervalMs: Int) -> Never {
    let sampler = SiliconTelemetrySampler()
    guard sampler.isAvailable else {
        FileHandle.standardError.write(Data("IOReport telemetry is unavailable on this system.\n".utf8))
        exit(1)
    }
    // Line-buffer stdout so a pipe or `> file` gets every sample, even when the run ends with Ctrl-C.
    setvbuf(stdout, nil, _IOLBF, 0)

    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss"
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    // Each header is exactly as wide as its column's number format below.
    let header = ["time    ", "ANE GB/s", " peak", "DRAM GB/s", " VMAX %", "  GPU W", "GPU %", "  CPU W"].joined(separator: "  ")
    if csv {
        print("timestamp,ane_fabric_gbps,ane_peak_bucket_gbps,ane_dram_gbps,ane_read_gbps,ane_write_gbps,ane_vmax_pct,gpu_watts,gpu_util_pct,cpu_watts")
    }

    var rows = 0
    var next = Date()
    while true {
        next += TimeInterval(intervalMs) / 1000
        // After a pause (Ctrl-Z, sleep, a stall), carry on from now instead of firing every missed sample at once.
        if next < Date() { next = Date() }
        Thread.sleep(until: next)
        guard let s = sampler.sampleNext() else { continue }
        if csv {
            print([
                iso.string(from: s.timestamp),
                String(format: "%.3f", s.aneFabricBandwidthGBps),
                String(format: "%.0f", s.anePeakFabricBandwidthGBps),
                String(format: "%.3f", s.aneDRAMBandwidthGBps),
                String(format: "%.3f", s.aneReadBandwidthGBps),
                String(format: "%.3f", s.aneWriteBandwidthGBps),
                String(format: "%.2f", s.aneOverdriveResidencyPercent),
                String(format: "%.3f", s.gpuPowerWatts),
                "\(s.gpuUtilizationPercent)",
                String(format: "%.3f", s.cpuPowerWatts)
            ].joined(separator: ","))
        } else {
            // Repeat the header every 20 rows, like vmstat.
            if rows % 20 == 0 { print(header) }
            rows += 1
            print([
                clock.string(from: s.timestamp),
                String(format: "%8.2f", s.aneFabricBandwidthGBps),
                String(format: "%5.0f", s.anePeakFabricBandwidthGBps),
                String(format: "%9.2f", s.aneDRAMBandwidthGBps),
                String(format: "%7.1f", s.aneOverdriveResidencyPercent),
                String(format: "%7.2f", s.gpuPowerWatts),
                String(format: "%5ld", s.gpuUtilizationPercent),
                String(format: "%7.2f", s.cpuPowerWatts)
            ].joined(separator: "  "))
        }
    }
}

let args = CommandLine.arguments
if let promptIdx = args.firstIndex(of: "--prompt"), promptIdx + 1 < args.count {
    let userPrompt = args[(promptIdx + 1)...].joined(separator: " ")
    Task { @MainActor in
        await runPromptMode(prompt: userPrompt)
        exit(0)
    }
    RunLoop.main.run()
} else if args.contains("--help") || args.contains("-h") {
    print("""
    Usage: ane-scope [--cli | --monitor [--csv] [--interval <ms>] | --prompt <text>]

      (no options)      Open the SwiftUI dashboard
      --cli             Run the full benchmark suite and MLComputePlan audit in the terminal
      --monitor         Print live ANE, GPU and CPU telemetry until you press Ctrl-C
        --csv           Print CSV instead of a table, for logging to a file
        --interval <ms> Time between samples in milliseconds (default 1000, minimum 100)
      --prompt <text>   Send a prompt to the on-device Apple LLM and report ANE telemetry
      -h, --help        Show this help
    """)
    exit(0)
} else if args.contains("--monitor") {
    let interval = args.firstIndex(of: "--interval").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 1000
    runMonitorMode(csv: args.contains("--csv"), intervalMs: max(100, interval))
} else if args.contains("--cli") {
    Task { @MainActor in
        await runCLIMode()
        exit(0)
    }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.run()
}

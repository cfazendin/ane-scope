import Foundation
import AppKit
import CoreML
import CoreAI
import FoundationModels
import Metal
import IOKit
import Combine

public struct NeuralEnginePromptMetrics: Sendable {
    public let prompt: String
    public let responseText: String
    public let elapsedSeconds: Double
    public let timeToFirstChunkMs: Double
    public let estimatedTokens: Int
    public let tokensPerSecond: Double
    public let aneFabricBandwidthGBps: Double
    public let anePeakFabricBandwidthGBps: Double
    public let aneOverdrivePercent: Double
    public let gpuPowerWatts: Double
    public let cpuPowerWatts: Double
}

public struct HardwareProfile: Sendable {
    public let cpuBrand: String
    public let osVersion: String
    public let coreAIArchitecture: String
    public let coreAIAvailableUnits: [String]
    public let aneCoreCount: Int
    public let gpuName: String
    public let gpuCoreCount: Int
    public let unifiedMemoryGB: Int

    /// "16-Core Neural Engine", or "Neural Engine" when the core count is unknown.
    public var aneName: String { aneCoreCount > 0 ? "\(aneCoreCount)-Core Neural Engine" : "Neural Engine" }
    /// "16-Core ANE", or "ANE" when the core count is unknown.
    public var aneShortName: String { aneCoreCount > 0 ? "\(aneCoreCount)-Core ANE" : "ANE" }
    /// "40-Core GPU", or "GPU" when the core count is unknown.
    public var gpuShortName: String { gpuCoreCount > 0 ? "\(gpuCoreCount)-Core GPU" : "GPU" }

    public static func detect() -> HardwareProfile {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brandChars = [CChar](repeating: 0, count: max(size, 64))
        sysctlbyname("machdep.cpu.brand_string", &brandChars, &size, nil, 0)
        let cpuBrand = String(cString: brandChars)

        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        let arch = AIModel.deviceArchitectureName
        let units = ComputeUnitKind.availableKinds.map { kind -> String in
            switch kind {
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .neuralEngine: return "NeuralEngine"
            @unknown default: return "Other"
            }
        }.sorted()

        var aneCores = 0
        var gpuName = MTLCreateSystemDefaultDevice()?.name ?? "Apple GPU"
        for dev in MLComputeDevice.allComputeDevices {
            switch dev {
            case .neuralEngine(let ane):
                aneCores = ane.totalCoreCount
            case .gpu(let gpu):
                if let name = gpu.metalDevice?.name {
                    gpuName = name
                }
            default:
                break
            }
        }

        // Metal doesn't expose the GPU core count; the AGX driver publishes it in the IORegistry.
        var gpuCores = 0
        let agx = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        if agx != 0 {
            if let count = IORegistryEntryCreateCFProperty(agx, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int {
                gpuCores = count
            }
            IOObjectRelease(agx)
        }

        let memBytes = ProcessInfo.processInfo.physicalMemory
        let memGB = Int(memBytes / (1024 * 1024 * 1024))

        return HardwareProfile(
            cpuBrand: cpuBrand.isEmpty ? "Apple Silicon" : cpuBrand,
            osVersion: "macOS \(osVer)",
            coreAIArchitecture: arch,
            coreAIAvailableUnits: units,
            aneCoreCount: aneCores,
            gpuName: gpuName,
            gpuCoreCount: gpuCores,
            unifiedMemoryGB: memGB
        )
    }
}

public enum BenchmarkEngine: Sendable {
    case neuralEngine, gpu, hybrid, cpu
}

public struct BenchmarkResult: Identifiable, Sendable {
    public let id = UUID()
    public let engine: BenchmarkEngine
    public let title: String
    public let subtitle: String
    public let engineBadge: String
    public let precision: String
    public let throughputValue: Double
    public let throughputUnit: String // "TFLOPS" or "TOPS"
    public let latencyMsPerIter: Double
    public let iterations: Int
    public let elapsedSeconds: Double
    public let aneFabricBandwidthGBps: Double
    public let anePeakFabricBandwidthGBps: Double
    public let aneDRAMBandwidthGBps: Double
    public let aneOverdrivePercent: Double
    public let gpuPowerWatts: Double
    public let cpuPowerWatts: Double
    /// GPU benchmarks only: whether the kernel's output matched the CPU reference.
    public var outputVerified: Bool? = nil
}

public struct ANEBurstEvent: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let durationSeconds: Double
    public let avgFabricGBps: Double
    public let peakBucketGBps: Double
    public let avgOverdrivePct: Double
    public let dataMovedGB: Double
    public let avgGPUPowerWatts: Double
}

@MainActor
public final class BenchmarkCoordinator: ObservableObject {
    public let hardware = HardwareProfile.detect()
    @Published public var modelArtifact: ANEModelArtifact?
    @Published public var results: [BenchmarkResult] = []
    @Published public var telemetryHistory: [TelemetrySample] = []
    @Published public var latestTelemetry: TelemetrySample?
    @Published public var statusMessage: String = "Monitoring Live Silicon Telemetry (IOReport)"
    @Published public var isRunning: Bool = false
    @Published public var logs: [String] = []

    // Session Peak-Hold & Cumulative Silicon Counters
    @Published public var peakANEFabricBW: Double = 0.0
    @Published public var peakANEBucketGBps: Double = 0.0
    @Published public var peakANEDRAMBW: Double = 0.0
    @Published public var peakANEOverdrivePct: Double = 0.0
    @Published public var peakGPUPowerWatts: Double = 0.0
    @Published public var peakCPUPowerWatts: Double = 0.0
    @Published public var cumulativeANEFabricGB: Double = 0.0
    @Published public var cumulativeANEDRAMGB: Double = 0.0
    @Published public var totalANEActiveSeconds: Double = 0.0
    @Published public var aneBurstEvents: [ANEBurstEvent] = []

    // Active burst tracking state
    private var activeBurstStart: Date?
    private var activeBurstDuration: Double = 0
    private var activeBurstWeightedBW: Double = 0
    private var activeBurstPeakBucket: Double = 0
    private var activeBurstWeightedOvd: Double = 0
    private var activeBurstWeightedGPU: Double = 0

    // Interactive FoundationModels session (Apple's on-device LLM)
    @Published public var promptInput: String = ""
    @Published public var llmResponseText: String = ""
    @Published public var isStreamingLLM: Bool = false
    @Published public var lastLLMMetrics: NeuralEnginePromptMetrics?
    @Published public var foundationModelAvailability: String = "Checking..."
    /// The image the current reply is about, shown beside it; nil for text prompts.
    @Published public var promptImage: NSImage?
    /// Whether this Mac's on-device model accepts images.
    public var supportsImageInput: Bool { SystemLanguageModel.default.capabilities.contains(.vision) }
    /// The last prompt actually sent. The prompt box keeps its text after sending, and a dropped image
    /// mustn't reuse that old prompt as its question.
    private var lastSentPrompt: String?
    /// What a dropped image will be asked: a question typed in the prompt box but not sent yet, or nil
    /// to ask for a description.
    public var pendingImageQuestion: String? {
        let typed = promptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty || typed == lastSentPrompt ? nil : typed
    }

    public let telemetrySampler = SiliconTelemetrySampler()
    /// CLI mode prints log lines as they happen, so a terminal run shows progress.
    public var echoLogsToStdout = false

    // Each benchmark runs for a fixed time rather than a fixed number of passes, so the suite
    // takes about as long on any chip.
    private static let benchmarkSeconds = 2.0
    private static let hybridSeconds = 3.0
    private static let pulseSeconds = 1.5
    /// How many samples the oscilloscopes show: 24 seconds at the 400 ms sampling interval.
    public static let historyLength = 60
    private var telemetryTimer: DispatchSourceTimer?
    private let telemetryQueue = DispatchQueue(label: "com.anescope.telemetry", qos: .utility)
    private var llmSession: LanguageModelSession?

    public init() {
        appendLog("ANE-Scope started on \(hardware.cpuBrand) (\(hardware.unifiedMemoryGB) GB Unified Memory)")
        appendLog("\(hardware.osVersion) | CoreAI Architecture: \(hardware.coreAIArchitecture) | ANE Cores: \(hardware.aneCoreCount) | GPU Cores: \(hardware.gpuCoreCount)")
        if !telemetrySampler.isAvailable {
            appendLog("IOReport telemetry is unavailable on this system; hardware counters will read 0.")
        }
        let sysModel = SystemLanguageModel.default
        foundationModelAvailability = Self.describeAvailability(sysModel.availability)
        if case .available = sysModel.availability {
            llmSession = LanguageModelSession(model: sysModel)
        }
        appendLog("FoundationModels SystemLanguageModel.default: \(foundationModelAvailability)")
    }

    private static func describeAvailability(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "Available (On-Device)"
        case .unavailable(.deviceNotEligible):
            return "Unavailable: this Mac can't run Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Unavailable: turn on Apple Intelligence in System Settings"
        case .unavailable(.modelNotReady):
            return "Unavailable: the model isn't ready yet (it may still be downloading)"
        default:
            return "Unavailable (\(availability))"
        }
    }

    public func resetLLMSession() {
        // A reply still streaming would keep writing into the text this clears.
        guard !isStreamingLLM else { return }
        llmSession = LanguageModelSession(model: .default)
        llmResponseText = ""
        promptImage = nil
        lastLLMMetrics = nil
        appendLog("Reset on-device FoundationModels LanguageModelSession context.")
    }

    /// Sends the prompt box text (or `customPrompt`) to the on-device model.
    public func sendPromptToNeuralEngine(_ customPrompt: String? = nil) async {
        let promptToRun = (customPrompt ?? promptInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptToRun.isEmpty, !isStreamingLLM else { return }
        if customPrompt != nil {
            promptInput = promptToRun
        }
        lastSentPrompt = promptToRun
        promptImage = nil
        await runOnDeviceModel(logLabel: "\"\(promptToRun)\"", metricsPrompt: promptToRun) {
            promptToRun
        }
    }

    /// Asks the on-device model about an image: an unsent question from the prompt box if there is one,
    /// otherwise for a description.
    public func describeImage(at url: URL) async {
        guard !isStreamingLLM else { return }
        guard supportsImageInput else {
            llmResponseText = "This Mac's on-device model doesn't accept images."
            return
        }
        guard let image = NSImage(contentsOf: url) else {
            llmResponseText = "Couldn't open \(url.lastPathComponent) as an image."
            return
        }
        let draft = pendingImageQuestion
        let question = draft ?? "Describe this image in a few sentences."
        if let draft {
            lastSentPrompt = draft  // used once, so the next image gets described instead
        }
        promptImage = image
        // Each dropped image starts a new conversation, so earlier prompts can't steer what the model says
        // about it. Follow-up questions about the image then continue in this session.
        llmSession = LanguageModelSession(model: .default)
        appendLog("Started a new FoundationModels session for \(url.lastPathComponent)")
        await runOnDeviceModel(logLabel: "\(url.lastPathComponent) + \"\(question)\"", metricsPrompt: question) {
            question
            Attachment(imageURL: url)
        }
    }

    /// Streams one reply from the on-device model into `llmResponseText` and records ANE, GPU and CPU
    /// telemetry for it.
    private func runOnDeviceModel(
        logLabel: String,
        metricsPrompt promptToRun: String,
        @PromptBuilder prompt: () -> Prompt
    ) async {
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            foundationModelAvailability = Self.describeAvailability(availability)
            llmResponseText = foundationModelAvailability
            appendLog("FoundationModels: \(foundationModelAvailability)")
            return
        }

        isStreamingLLM = true
        llmResponseText = ""
        statusMessage = "Streaming from the On-Device Apple LLM..."
        appendLog("Prompt -> FoundationModels: \(logLabel)")

        let session: LanguageModelSession
        if let existing = llmSession {
            session = existing
        } else {
            let created = LanguageModelSession(model: .default)
            llmSession = created
            session = created
        }

        var s1 = telemetrySampler.takeSnapshot()

        do {
            let reply: (firstChunkMs: Double, elapsed: Double)
            do {
                reply = try await streamReply(in: session, prompt: prompt)
            } catch LanguageModelError.contextSizeExceeded {
                // The session keeps every earlier prompt and reply, though this panel only shows the latest.
                // Once that hidden history fills the model's context window every prompt fails, so start a
                // fresh session and send the prompt again.
                appendLog("FoundationModels context window full; started a new session and retried")
                let fresh = LanguageModelSession(model: .default)
                llmSession = fresh
                s1 = telemetrySampler.takeSnapshot()
                reply = try await streamReply(in: fresh, prompt: prompt)
            }
            let firstChunkMs = reply.firstChunkMs
            let elapsed = reply.elapsed
            let s2 = telemetrySampler.takeSnapshot()

            let wordCount = llmResponseText.split(whereSeparator: \.isWhitespace).count
            let estTokens = max(1, Int((Double(wordCount) * 1.33).rounded()))
            let tokPerSec = Double(estTokens) / elapsed

            if let snap1 = s1, let snap2 = s2 {
                let delta = telemetrySampler.computeDelta(from: snap1, to: snap2)
                let metrics = NeuralEnginePromptMetrics(
                    prompt: promptToRun,
                    responseText: llmResponseText,
                    elapsedSeconds: elapsed,
                    timeToFirstChunkMs: firstChunkMs,
                    estimatedTokens: estTokens,
                    tokensPerSecond: tokPerSec,
                    aneFabricBandwidthGBps: delta.aneFabricBandwidthGBps,
                    anePeakFabricBandwidthGBps: delta.anePeakFabricBandwidthGBps,
                    aneOverdrivePercent: delta.aneOverdriveResidencyPercent,
                    gpuPowerWatts: delta.gpuPowerWatts,
                    cpuPowerWatts: delta.cpuPowerWatts
                )
                lastLLMMetrics = metrics
                appendLog(String(
                    format: "FoundationModels Complete: ~%d tokens in %.2fs (%.1f tok/s, TTFT %.0f ms) | ANE Fabric Peak: %.0f GB/s (avg %.1f GB/s) | ANE Overdrive: %.1f%% | GPU Power: %.2f W",
                    estTokens, elapsed, tokPerSec, firstChunkMs,
                    delta.anePeakFabricBandwidthGBps, delta.aneFabricBandwidthGBps,
                    delta.aneOverdriveResidencyPercent, delta.gpuPowerWatts
                ))
                statusMessage = String(format: "LLM Complete (%.1f tok/s | %.1f%% ANE Overdrive | %.2fW GPU)", tokPerSec, delta.aneOverdriveResidencyPercent, delta.gpuPowerWatts)
            } else {
                statusMessage = "LLM Response Complete (\(String(format: "%.2f", elapsed))s)"
            }
        } catch {
            llmResponseText = "Error: \(error.localizedDescription)"
            appendLog("FoundationModels Error: \(error.localizedDescription)")
            statusMessage = "LLM Error: \(error.localizedDescription)"
        }

        isStreamingLLM = false
    }

    /// Streams one reply into `llmResponseText`, returning the time to the first text and the total time.
    private func streamReply(in session: LanguageModelSession, prompt: () -> Prompt) async throws -> (firstChunkMs: Double, elapsed: Double) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var firstChunkMs = 0.0
        for try await partial in session.streamResponse(prompt: prompt) {
            if firstChunkMs == 0 && !partial.content.isEmpty {
                firstChunkMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            }
            llmResponseText = partial.content
        }
        return (firstChunkMs, max(CFAbsoluteTimeGetCurrent() - t0, 1e-4))
    }

    public func startLiveTelemetry() {
        guard telemetryTimer == nil else { return }
        let sampler = self.telemetrySampler
        let source = DispatchSource.makeTimerSource(queue: telemetryQueue)
        source.schedule(deadline: .now() + 0.1, repeating: .milliseconds(400), leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            guard let sample = sampler.sampleNext() else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ingestSample(sample)
            }
        }
        source.resume()
        self.telemetryTimer = source
    }

    private func ingestSample(_ sample: TelemetrySample) {
        self.latestTelemetry = sample
        self.telemetryHistory.append(sample)
        if self.telemetryHistory.count > Self.historyLength {
            self.telemetryHistory.removeFirst(self.telemetryHistory.count - Self.historyLength)
        }

        // Update session peak-hold and cumulative counters
        self.peakANEFabricBW = max(self.peakANEFabricBW, sample.aneFabricBandwidthGBps)
        self.peakANEBucketGBps = max(self.peakANEBucketGBps, sample.anePeakFabricBandwidthGBps)
        self.peakANEDRAMBW = max(self.peakANEDRAMBW, sample.aneDRAMBandwidthGBps)
        self.peakANEOverdrivePct = max(self.peakANEOverdrivePct, sample.aneOverdriveResidencyPercent)
        self.peakGPUPowerWatts = max(self.peakGPUPowerWatts, sample.gpuPowerWatts)
        self.peakCPUPowerWatts = max(self.peakCPUPowerWatts, sample.cpuPowerWatts)

        if sample.aneFabricBandwidthGBps > 0.1 {
            let dt = sample.durationSeconds
            self.cumulativeANEFabricGB += sample.aneFabricBandwidthGBps * dt
            self.cumulativeANEDRAMGB += sample.aneDRAMBandwidthGBps * dt
            self.totalANEActiveSeconds += dt

            if self.activeBurstStart == nil {
                self.activeBurstStart = sample.timestamp
                self.activeBurstDuration = 0
                self.activeBurstWeightedBW = 0
                self.activeBurstPeakBucket = 0
                self.activeBurstWeightedOvd = 0
                self.activeBurstWeightedGPU = 0
            }
            self.activeBurstDuration += dt
            self.activeBurstWeightedBW += sample.aneFabricBandwidthGBps * dt
            self.activeBurstPeakBucket = max(self.activeBurstPeakBucket, sample.anePeakFabricBandwidthGBps)
            self.activeBurstWeightedOvd += sample.aneOverdriveResidencyPercent * dt
            self.activeBurstWeightedGPU += sample.gpuPowerWatts * dt

            if !self.isRunning && !self.isStreamingLLM {
                self.statusMessage = String(
                    format: "ANE0 Active: %.1f GB/s (Peak %.0f) • %.0f%% VMAX • GPU %.2f W",
                    sample.aneFabricBandwidthGBps,
                    sample.anePeakFabricBandwidthGBps,
                    sample.aneOverdriveResidencyPercent,
                    sample.gpuPowerWatts
                )
            }
        } else if let burstStart = self.activeBurstStart {
            let dur = max(self.activeBurstDuration, 0.05)
            let event = ANEBurstEvent(
                timestamp: burstStart,
                durationSeconds: dur,
                avgFabricGBps: self.activeBurstWeightedBW / dur,
                peakBucketGBps: self.activeBurstPeakBucket,
                avgOverdrivePct: self.activeBurstWeightedOvd / dur,
                dataMovedGB: self.activeBurstWeightedBW,
                avgGPUPowerWatts: self.activeBurstWeightedGPU / dur
            )
            self.aneBurstEvents.insert(event, at: 0)
            if self.aneBurstEvents.count > 40 {
                self.aneBurstEvents.removeLast(self.aneBurstEvents.count - 40)
            }
            self.activeBurstStart = nil
            if !self.isRunning && !self.isStreamingLLM {
                self.statusMessage = "Monitoring Live Silicon Telemetry (IOReport)"
            }
        }
    }

    public func resetSessionStats() {
        peakANEFabricBW = 0.0
        peakANEBucketGBps = 0.0
        peakANEDRAMBW = 0.0
        peakANEOverdrivePct = 0.0
        peakGPUPowerWatts = 0.0
        peakCPUPowerWatts = 0.0
        cumulativeANEFabricGB = 0.0
        cumulativeANEDRAMGB = 0.0
        totalANEActiveSeconds = 0.0
        aneBurstEvents.removeAll()
        telemetryHistory.removeAll()
        statusMessage = "Reset Session Peaks & History"
    }

    public func triggerQuickANEPulse() async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            statusMessage = "Monitoring Live Silicon Telemetry (IOReport)"
        }
        do {
            let artifact = try await prepareModelIfNeeded()
            let res = try await executeANEBenchmark(artifact: artifact, seconds: Self.pulseSeconds)
            if let idx = results.firstIndex(where: { $0.title == res.title }) {
                results[idx] = res
            } else {
                results.insert(res, at: 0)
            }
        } catch {
            appendLog("Quick ANE Pulse Error: \(error.localizedDescription)")
        }
    }

    public func appendLog(_ msg: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(msg)"
        logs.append(line)
        if echoLogsToStdout { print(line) }
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    public func prepareModelIfNeeded() async throws -> ANEModelArtifact {
        if let existing = modelArtifact {
            return existing
        }
        statusMessage = "Synthesizing & Compiling Core ML Spec v7 FP16 Model..."
        let artifact = try await Task.detached(priority: .userInitiated) {
            try await ANEModelBuilder.buildAndVerifyANEModel { msg in
                Task { @MainActor in
                    self.appendLog(msg)
                }
            }
        }.value
        self.modelArtifact = artifact
        statusMessage = "Compiled \(artifact.modelName) (\(artifact.aneAssignedCount)/\(artifact.layers.count) layers on ANE)"
        return artifact
    }

    public func runFullSuite() async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            statusMessage = "Benchmark Suite Complete"
        }

        results.removeAll()
        // Each benchmark runs on its own, so one failure (say, a GPU that can't compile the
        // Metal 4 kernels) doesn't skip the rest of the suite.
        let artifact: ANEModelArtifact?
        do {
            artifact = try await prepareModelIfNeeded()
        } catch {
            artifact = nil
            appendLog("Core ML model build failed, skipping the ANE, hybrid and CPU benchmarks: \(error.localizedDescription)")
        }

        let seconds = Self.benchmarkSeconds
        let hybridSeconds = Self.hybridSeconds
        if let artifact {
            await runStep("Neural Engine") { try await self.executeANEBenchmark(artifact: artifact, seconds: seconds) }
        }
        await runStep("GPU FP16") { try await self.executeGPUNeuralBenchmark(precision: .fp16, seconds: seconds) }
        await runStep("GPU INT8") { try await self.executeGPUNeuralBenchmark(precision: .int8, seconds: seconds) }
        if let artifact {
            await runStep("Hybrid") { try await self.executeHybridFusionBenchmark(artifact: artifact, seconds: hybridSeconds) }
            await runStep("CPU baseline") { try await self.executeCPUBaselineBenchmark(artifact: artifact, seconds: seconds) }
        }
    }

    public func runSingleTarget(_ target: String) async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            statusMessage = "Ready"
        }

        let seconds = Self.benchmarkSeconds
        let hybridSeconds = Self.hybridSeconds
        switch target {
        case "ANE":
            await runStep("Neural Engine") { try await self.executeANEBenchmark(artifact: self.prepareModelIfNeeded(), seconds: seconds) }
        case "GPU_FP16":
            await runStep("GPU FP16") { try await self.executeGPUNeuralBenchmark(precision: .fp16, seconds: seconds) }
        case "GPU_INT8":
            await runStep("GPU INT8") { try await self.executeGPUNeuralBenchmark(precision: .int8, seconds: seconds) }
        case "HYBRID":
            await runStep("Hybrid") { try await self.executeHybridFusionBenchmark(artifact: self.prepareModelIfNeeded(), seconds: hybridSeconds) }
        case "CPU":
            await runStep("CPU baseline") { try await self.executeCPUBaselineBenchmark(artifact: self.prepareModelIfNeeded(), seconds: seconds) }
        default:
            return
        }
    }

    /// Runs one benchmark and stores its result, replacing an earlier run of the same benchmark.
    /// A failure is logged rather than thrown, so the suite carries on with the next benchmark.
    private func runStep(_ name: String, _ benchmark: () async throws -> BenchmarkResult) async {
        do {
            let result = try await benchmark()
            if let idx = results.firstIndex(where: { $0.title == result.title }) {
                results[idx] = result
            } else {
                results.append(result)
            }
        } catch {
            appendLog("\(name) benchmark failed: \(error.localizedDescription)")
        }
    }

    private nonisolated static func runSyncPredictions(model: MLModel, provider: MLFeatureProvider, count: Int) throws {
        for _ in 0..<count {
            _ = try model.prediction(from: provider)
        }
    }

    /// Runs predictions until `deadline`, and at least `minimum` times so very slow devices still get a measurement.
    private nonisolated static func runPredictions(
        model: MLModel,
        provider: MLFeatureProvider,
        until deadline: CFAbsoluteTime,
        minimum: Int = 3
    ) throws -> (iterations: Int, elapsedSeconds: Double) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var count = 0
        repeat {
            _ = try model.prediction(from: provider)
            count += 1
        } while count < minimum || CFAbsoluteTimeGetCurrent() < deadline
        return (count, max(CFAbsoluteTimeGetCurrent() - t0, 1e-6))
    }

    private func executeANEBenchmark(artifact: ANEModelArtifact, seconds: Double) async throws -> BenchmarkResult {
        statusMessage = "Running \(hardware.aneName) (ANE0) FP16 Benchmark..."
        appendLog("Starting \(hardware.aneName) (\(hardware.coreAIArchitecture)) benchmark (\(String(format: "%.1f", seconds))s, \(String(format: "%.1f", artifact.gflopsPerIteration)) GFLOP/pass)...")

        let sampler = self.telemetrySampler
        let url = artifact.compiledURL
        let gflops = artifact.gflopsPerIteration

        let (iterations, elapsed, snapDelta) = try await Task.detached(priority: .userInitiated) { () -> (Int, Double, TelemetrySample) in
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: url, configuration: config)
            let inputArray = try MLMultiArray(shape: [1, NSNumber(value: artifact.channels), NSNumber(value: artifact.spatialSize), NSNumber(value: artifact.spatialSize)], dataType: .float16)
            let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: inputArray)])

            try Self.runSyncPredictions(model: model, provider: provider, count: 6)

            let s1 = sampler.takeSnapshot()
            let run = try Self.runPredictions(model: model, provider: provider, until: CFAbsoluteTimeGetCurrent() + seconds)
            let s2 = sampler.takeSnapshot()
            return (run.iterations, run.elapsedSeconds, sampler.computeDelta(from: s1, to: s2))
        }.value

        let tflops = (gflops * Double(iterations) / elapsed) / 1000.0
        let msPerIter = (elapsed / Double(iterations)) * 1000.0
        appendLog(String(format: "ANE0 Result: %.2f TFLOPS (%.2f ms/iter) | ANE Fabric BW: %.1f GB/s (Peak %.0f GB/s) | ANE Overdrive: %.1f%% | GPU Power: %.2f W",
                         tflops, msPerIter, snapDelta.aneFabricBandwidthGBps, snapDelta.anePeakFabricBandwidthGBps, snapDelta.aneOverdriveResidencyPercent, snapDelta.gpuPowerWatts))

        return BenchmarkResult(
            engine: .neuralEngine,
            title: "\(hardware.aneName) (ANE0)",
            subtitle: "Core ML Spec v7 (\(artifact.layerCount)× \(artifact.channels)ch \(artifact.kernelSize)×\(artifact.kernelSize) Conv) • .cpuAndNeuralEngine",
            engineBadge: "ANE0 (\(hardware.coreAIArchitecture))",
            precision: "FP16",
            throughputValue: tflops,
            throughputUnit: "TFLOPS",
            latencyMsPerIter: msPerIter,
            iterations: iterations,
            elapsedSeconds: elapsed,
            aneFabricBandwidthGBps: snapDelta.aneFabricBandwidthGBps,
            anePeakFabricBandwidthGBps: snapDelta.anePeakFabricBandwidthGBps,
            aneDRAMBandwidthGBps: snapDelta.aneDRAMBandwidthGBps,
            aneOverdrivePercent: snapDelta.aneOverdriveResidencyPercent,
            gpuPowerWatts: snapDelta.gpuPowerWatts,
            cpuPowerWatts: snapDelta.cpuPowerWatts
        )
    }

    private func executeGPUNeuralBenchmark(precision: MatMulPrecision, seconds: Double) async throws -> BenchmarkResult {
        let label = precision.rawValue
        statusMessage = "Running GPU Neural Accelerators (Metal 4 MPP \(label))..."
        appendLog("Starting \(hardware.gpuName) \(hardware.gpuShortName) benchmark (Metal 4 MPP matmul2d \(label), 4096×4096×4096, \(String(format: "%.1f", seconds))s)...")

        let sampler = self.telemetrySampler
        let (check, run, snapDelta) = try await Task.detached(priority: .userInitiated) { () -> (MatMulCheck, MatMulRun, TelemetrySample) in
            let engine = try Metal4NeuralAccelerator()
            // Check the kernel computes the right answer before trusting its throughput.
            let check = try engine.validate(precision)
            let dispatchesPerBuffer = try engine.calibrate(precision)
            let s1 = sampler.takeSnapshot()
            let run = try engine.run(precision, until: CFAbsoluteTimeGetCurrent() + seconds, dispatchesPerBuffer: dispatchesPerBuffer)
            let s2 = sampler.takeSnapshot()
            return (check, run, sampler.computeDelta(from: s1, to: s2))
        }.value

        let maxError = String(format: "%.3g", check.maxAbsError)
        if check.passed {
            appendLog("GPU \(label) output check passed: a \(check.size)×\(check.size) matmul matches the CPU reference (max error \(maxError))")
        } else {
            appendLog("GPU \(label) output check FAILED: max error \(maxError) against the CPU reference, so this result can't be trusted")
        }

        let unit = (precision == .int8) ? "TOPS" : "TFLOPS"
        let msPerIter = (run.elapsedSeconds / Double(max(run.iterations, 1))) * 1000.0
        appendLog(String(format: "GPU0 (%@) Result: %.2f %@ (%.2f ms/iter) | GPU Power: %.1f W | ANE Fabric BW: %.1f GB/s",
                         label, run.teraOpsPerSecond, unit, msPerIter, snapDelta.gpuPowerWatts, snapDelta.aneFabricBandwidthGBps))

        return BenchmarkResult(
            engine: .gpu,
            title: "GPU Neural Accelerators (\(label))",
            subtitle: "Metal 4 MPP matmul2d + cooperative_tensor (4096³)",
            engineBadge: hardware.gpuCoreCount > 0 ? "GPU0 (\(hardware.gpuCoreCount)-Core)" : "GPU0",
            precision: label,
            throughputValue: run.teraOpsPerSecond,
            throughputUnit: unit,
            latencyMsPerIter: msPerIter,
            iterations: run.iterations,
            elapsedSeconds: run.elapsedSeconds,
            aneFabricBandwidthGBps: snapDelta.aneFabricBandwidthGBps,
            anePeakFabricBandwidthGBps: snapDelta.anePeakFabricBandwidthGBps,
            aneDRAMBandwidthGBps: snapDelta.aneDRAMBandwidthGBps,
            aneOverdrivePercent: snapDelta.aneOverdriveResidencyPercent,
            gpuPowerWatts: snapDelta.gpuPowerWatts,
            cpuPowerWatts: snapDelta.cpuPowerWatts,
            outputVerified: check.passed
        )
    }

    private func executeHybridFusionBenchmark(artifact: ANEModelArtifact, seconds: Double) async throws -> BenchmarkResult {
        statusMessage = "Running Simultaneous Hybrid Fusion (ANE0 + GPU0)..."
        appendLog("Launching Simultaneous Hybrid Fusion for \(String(format: "%.1f", seconds))s: \(hardware.aneShortName) (FP16 Conv) + \(hardware.gpuShortName) (FP16 MatMul)...")

        let sampler = self.telemetrySampler
        let url = artifact.compiledURL
        let aneGflops = artifact.gflopsPerIteration

        let (elapsed, combinedTFLOPS, aneTFLOPS, gpuTFLOPS, totalIterations, snapDelta) = try await Task.detached(priority: .userInitiated) { () -> (Double, Double, Double, Double, Int, TelemetrySample) in
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            nonisolated(unsafe) let model = try MLModel(contentsOf: url, configuration: config)
            let inputArray = try MLMultiArray(shape: [1, NSNumber(value: artifact.channels), NSNumber(value: artifact.spatialSize), NSNumber(value: artifact.spatialSize)], dataType: .float16)
            nonisolated(unsafe) let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: inputArray)])
            try Self.runSyncPredictions(model: model, provider: provider, count: 4)

            let gpuEngine = try Metal4NeuralAccelerator()
            let dispatchesPerBuffer = try gpuEngine.calibrate(.fp16)

            // Both engines work until the same deadline, so the combined figure covers one shared window.
            let s1 = sampler.takeSnapshot()
            let t0 = CFAbsoluteTimeGetCurrent()
            let deadline = t0 + seconds
            async let aneRun = Self.runPredictions(model: model, provider: provider, until: deadline)
            async let gpuRun = gpuEngine.run(.fp16, until: deadline, dispatchesPerBuffer: dispatchesPerBuffer)
            let (ane, gpu) = try await (aneRun, gpuRun)
            let wallTime = CFAbsoluteTimeGetCurrent() - t0
            let s2 = sampler.takeSnapshot()

            let aneRate = (aneGflops * Double(ane.iterations) / ane.elapsedSeconds) / 1000.0
            let totalGFLOPs = aneGflops * Double(ane.iterations) + gpuEngine.gopsPerIteration * Double(gpu.iterations)
            // Report what was measured: all work done divided by wall-clock time.
            let wallTFLOPS = (totalGFLOPs / wallTime) / 1000.0
            return (wallTime, wallTFLOPS, aneRate, gpu.teraOpsPerSecond, ane.iterations + gpu.iterations, sampler.computeDelta(from: s1, to: s2))
        }.value

        appendLog(String(format: "Hybrid Fusion Result: %.2f TFLOPS Combined (ANE0: %.2f TFLOPS + GPU0: %.2f TFLOPS) | ANE Fabric BW: %.1f GB/s | GPU Power: %.1f W",
                         combinedTFLOPS, aneTFLOPS, gpuTFLOPS, snapDelta.aneFabricBandwidthGBps, snapDelta.gpuPowerWatts))

        return BenchmarkResult(
            engine: .hybrid,
            title: "Simultaneous Hybrid Fusion (ANE0 + GPU0)",
            subtitle: String(format: "Concurrent ANE (%.1f TF) + GPU (%.1f TF), wall-clock combined", aneTFLOPS, gpuTFLOPS),
            engineBadge: "ANE0 + GPU0",
            precision: "FP16",
            throughputValue: combinedTFLOPS,
            throughputUnit: "TFLOPS",
            latencyMsPerIter: (elapsed / Double(max(totalIterations, 1))) * 1000.0,
            iterations: totalIterations,
            elapsedSeconds: elapsed,
            aneFabricBandwidthGBps: snapDelta.aneFabricBandwidthGBps,
            anePeakFabricBandwidthGBps: snapDelta.anePeakFabricBandwidthGBps,
            aneDRAMBandwidthGBps: snapDelta.aneDRAMBandwidthGBps,
            aneOverdrivePercent: snapDelta.aneOverdriveResidencyPercent,
            gpuPowerWatts: snapDelta.gpuPowerWatts,
            cpuPowerWatts: snapDelta.cpuPowerWatts
        )
    }

    private func executeCPUBaselineBenchmark(artifact: ANEModelArtifact, seconds: Double) async throws -> BenchmarkResult {
        statusMessage = "Running CPU-Only Baseline (.cpuOnly) to Verify ANE Isolation..."
        appendLog("Running the same \(artifact.layerCount)-layer model forced to .cpuOnly for \(String(format: "%.1f", seconds))s to verify ANE stays at 0 GB/s...")

        let sampler = self.telemetrySampler
        let url = artifact.compiledURL
        let gflops = artifact.gflopsPerIteration

        let (iterations, elapsed, snapDelta) = try await Task.detached(priority: .userInitiated) { () -> (Int, Double, TelemetrySample) in
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: url, configuration: config)
            let inputArray = try MLMultiArray(shape: [1, NSNumber(value: artifact.channels), NSNumber(value: artifact.spatialSize), NSNumber(value: artifact.spatialSize)], dataType: .float16)
            let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: inputArray)])

            try Self.runSyncPredictions(model: model, provider: provider, count: 1)

            let s1 = sampler.takeSnapshot()
            let run = try Self.runPredictions(model: model, provider: provider, until: CFAbsoluteTimeGetCurrent() + seconds)
            let s2 = sampler.takeSnapshot()
            return (run.iterations, run.elapsedSeconds, sampler.computeDelta(from: s1, to: s2))
        }.value

        let tflops = (gflops * Double(iterations) / elapsed) / 1000.0
        let msPerIter = (elapsed / Double(iterations)) * 1000.0
        appendLog(String(format: "CPU Baseline Result (.cpuOnly): %.2f TFLOPS (%.2f ms/iter) | ANE Fabric BW: %.1f GB/s | ANE Overdrive: %.1f%%",
                         tflops, msPerIter, snapDelta.aneFabricBandwidthGBps, snapDelta.aneOverdriveResidencyPercent))

        return BenchmarkResult(
            engine: .cpu,
            title: "CPU Baseline (.cpuOnly)",
            subtitle: "Same \(artifact.layerCount)-Layer \(artifact.channels)ch \(artifact.kernelSize)×\(artifact.kernelSize) Model Restricted to CPU",
            engineBadge: "CPU (AMX/BNNS)",
            precision: "FP16/FP32",
            throughputValue: tflops,
            throughputUnit: "TFLOPS",
            latencyMsPerIter: msPerIter,
            iterations: iterations,
            elapsedSeconds: elapsed,
            aneFabricBandwidthGBps: snapDelta.aneFabricBandwidthGBps,
            anePeakFabricBandwidthGBps: snapDelta.anePeakFabricBandwidthGBps,
            aneDRAMBandwidthGBps: snapDelta.aneDRAMBandwidthGBps,
            aneOverdrivePercent: snapDelta.aneOverdriveResidencyPercent,
            gpuPowerWatts: snapDelta.gpuPowerWatts,
            cpuPowerWatts: snapDelta.cpuPowerWatts
        )
    }
}

import Foundation
import CoreML
import CoreAI

public struct LayerComputeAssignment: Identifiable, Sendable {
    public let id = UUID()
    public let index: Int
    public let name: String
    public let layerType: String
    public let shapeDescription: String
    public let preferredDevice: String
    public let isNeuralEngine: Bool
    public let supportedDevices: [String]
    public let gflopsPerForwardPass: Double
}

public struct ANEModelArtifact: Sendable {
    public let modelName: String
    public let compiledURL: URL
    public let channels: Int
    public let spatialSize: Int
    public let layerCount: Int
    public let kernelSize: Int
    public let gflopsPerIteration: Double
    public let compileDurationSeconds: Double
    /// True when the compiled model came from the cache, so nothing was compiled this run.
    public let usedCachedBuild: Bool
    public let layers: [LayerComputeAssignment]

    public var aneAssignedCount: Int {
        layers.filter(\.isNeuralEngine).count
    }
}

public enum ANEModelBuilder {
    /// Generates a Core ML Specification v7 (FP16) multi-layer convolution .mlmodel binary in pure Swift,
    /// compiles it on-device with `MLModel.compileModel(at:)`, and audits every layer via `MLComputePlan`.
    public static func buildAndVerifyANEModel(
        channels: Int = 512,
        spatialSize: Int = 64,
        layerCount: Int = 12,
        kernelSize: Int = 3,
        log: (@Sendable (String) -> Void)? = nil
    ) async throws -> ANEModelArtifact {
        let modelName = "ANE_Conv\(kernelSize)x\(kernelSize)_\(channels)ch_\(spatialSize)px_\(layerCount)L"
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("ANEScopeModels", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let mlmodelURL = workDir.appendingPathComponent("\(modelName).mlmodel")
        let compiledURL = workDir.appendingPathComponent("\(modelName).mlmodelc")

        let t0 = CFAbsoluteTimeGetCurrent()
        let usedCache = FileManager.default.fileExists(atPath: compiledURL.path)
        if !usedCache {
            log?("Synthesizing Core ML Spec v7 FP16 neural network (\(layerCount)x \(channels)ch \(kernelSize)x\(kernelSize) conv)...")
            let protoBytes = buildCoreMLSpecV7Protobuf(
                channels: channels,
                height: spatialSize,
                width: spatialSize,
                layerCount: layerCount,
                kernelSize: kernelSize
            )
            try protoBytes.write(to: mlmodelURL, options: .atomic)

            // Compile with Core ML itself rather than `xcrun coremlcompiler`, so Xcode isn't needed at runtime.
            log?("Compiling \(modelName).mlmodel with Core ML...")
            let compiledTemp = try await MLModel.compileModel(at: mlmodelURL)
            try FileManager.default.moveItem(at: compiledTemp, to: compiledURL)
        } else {
            log?("Using cached compiled ANE bundle at \(compiledURL.lastPathComponent)")
        }
        let compileTime = CFAbsoluteTimeGetCurrent() - t0

        // Inspect MLComputePlan with .cpuAndNeuralEngine
        log?("Auditing layer-by-layer hardware placement via MLComputePlan...")
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let plan = try await MLComputePlan.load(contentsOf: compiledURL, configuration: config)

        let layerGFLOPs = (2.0 * Double(channels) * Double(channels) * Double(kernelSize * kernelSize) * Double(spatialSize * spatialSize)) / 1e9
        var assignments: [LayerComputeAssignment] = []

        switch plan.modelStructure {
        case .neuralNetwork(let nn):
            for (idx, layer) in nn.layers.enumerated() {
                let isConv = layer.type == "convolution"
                let usage = plan.deviceUsage(for: layer)
                let prefDesc = describeDevice(usage?.preferred)
                let isANE = isNeuralEngineDevice(usage?.preferred)
                let supported = (usage?.supported ?? []).map { describeDevice($0) }
                assignments.append(
                    LayerComputeAssignment(
                        index: idx,
                        name: layer.name,
                        // Core ML can add layers of its own (such as an elementwise op on the FP16 input),
                        // so only the convolutions get the kernel label and a FLOP count.
                        layerType: isConv ? "convolution (FP16 \(kernelSize)×\(kernelSize))" : layer.type,
                        shapeDescription: "[1, \(channels), \(spatialSize), \(spatialSize)]",
                        preferredDevice: prefDesc,
                        isNeuralEngine: isANE,
                        supportedDevices: supported,
                        gflopsPerForwardPass: isConv ? layerGFLOPs : 0
                    )
                )
            }
        case .program(let prog):
            if let mainFn = prog.functions["main"] {
                for (idx, op) in mainFn.block.operations.enumerated() {
                    let usage = plan.deviceUsage(for: op)
                    let prefDesc = describeDevice(usage?.preferred)
                    let isANE = isNeuralEngineDevice(usage?.preferred)
                    let supported = (usage?.supported ?? []).map { describeDevice($0) }
                    assignments.append(
                        LayerComputeAssignment(
                            index: idx,
                            name: op.outputs.first?.name ?? "op_\(idx)",
                            layerType: op.operatorName,
                            shapeDescription: "[1, \(channels), \(spatialSize), \(spatialSize)]",
                            preferredDevice: prefDesc,
                            isNeuralEngine: isANE,
                            supportedDevices: supported,
                            gflopsPerForwardPass: layerGFLOPs
                        )
                    )
                }
            }
        default:
            break
        }

        let totalGFLOPs = layerGFLOPs * Double(layerCount)
        log?("MLComputePlan verified: \(assignments.filter(\.isNeuralEngine).count)/\(assignments.count) layers scheduled on the Neural Engine (\(AIModel.deviceArchitectureName))")

        return ANEModelArtifact(
            modelName: modelName,
            compiledURL: compiledURL,
            channels: channels,
            spatialSize: spatialSize,
            layerCount: layerCount,
            kernelSize: kernelSize,
            gflopsPerIteration: totalGFLOPs,
            compileDurationSeconds: compileTime,
            usedCachedBuild: usedCache,
            layers: assignments
        )
    }

    private static func isNeuralEngineDevice(_ device: MLComputeDevice?) -> Bool {
        guard let device else { return false }
        if case .neuralEngine = device { return true }
        return false
    }

    private static func describeDevice(_ device: MLComputeDevice?) -> String {
        guard let device else { return "Unknown" }
        switch device {
        case .neuralEngine(let ane):
            return "Neural Engine (\(ane.totalCoreCount)-Core \(AIModel.deviceArchitectureName))"
        case .gpu(let gpu):
            return "GPU (\(gpu.metalDevice?.name ?? "Apple GPU"))"
        case .cpu:
            return "CPU (BNNS / AMX)"
        @unknown default:
            return "Other"
        }
    }

    // MARK: - Pure Swift Core ML Spec v7 Protobuf Serializer

    private static func encodeVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while v > 0x7f {
            out.append(UInt8((v & 0x7f) | 0x80))
            v >>= 7
        }
        out.append(UInt8(v & 0x7f))
        return out
    }

    private static func encodeTag(field: Int, wireType: Int) -> Data {
        encodeVarint(UInt64((field << 3) | wireType))
    }

    private static func encodeUInt64(field: Int, value: UInt64) -> Data {
        var d = encodeTag(field: field, wireType: 0)
        d.append(encodeVarint(value))
        return d
    }

    private static func encodeMessage(field: Int, payload: Data) -> Data {
        var d = encodeTag(field: field, wireType: 2)
        d.append(encodeVarint(UInt64(payload.count)))
        d.append(payload)
        return d
    }

    private static func encodeString(field: Int, value: String) -> Data {
        encodeMessage(field: field, payload: Data(value.utf8))
    }

    private static func encodeArrayFeature(name: String, shape: [Int], dataType: UInt64 = 65552) -> Data {
        // 65552 == ArrayFeatureType.ArrayDataType.FLOAT16 in CoreML Spec v7+
        var arr = Data()
        for dim in shape {
            arr.append(encodeUInt64(field: 1, value: UInt64(dim)))
        }
        arr.append(encodeUInt64(field: 2, value: dataType))
        let featureType = encodeMessage(field: 5, payload: arr)
        var feat = encodeString(field: 1, value: name)
        feat.append(encodeMessage(field: 3, payload: featureType))
        return feat
    }

    private static func encodeConvLayer(
        name: String,
        input: String,
        output: String,
        inChannels: Int,
        outChannels: Int,
        kernelSize: Int
    ) -> Data {
        let weightCount = outChannels * inChannels * kernelSize * kernelSize
        // Small non-zero FP16 weight (0x1400) so activations stay well-scaled across 12 layers
        var weightBytes = Data(capacity: weightCount * 2)
        let pattern: [UInt8] = [0x00, 0x14]
        for _ in 0..<weightCount {
            weightBytes.append(contentsOf: pattern)
        }
        // WeightParams field 2 = float16Value (bytes)
        let weightsMsg = encodeMessage(field: 2, payload: weightBytes)

        var conv = Data()
        conv.append(encodeUInt64(field: 1, value: UInt64(outChannels))) // outputChannels
        conv.append(encodeUInt64(field: 2, value: UInt64(inChannels)))  // kernelChannels
        conv.append(encodeUInt64(field: 10, value: 1))                  // nGroups
        conv.append(encodeUInt64(field: 20, value: UInt64(kernelSize))) // kernelSize H
        conv.append(encodeUInt64(field: 20, value: UInt64(kernelSize))) // kernelSize W
        conv.append(encodeUInt64(field: 30, value: 1))                  // stride H
        conv.append(encodeUInt64(field: 30, value: 1))                  // stride W
        conv.append(encodeUInt64(field: 40, value: 1))                  // dilation H
        conv.append(encodeUInt64(field: 40, value: 1))                  // dilation W
        conv.append(encodeMessage(field: 51, payload: Data()))          // same padding (field 51)
        conv.append(encodeUInt64(field: 60, value: 0))                  // isDeconvolution = false
        conv.append(encodeUInt64(field: 61, value: 0))                  // hasBias = false
        conv.append(encodeMessage(field: 90, payload: weightsMsg))      // weights

        var layer = encodeString(field: 1, value: name)
        layer.append(encodeString(field: 2, value: input))
        layer.append(encodeString(field: 3, value: output))
        layer.append(encodeMessage(field: 100, payload: conv))
        return layer
    }

    private static func buildCoreMLSpecV7Protobuf(
        channels: Int,
        height: Int,
        width: Int,
        layerCount: Int,
        kernelSize: Int
    ) -> Data {
        var desc = Data()
        desc.append(encodeMessage(field: 1, payload: encodeArrayFeature(name: "input", shape: [1, channels, height, width])))
        desc.append(encodeMessage(field: 10, payload: encodeArrayFeature(name: "output", shape: [1, channels, height, width])))

        var nn = Data()
        var prev = "input"
        for i in 0..<layerCount {
            let next = (i == layerCount - 1) ? "output" : "h_\(i)"
            let layer = encodeConvLayer(
                name: String(format: "ane_conv_%02d", i),
                input: prev,
                output: next,
                inChannels: channels,
                outChannels: channels,
                kernelSize: kernelSize
            )
            nn.append(encodeMessage(field: 1, payload: layer))
            prev = next
        }
        // NeuralNetwork field 5 = arrayInputShapeMapping = EXACT_ARRAY_MAPPING (1)
        nn.append(encodeUInt64(field: 5, value: 1))

        var model = Data()
        model.append(encodeUInt64(field: 1, value: 7)) // specificationVersion = 7 (macOS 14+ / FP16 I/O)
        model.append(encodeMessage(field: 2, payload: desc))
        model.append(encodeMessage(field: 500, payload: nn))
        return model
    }
}

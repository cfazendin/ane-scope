import Foundation
import Metal

public enum MatMulPrecision: String, Sendable {
    case fp16 = "FP16"
    case int8 = "INT8"
}

/// Work done by one timed GPU run.
public struct MatMulRun: Sendable {
    public let iterations: Int
    public let elapsedSeconds: Double
    /// TFLOPS for FP16, TOPS for INT8.
    public let teraOpsPerSecond: Double
}

/// Result of checking the GPU kernel's output against a CPU reference.
public struct MatMulCheck: Sendable {
    public let size: Int
    public let maxAbsError: Double
    public let tolerance: Double
    public var passed: Bool { maxAbsError <= tolerance }
}

public final class Metal4NeuralAccelerator: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private let fp16Pipeline: MTLComputePipelineState
    private let int8Pipeline: MTLComputePipelineState

    public let matrixSize: Int = 4096
    public var gopsPerIteration: Double {
        2.0 * Double(matrixSize) * Double(matrixSize) * Double(matrixSize) / 1e9
    }

    private let fp16BufA: MTLBuffer
    private let fp16BufB: MTLBuffer
    private let fp16BufC: MTLBuffer

    private let int8BufA: MTLBuffer
    private let int8BufB: MTLBuffer
    private let int8BufC: MTLBuffer

    public init() throws {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            throw NSError(domain: "Metal4NeuralAccelerator", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No Metal device available"
            ])
        }
        self.device = dev
        self.commandQueue = queue

        let shaderSource = """
        #include <metal_stdlib>
        #include <metal_tensor>
        #include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>

        using namespace metal;
        using namespace mpp::tensor_ops;

        kernel void neuralMatMulCoopFP16(
            device half* bufA [[buffer(0)]],
            device half* bufB [[buffer(1)]],
            device half* bufC [[buffer(2)]],
            constant uint3& dims [[buffer(3)]],
            uint2 tgid [[threadgroup_position_in_grid]]
        ) {
            int M = int(dims.x);
            int N = int(dims.y);
            int K = int(dims.z);

            tensor<device half, dextents<int32_t, 2>, tensor_inline> A(bufA, dextents<int32_t, 2>(K, M));
            tensor<device half, dextents<int32_t, 2>, tensor_inline> B(bufB, dextents<int32_t, 2>(N, K));
            tensor<device half, dextents<int32_t, 2>, tensor_inline> C(bufC, dextents<int32_t, 2>(N, M));

            constexpr auto desc = matmul2d_descriptor(64, 64, static_cast<int>(dynamic_extent), false, false, true);
            matmul2d<desc, execution_simdgroups<4>> op;

            auto mA = A.slice(0, tgid.y * 64);
            auto mB = B.slice(tgid.x * 64, 0);
            auto mC = C.slice(tgid.x * 64, tgid.y * 64);

            auto cT = op.get_destination_cooperative_tensor<decltype(mA), decltype(mB), half>();
            #pragma clang loop unroll(full)
            for (uint16_t i = 0; i < cT.get_capacity(); ++i) {
                if (cT.is_valid_element(i)) cT[i] = 0;
            }
            op.run(mA, mB, cT);
            cT.store(mC);
        }

        kernel void neuralMatMulCoopINT8(
            device int8_t* bufA [[buffer(0)]],
            device int8_t* bufB [[buffer(1)]],
            device int32_t* bufC [[buffer(2)]],
            constant uint3& dims [[buffer(3)]],
            uint2 tgid [[threadgroup_position_in_grid]]
        ) {
            int M = int(dims.x);
            int N = int(dims.y);
            int K = int(dims.z);

            tensor<device int8_t, dextents<int32_t, 2>, tensor_inline> A(bufA, dextents<int32_t, 2>(K, M));
            tensor<device int8_t, dextents<int32_t, 2>, tensor_inline> B(bufB, dextents<int32_t, 2>(N, K));
            tensor<device int32_t, dextents<int32_t, 2>, tensor_inline> C(bufC, dextents<int32_t, 2>(N, M));

            constexpr auto desc = matmul2d_descriptor(64, 64, static_cast<int>(dynamic_extent), false, false, true);
            matmul2d<desc, execution_simdgroups<4>> op;

            auto mA = A.slice(0, tgid.y * 64);
            auto mB = B.slice(tgid.x * 64, 0);
            auto mC = C.slice(tgid.x * 64, tgid.y * 64);

            auto cT = op.get_destination_cooperative_tensor<decltype(mA), decltype(mB), int32_t>();
            #pragma clang loop unroll(full)
            for (uint16_t i = 0; i < cT.get_capacity(); ++i) {
                if (cT.is_valid_element(i)) cT[i] = 0;
            }
            op.run(mA, mB, cT);
            cT.store(mC);
        }
        """

        let options = MTLCompileOptions()
        options.languageVersion = .version4_0
        let library = try dev.makeLibrary(source: shaderSource, options: options)

        guard let fn16 = library.makeFunction(name: "neuralMatMulCoopFP16"),
              let fn8 = library.makeFunction(name: "neuralMatMulCoopINT8") else {
            throw NSError(domain: "Metal4NeuralAccelerator", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to load Metal 4 MPP matmul2d functions"
            ])
        }

        self.fp16Pipeline = try dev.makeComputePipelineState(function: fn16)
        self.int8Pipeline = try dev.makeComputePipelineState(function: fn8)

        func makeBuffer(_ length: Int) throws -> MTLBuffer {
            guard let buffer = dev.makeBuffer(length: length, options: .storageModePrivate) else {
                throw NSError(domain: "Metal4NeuralAccelerator", code: -3, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to allocate a \(length / (1024 * 1024)) MB Metal buffer"
                ])
            }
            return buffer
        }

        let M = matrixSize
        self.fp16BufA = try makeBuffer(M * M * 2)
        self.fp16BufB = try makeBuffer(M * M * 2)
        self.fp16BufC = try makeBuffer(M * M * 2)

        self.int8BufA = try makeBuffer(M * M * 1)
        self.int8BufB = try makeBuffer(M * M * 1)
        self.int8BufC = try makeBuffer(M * M * 4)
    }

    /// Warms up the kernel and returns how many dispatches fill about 50 ms of GPU time, so a timed
    /// run can stop close to its deadline on any GPU.
    public func calibrate(_ precision: MatMulPrecision) throws -> Int {
        let (pipeline, a, b, c) = resources(for: precision)
        try waitChecked(encode(pipeline, a, b, c, size: matrixSize, dispatches: 2))
        let t0 = CFAbsoluteTimeGetCurrent()
        try waitChecked(encode(pipeline, a, b, c, size: matrixSize, dispatches: 4))
        let perDispatch = max((CFAbsoluteTimeGetCurrent() - t0) / 4, 1e-5)
        return max(1, min(64, Int(0.05 / perDispatch)))
    }

    /// Runs the matmul until `deadline`. Two command buffers stay in flight so the GPU never waits on
    /// the CPU, and each holds `dispatchesPerBuffer` dispatches so live telemetry sees steady progress.
    public func run(_ precision: MatMulPrecision, until deadline: CFAbsoluteTime, dispatchesPerBuffer: Int) throws -> MatMulRun {
        let (pipeline, a, b, c) = resources(for: precision)
        let chunk = max(1, dispatchesPerBuffer)
        let t0 = CFAbsoluteTimeGetCurrent()
        var completed = 0
        var inFlight: [MTLCommandBuffer] = []
        while true {
            while inFlight.count < 2, CFAbsoluteTimeGetCurrent() < deadline,
                  let buffer = encode(pipeline, a, b, c, size: matrixSize, dispatches: chunk) {
                inFlight.append(buffer)
            }
            guard !inFlight.isEmpty else { break }
            try waitChecked(inFlight.removeFirst())
            completed += chunk
        }
        let elapsed = max(CFAbsoluteTimeGetCurrent() - t0, 1e-6)
        return MatMulRun(
            iterations: completed,
            elapsedSeconds: elapsed,
            teraOpsPerSecond: gopsPerIteration * Double(completed) / elapsed / 1000.0
        )
    }

    /// Multiplies two known `size`×`size` matrices with the benchmark kernel and compares the result
    /// with a CPU reference, so the throughput figure can be trusted to come from correct math. The
    /// inputs are small multiples of 1/4 and 1/2, so every FP16 product and partial sum is exact.
    public func validate(_ precision: MatMulPrecision, size n: Int = 256) throws -> MatMulCheck {
        let count = n * n
        let aValues = (0..<count).map { Double($0 % 7 - 3) }
        let bValues = (0..<count).map { Double($0 % 5 - 2) }

        let inputBytes = precision == .fp16 ? 2 : 1
        let outputBytes = precision == .fp16 ? 2 : 4
        guard let bufA = device.makeBuffer(length: count * inputBytes, options: .storageModeShared),
              let bufB = device.makeBuffer(length: count * inputBytes, options: .storageModeShared),
              let bufC = device.makeBuffer(length: count * outputBytes, options: .storageModeShared) else {
            throw Self.failure(-4, "Failed to allocate Metal buffers for the output check")
        }

        // FP16 inputs are scaled by 1/4 and 1/2, so the expected products are scaled by 1/8.
        let scale = precision == .fp16 ? 0.125 : 1.0
        switch precision {
        case .fp16:
            let a = bufA.contents().bindMemory(to: Float16.self, capacity: count)
            let b = bufB.contents().bindMemory(to: Float16.self, capacity: count)
            for i in 0..<count {
                a[i] = Float16(aValues[i] * 0.25)
                b[i] = Float16(bValues[i] * 0.5)
            }
        case .int8:
            let a = bufA.contents().bindMemory(to: Int8.self, capacity: count)
            let b = bufB.contents().bindMemory(to: Int8.self, capacity: count)
            for i in 0..<count {
                a[i] = Int8(aValues[i])
                b[i] = Int8(bValues[i])
            }
        }

        let (pipeline, _, _, _) = resources(for: precision)
        try waitChecked(encode(pipeline, bufA, bufB, bufC, size: n, dispatches: 1))

        let gpu: [Double]
        switch precision {
        case .fp16:
            let c = bufC.contents().bindMemory(to: Float16.self, capacity: count)
            gpu = (0..<count).map { Double(c[$0]) }
        case .int8:
            let c = bufC.contents().bindMemory(to: Int32.self, capacity: count)
            gpu = (0..<count).map { Double(c[$0]) }
        }

        // CPU reference, all row-major: C[row][col] = Σk A[row][k] · B[k][col].
        var maxError = 0.0
        var expected = [Double](repeating: 0, count: n)
        for row in 0..<n {
            for col in 0..<n { expected[col] = 0 }
            for k in 0..<n {
                let a = aValues[row * n + k]
                if a == 0 { continue }
                for col in 0..<n {
                    expected[col] += a * bValues[k * n + col]
                }
            }
            for col in 0..<n {
                maxError = max(maxError, abs(gpu[row * n + col] - expected[col] * scale))
            }
        }
        // INT8 must match exactly; FP16 gets a little room in case a GPU accumulates at lower precision.
        return MatMulCheck(size: n, maxAbsError: maxError, tolerance: precision == .fp16 ? 0.5 : 0)
    }

    private func resources(for precision: MatMulPrecision) -> (MTLComputePipelineState, MTLBuffer, MTLBuffer, MTLBuffer) {
        switch precision {
        case .fp16: return (fp16Pipeline, fp16BufA, fp16BufB, fp16BufC)
        case .int8: return (int8Pipeline, int8BufA, int8BufB, int8BufC)
        }
    }

    /// Encodes and commits one command buffer holding `dispatches` back-to-back n×n×n matmuls.
    private func encode(
        _ pipeline: MTLComputePipelineState,
        _ a: MTLBuffer,
        _ b: MTLBuffer,
        _ c: MTLBuffer,
        size n: Int,
        dispatches: Int
    ) -> MTLCommandBuffer? {
        guard let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder() else { return nil }
        var dims = SIMD3<UInt32>(UInt32(n), UInt32(n), UInt32(n))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(a, offset: 0, index: 0)
        encoder.setBuffer(b, offset: 0, index: 1)
        encoder.setBuffer(c, offset: 0, index: 2)
        encoder.setBytes(&dims, length: MemoryLayout<SIMD3<UInt32>>.size, index: 3)
        let grid = MTLSize(width: n / 64, height: n / 64, depth: 1)
        let threads = MTLSize(width: pipeline.threadExecutionWidth * 4, height: 1, depth: 1)
        for _ in 0..<dispatches {
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: threads)
        }
        encoder.endEncoding()
        buffer.commit()
        return buffer
    }

    /// Waits for a committed command buffer and surfaces any GPU error, so failed work is never counted.
    private func waitChecked(_ buffer: MTLCommandBuffer?) throws {
        guard let buffer else { throw Self.failure(-5, "Failed to create a Metal command buffer") }
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw error }
    }

    private static func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "Metal4NeuralAccelerator", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

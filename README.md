# ANE-Scope

A live hardware monitor and benchmark suite for the Apple Neural Engine (ANE) and the Metal 4 GPU tensor hardware on Apple silicon Macs.

ANE-Scope reads undocumented IOReport counters without `sudo`, so you can watch ANE bandwidth, voltage states and SoC power while a model runs. It also checks where Core ML places each layer of a model, and benchmarks the ANE, the GPU, both at once, and a CPU baseline. It runs as a SwiftUI dashboard or from the terminal.

## What it shows

**Live telemetry**, sampled every 400 ms from IOReport and the IORegistry:

| Reading | Source |
| --- | --- |
| ANE fabric bandwidth (read, write, peak bucket) | `PMP / AF BW`: `ANE… RD+WR` |
| ANE DRAM bandwidth | `PMP / DCS BW`: `ANE… RD+WR` |
| ANE voltage-state residency (VMIN, VNOM, VMAX, VOVD) | `PMP / SOC Floor`: `ANE…AF-BW` |
| GPU power | `Energy Model`: `GPU Energy` |
| CPU cluster power (PACC, MACC, EACC, SRAM) | `PMP / Energy` |
| GPU utilization and memory, ANE power-gate state | IORegistry: `IOAccelerator`, `H11ANEIn` |

A burst detector logs every stretch of ANE activity, whichever process causes it.

**Benchmarks**

Each benchmark runs for a set time (2 seconds, or 3 for the hybrid run) instead of a set number of passes, so the suite takes about as long on any chip. If one benchmark fails, the rest still run.

- **Neural Engine.** A 12-layer, 512-channel 3×3 convolution network (FP16, 64×64 input, about 232 GFLOP per pass). ANE-Scope writes the Core ML spec v7 protobuf directly in Swift, with no Python or coremltools, and compiles it on-device with Core ML.
- **`MLComputePlan` audit.** Lists the compute device Core ML prefers for each layer, so you can confirm the model really runs on the ANE.
- **GPU.** FP16 and INT8 4096³ matrix multiplies written with Metal 4 `MetalPerformancePrimitives` (`matmul2d` with `cooperative_tensor`). On M5-family chips these use the GPU's per-core Neural Accelerators. Before timing, each kernel multiplies two known 256×256 matrices and checks the answer against a CPU reference. If the check fails, the result is flagged.
- **Hybrid.** The ANE model and the GPU matmul run side by side until the same deadline. The result is total work divided by wall-clock time.
- **CPU baseline.** The same model restricted to `.cpuOnly`, which should leave ANE bandwidth at 0.

**On-device LLM.** Streams replies from Apple's `FoundationModels` system model and records time to first token, estimated tokens per second, ANE bandwidth, voltage residency and power for each reply.

- **Images.** Drop an image on the chat panel and the model describes it. If you've typed a question in the prompt box and haven't sent it yet, the model answers that question about the image instead; the highlight shown while you drag says which it will do. Each dropped image starts a new conversation, so follow-up questions are about that image. This needs a Mac whose on-device model accepts images.
## Requirements

- An Apple silicon Mac running macOS 27 or later
- Xcode 27 or later to build (Swift 6 and the macOS 27 SDK)
- Apple Intelligence turned on, for the LLM features

## Build and run

```bash
swift build -c release
```

Open the dashboard:

```bash
.build/release/ane-scope
```

Run the full benchmark suite and layer audit in the terminal:

```bash
.build/release/ane-scope --cli
```

Watch live telemetry in the terminal (press Ctrl-C to stop):

```bash
.build/release/ane-scope --monitor
```

Or log it as CSV, here every 500 ms:

```bash
.build/release/ane-scope --monitor --csv --interval 500 > ane-log.csv
```

Send one prompt to the on-device model and print the hardware telemetry for it:

```bash
.build/release/ane-scope --prompt "Explain how unified memory helps neural networks."
```

The first ANE run builds and compiles the test model, then caches it in `$TMPDIR/ANEScopeModels`.

## Caveats

- **Private API.** IOReport isn't public. ANE-Scope links `libIOReport` and declares its functions with `@_silgen_name`, so it can't ship on the Mac App Store, and any macOS update can change or remove the counters.
- **Interpretation.** Channel names and states vary between chips and OS releases. Labels like "overdrive" (time in VMAX or VOVD) are best-effort readings of undocumented data, not Apple's terms.
- **Estimates.** The SLC hit ratio is estimated as 1 − (ANE DRAM bandwidth ÷ ANE fabric bandwidth). LLM token counts are estimated as words × 1.33, because FoundationModels doesn't report them.
- **Benchmark scope.** Throughput figures are for these synthetic workloads. They aren't comparable to Apple's peak TOPS ratings.

## License

MIT. See [LICENSE](LICENSE).

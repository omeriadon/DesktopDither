import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
@testable import DesktopDither

// Opt in with DESKTOP_GLOW_BENCHMARK=1. GPU timestamps measure renderer work,
// excluding WindowServer composition, display scanout, and system GPU activity.
@Test
func measureRendererGPUCost() throws {
    guard ProcessInfo.processInfo.environment["DESKTOP_GLOW_BENCHMARK"] == "1" else {
        return
    }
    let renderer = try DitherMetalRenderer()
    let width = 3024
    let height = 1964
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.storageMode = .private
    descriptor.usage = [.renderTarget]
    let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
    var configuration = DitherConfiguration()
    configuration.intro = false
    let cases: [(mode: Int, speed: Float)] = [
        (6, 0.05), (7, 0.05), (6, 0.01), (7, 0.01), (6, 0), (7, 0)
    ]
    var samples = [[Double]](repeating: [], count: cases.count)
    // Interleave settings to reduce bias from GPU clock and thermal drift.
    for frame in 0..<100 {
        for index in cases.indices {
            configuration.ditherMode = cases[index].mode
            configuration.waveSpeed = cases[index].speed
            try renderer.render(
                to: texture,
                width: width,
                height: height,
                cell: 4,
                configuration: configuration,
                advance: false,
                atTime: Float(frame) / 30
            )
            if frame >= 20, let elapsed = renderer.lastRenderMetrics?.gpuElapsed {
                samples[index].append(elapsed * 1_000)
            }
        }
    }
    for index in cases.indices {
        #expect(samples[index].count == 80)
        let sorted = samples[index].sorted()
        let median = sorted[sorted.count / 2]
        print("GPU_BENCHMARK mode=\(cases[index].mode) speed=\(cases[index].speed) median_ms=\(median) samples=\(sorted.count)")
    }
}

@Test
func measureTopBlurGPUCostAndWriteInspectionCrops() throws {
    guard ProcessInfo.processInfo.environment["DESKTOP_GLOW_BENCHMARK"] == "1" else {
        return
    }
    let width = 3024
    let height = 1964
    let sharpRenderer = try DitherMetalRenderer(usesTopBlur: false, blurScale: 2)
    let blurredRenderer = try DitherMetalRenderer(usesTopBlur: true, blurScale: 2)
    let sharp = try makeBenchmarkTexture(device: sharpRenderer.device, width: width, height: height)
    let blurred = try makeBenchmarkTexture(device: blurredRenderer.device, width: width, height: height)
    var configuration = DitherConfiguration()
    configuration.intro = false
    configuration.ditherMode = 6
    configuration.waveAmplitude = 0.8
    var samples = [[Double](), [Double]()]
    for frame in 0..<60 {
        let order = frame.isMultiple(of: 2) ? [0, 1] : [1, 0]
        for path in order {
            let renderer = path == 0 ? sharpRenderer : blurredRenderer
            let target = path == 0 ? sharp : blurred
            try renderer.render(to: target, width: width, height: height, cell: 4, configuration: configuration, scale: 2, advance: false, atTime: Float(frame) / 30)
            if frame >= 10, let gpu = renderer.lastRenderMetrics?.gpuElapsed {
                samples[path].append(gpu * 1_000)
            }
        }
    }
    let result: [String: Any] = [
        "width": width,
        "height": height,
        "scale": 2,
        "cell": 4,
        "strip_points": DitherMetalRenderer.topBlurStripPoints,
        "maximum_sigma": DitherMetalRenderer.topBlurMaximumSigma,
        "gaussian_sigmas": DitherMetalRenderer.topBlurGaussianSigmas,
        "sharp_gpu_ms": samples[0],
        "blur_gpu_ms": samples[1]
    ]
    if let output = ProcessInfo.processInfo.environment["DESKTOP_GLOW_BLUR_BENCHMARK_OUTPUT"] {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
    }
    print("TOP_BLUR_BENCHMARK sharp_median_ms=\(median(samples[0])) blur_median_ms=\(median(samples[1])) samples=\(samples[0].count)")
    #expect(samples.allSatisfy { $0.count == 50 })

    let cropWidth = 640
    let cropHeight = 320
    let cropSharp = try makeSharedBenchmarkTexture(device: sharpRenderer.device, width: cropWidth, height: cropHeight)
    let cropBlurred = try makeSharedBenchmarkTexture(device: blurredRenderer.device, width: cropWidth, height: cropHeight)
    try sharpRenderer.render(to: cropSharp, width: cropWidth, height: cropHeight, cell: 8, configuration: configuration, scale: 2, advance: false, atTime: 2)
    try blurredRenderer.render(to: cropBlurred, width: cropWidth, height: cropHeight, cell: 8, configuration: configuration, scale: 2, advance: false, atTime: 2)
    if let directory = ProcessInfo.processInfo.environment["DESKTOP_GLOW_BLUR_BENCHMARK_ARTIFACTS"] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try writePNG(texture: cropSharp, width: cropWidth, height: cropHeight, to: URL(fileURLWithPath: directory).appendingPathComponent("top-blur-sharp.png"))
        try writePNG(texture: cropBlurred, width: cropWidth, height: cropHeight, to: URL(fileURLWithPath: directory).appendingPathComponent("top-blur-blurred.png"))
    }
}

private func writePNG(texture: MTLTexture, width: Int, height: Int, to url: URL) throws {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "DesktopDitherTests", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "DesktopDitherTests", code: 2)
    }
}

private func makeSharedBenchmarkTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget, .shaderRead]
    return try #require(device.makeTexture(descriptor: descriptor))
}

// Previous: preserved first optimization. Current: shared paired gradients, no atlas.
// Optimized: shared paired gradients plus coverage atlas and grid join masks.
@Test
func measureFusedFieldAndCellPass() throws {
    guard ProcessInfo.processInfo.environment["DESKTOP_GLOW_BENCHMARK"] == "1" else {
        return
    }
    let width = 3024
    let height = 1964
    let previousRenderer = try PreviousDitherMetalRenderer(usesFusedFieldAndCellPass: true)
    let referenceRenderer = try DitherMetalRenderer(usesFusedFieldAndCellPass: true, usesCoverageAtlas: false, usesTopBlur: false)
    let optimizedRenderer = try DitherMetalRenderer(usesFusedFieldAndCellPass: true, usesTopBlur: false)
    let previousTexture = try makeBenchmarkTexture(device: previousRenderer.device, width: width, height: height)
    let referenceTexture = try makeBenchmarkTexture(device: referenceRenderer.device, width: width, height: height)
    let optimizedTexture = try makeBenchmarkTexture(device: optimizedRenderer.device, width: width, height: height)
    var configuration = DitherConfiguration()
    configuration.intro = false
    configuration.colorNum = 5
    configuration.waveFrequency = 1.7
    configuration.waveAmplitude = 0.62
    configuration.scale = 0.8
    configuration.contrast = 1.2
    configuration.brightness = -0.08
    configuration.palette = [
        SIMD3<Float>(0.95, 0.1, 0.2),
        SIMD3<Float>(0.1, 0.8, 0.35),
        SIMD3<Float>(0.2, 0.35, 0.95)
    ]
    let cases: [(mode: Int, gap: Float, cornerRadius: Float, join: Bool, cell: Int)] = [
        (0, 0, 0, false, 4),
        (3, 0.18, 0.32, false, 4),
        (6, 0, 0.32, true, 4),
        (7, 0, 0, false, 4),
        (0, 0, 0, false, 16),
        (6, 0, 0.32, true, 16)
    ]
    var previousCPUSamples = [[Double]](repeating: [], count: cases.count)
    var currentCPUSamples = [[Double]](repeating: [], count: cases.count)
    var optimizedCPUSamples = [[Double]](repeating: [], count: cases.count)
    var previousSamples = [[Double]](repeating: [], count: cases.count)
    var referenceSamples = [[Double]](repeating: [], count: cases.count)
    var optimizedSamples = [[Double]](repeating: [], count: cases.count)

    for frame in 0..<70 {
        for index in cases.indices {
            let testCase = cases[index]
            configuration.ditherMode = testCase.mode
            configuration.gap = testCase.gap
            configuration.cornerRadius = testCase.cornerRadius
            configuration.joinAdjacentSquares = testCase.join
            let fixedTime = Float(frame) / 30

            let order: [Int] = switch frame % 3 {
            case 0: [0, 1, 2]
            case 1: [1, 2, 0]
            default: [2, 0, 1]
            }
            for path in order {
                switch path {
                case 0:
                    try previousRenderer.render(
                        to: previousTexture,
                        width: width,
                        height: height,
                        cell: testCase.cell,
                        configuration: configuration,
                        advance: false,
                        atTime: fixedTime
                    )
                    if frame >= 10, let elapsed = previousRenderer.lastRenderMetrics?.gpuElapsed {
                        previousSamples[index].append(elapsed * 1_000)
                        previousCPUSamples[index].append(previousRenderer.lastRenderMetrics!.cpuElapsed * 1_000)
                    }
                case 1:
                    try referenceRenderer.render(
                        to: referenceTexture,
                        width: width,
                        height: height,
                        cell: testCase.cell,
                        configuration: configuration,
                        advance: false,
                        atTime: fixedTime
                    )
                    if frame >= 10, let elapsed = referenceRenderer.lastRenderMetrics?.gpuElapsed {
                        referenceSamples[index].append(elapsed * 1_000)
                        currentCPUSamples[index].append(referenceRenderer.lastRenderMetrics!.cpuElapsed * 1_000)
                    }
                default:
                    try optimizedRenderer.render(
                        to: optimizedTexture,
                        width: width,
                        height: height,
                        cell: testCase.cell,
                        configuration: configuration,
                        advance: false,
                        atTime: fixedTime
                    )
                    if frame >= 10, let elapsed = optimizedRenderer.lastRenderMetrics?.gpuElapsed {
                        optimizedSamples[index].append(elapsed * 1_000)
                        optimizedCPUSamples[index].append(optimizedRenderer.lastRenderMetrics!.cpuElapsed * 1_000)
                    }
                }
            }

        }
    }

    if let output = ProcessInfo.processInfo.environment["DESKTOP_GLOW_BENCHMARK_OUTPUT"] {
        let results: [[String: Any]] = cases.indices.map { index in
            [
                "mode": cases[index].mode,
                "gap": cases[index].gap,
                "cornerRadius": cases[index].cornerRadius,
                "join": cases[index].join,
                "cell": cases[index].cell,
                "previous_ms": previousSamples[index],
                "previous_cpu_ms": previousCPUSamples[index],
                "current_cpu_ms": currentCPUSamples[index],
                "optimized_cpu_ms": optimizedCPUSamples[index],
                "current_ms": referenceSamples[index],
                "optimized_ms": optimizedSamples[index]
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["width": width, "height": height, "results": results], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
    }
    for index in cases.indices {
        try #require(previousSamples[index].count == 60)
        try #require(referenceSamples[index].count == 60)
        try #require(optimizedSamples[index].count == 60)
        let previousMedian = median(previousSamples[index])
        let referenceMedian = median(referenceSamples[index])
        let optimizedMedian = median(optimizedSamples[index])
        let speedup = referenceMedian / optimizedMedian
        print(
            "FUSED_BENCHMARK mode=\(cases[index].mode) gap=\(cases[index].gap) "
                + "corner=\(cases[index].cornerRadius) join=\(cases[index].join) cell=\(cases[index].cell) "
                + "previous_ms=\(previousMedian) current_ms=\(referenceMedian) optimized_ms=\(optimizedMedian) "
                + "speedup=\(speedup) samples=\(optimizedSamples[index].count)"
        )
        #expect(previousSamples[index].count == 60)
        #expect(referenceSamples[index].count == 60)
        #expect(optimizedSamples[index].count == 60)
    }
}

private func makeBenchmarkTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.storageMode = .private
    descriptor.usage = [.renderTarget]
    return try #require(device.makeTexture(descriptor: descriptor))
}

private func median(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted[sorted.count / 2]
}

@Test @MainActor
func measureLiveRenderCadence() throws {
    guard ProcessInfo.processInfo.environment["DESKTOP_GLOW_BENCHMARK"] == "1" else {
        return
    }
    _ = NSApplication.shared
    let view = DitherPreviewView(frame: NSRect(x: 0, y: 0, width: 128, height: 80))
    let window = NSWindow(
        contentRect: view.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderBack(nil)
    defer {
        view.setActive(false)
        window.close()
    }
    var configuration = DitherConfiguration()
    configuration.intro = false
    for speed: Float in [0.05, 0.01, 0] {
        configuration.waveSpeed = speed
        view.setConfiguration(configuration)
        view.setActive(true)
        let startFrames = view.renderedFrames
        let start = Date()
        let deadline = start.addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
        let elapsed = Date().timeIntervalSince(start)
        let count = view.renderedFrames - startFrames
        print("CADENCE_BENCHMARK speed=\(speed) frames=\(count) seconds=\(elapsed) fps=\(Double(count) / elapsed)")
        #expect(view.lastRenderError == nil)
        if speed == 0 {
            #expect(count == 0)
        }
        view.setActive(false)
    }
}

@Test
func measureRendererInitializationAndSharedResources() throws {
    guard ProcessInfo.processInfo.environment["DESKTOP_GLOW_BENCHMARK"] == "1" else {
        return
    }
    let coldStart = CACurrentMediaTime()
    _ = try PreviousDitherMetalRenderer()
    let previousElapsed = CACurrentMediaTime() - coldStart

    let firstStart = CACurrentMediaTime()
    let firstRenderer = try DitherMetalRenderer()
    let firstElapsed = CACurrentMediaTime() - firstStart

    var warmElapsed: [Double] = []
    var resourceIdentifiers: [ObjectIdentifier] = [firstRenderer.sharedGradientResourceIdentifier]
    for _ in 0..<8 {
        let start = CACurrentMediaTime()
        let renderer = try DitherMetalRenderer()
        warmElapsed.append(CACurrentMediaTime() - start)
        resourceIdentifiers.append(renderer.sharedGradientResourceIdentifier)
    }
    let sortedWarm = warmElapsed.sorted()
    let warmMedian = sortedWarm[sortedWarm.count / 2]
    print(
        "INITIALIZATION_BENCHMARK previous_cold_ms=\(previousElapsed * 1_000) "
            + "shared_first_ms=\(firstElapsed * 1_000) "
            + "shared_warm_median_ms=\(warmMedian * 1_000) "
            + "shared_gradient_count=\(Set(resourceIdentifiers).count)"
    )
    #expect(Set(resourceIdentifiers).count == 1)
}

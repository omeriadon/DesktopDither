import AppKit
import Foundation
import Metal
import MetalPerformanceShaders
import QuartzCore
import simd

private struct FieldUniforms {
    var resolution: SIMD2<Float>
    var cell: Float
    var time: Float
    var waveSpeed: Float
    var waveDirection: SIMD2<Float>
    var waveFrequency: Float
    var waveAmplitude: Float
    var scale: Float
    var contrast: Float
    var brightness: Float
    var intro: Float
    var reach: Float
}

private struct DitherUniforms {
    var fieldSize: SIMD2<Int32>
    var cellDevice: Float
    var mode: Int32
    var colorNum: Float
    var ditherStrength: Float
    var wave: SIMD3<Float>
    var background: SIMD3<Float>
    var paletteCount: Int32
    var transparent: Float
    var gap: Float
    var cornerRadius: Float
    var joinAdjacentSquares: Int32
    var viewportSize: SIMD2<Int32>
}

private struct TopBlurUniforms {
    var stripHeight: Float
}

private final class SharedMetalResources: @unchecked Sendable {
    let device: MTLDevice
    let fieldPipeline: MTLRenderPipelineState
    let cellPipeline: MTLRenderPipelineState
    let fusedCellComputePipeline: MTLComputePipelineState
    let referenceDitherPipeline: MTLRenderPipelineState
    let optimizedDitherPipeline: MTLRenderPipelineState
    let gradientTexture: MTLTexture
    let atlasDitherPipeline: MTLRenderPipelineState
    let coverageComputePipeline: MTLComputePipelineState
    let joinMaskComputePipeline: MTLComputePipelineState
    let blurCompositePipeline: MTLRenderPipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "DitherMetal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal device is unavailable"])
        }
        self.device = device

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: DitherMetalRenderer.shaderSource, options: nil)
        } catch {
            throw NSError(domain: "DitherMetal", code: 3, userInfo: [NSLocalizedDescriptionKey: "Dither shader compilation failed: \(error)"])
        }
        guard let vertex = library.makeFunction(name: "ditherVertex"),
              let field = library.makeFunction(name: "ditherField"),
              let cell = library.makeFunction(name: "ditherCell"),
              let fusedCellCompute = library.makeFunction(name: "ditherFusedCellCompute"),
              let referenceDither = library.makeFunction(name: "ditherUpscale"),
              let optimizedDither = library.makeFunction(name: "ditherUpscaleOptimized"),
              let blurComposite = library.makeFunction(name: "ditherTopBlurComposite"),
              let gradientFunction = library.makeFunction(name: "ditherGradient") else {
            throw NSError(domain: "DitherMetal", code: 4, userInfo: [NSLocalizedDescriptionKey: "Dither shader functions are missing"])
        }

        func makePipeline(fragment: MTLFunction, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        do {
            fieldPipeline = try makePipeline(fragment: field, pixelFormat: .rgba8Unorm)
            cellPipeline = try makePipeline(fragment: cell, pixelFormat: .rgba16Float)
            fusedCellComputePipeline = try device.makeComputePipelineState(function: fusedCellCompute)
            referenceDitherPipeline = try makePipeline(fragment: referenceDither, pixelFormat: .bgra8Unorm)
            optimizedDitherPipeline = try makePipeline(fragment: optimizedDither, pixelFormat: .bgra8Unorm)
            blurCompositePipeline = try makePipeline(fragment: blurComposite, pixelFormat: .bgra8Unorm)
        } catch {
            throw NSError(domain: "DitherMetal", code: 5, userInfo: [NSLocalizedDescriptionKey: "Dither pipeline creation failed: \(error)"])
        }

        guard let atlasFunction = library.makeFunction(name: "ditherUpscaleAtlas") else {
            throw NSError(domain: "DitherMetal", code: 4)
        }
        guard let coverageComputeFunction = library.makeFunction(name: "ditherCoverageCompute"),
              let joinMaskComputeFunction = library.makeFunction(name: "ditherJoinMaskCompute") else {
            throw NSError(domain: "DitherMetal", code: 4)
        }
        atlasDitherPipeline = try makePipeline(fragment: atlasFunction, pixelFormat: .bgra8Unorm)
        coverageComputePipeline = try device.makeComputePipelineState(function: coverageComputeFunction)
        joinMaskComputePipeline = try device.makeComputePipelineState(function: joinMaskComputeFunction)
        let gradientDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: 289,
            height: 289,
            mipmapped: false
        )
        gradientDescriptor.storageMode = .private
        gradientDescriptor.usage = [.renderTarget, .shaderRead]
        guard let gradients = device.makeTexture(descriptor: gradientDescriptor),
              let queue = device.makeCommandQueue(),
              let initialization = queue.makeCommandBuffer() else {
            throw NSError(domain: "DitherMetal", code: 13)
        }
        let gradientPipeline = try makePipeline(fragment: gradientFunction, pixelFormat: .rgba32Float)
        let gradientPass = MTLRenderPassDescriptor()
        gradientPass.colorAttachments[0].texture = gradients
        gradientPass.colorAttachments[0].loadAction = .dontCare
        gradientPass.colorAttachments[0].storeAction = .store
        guard let encoder = initialization.makeRenderCommandEncoder(descriptor: gradientPass) else {
            throw NSError(domain: "DitherMetal", code: 13)
        }
        encoder.setRenderPipelineState(gradientPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        initialization.commit()
        initialization.waitUntilCompleted()
        if let error = initialization.error {
            throw error
        }
        gradientTexture = gradients
    }
}

final class DitherMetalRenderer {
    static let topBlurStripPoints: Float = 104
    static let topBlurMaximumSigma: Float = 5
    static let topBlurGaussianSigmas: [Float] = [
        topBlurMaximumSigma * 0.1,
        topBlurMaximumSigma * 0.4,
        topBlurMaximumSigma
    ]
    static let topBlurDecayCoefficient: Float = 3

    struct RenderMetrics {
        let cpuElapsed: TimeInterval
        let gpuElapsed: TimeInterval?
        let renderPassCount: Int
        let computeDispatchCount: Int
        let gaussianEncodeCount: Int
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fieldPipeline: MTLRenderPipelineState
    private let cellPipeline: MTLRenderPipelineState
    private let fusedCellComputePipeline: MTLComputePipelineState
    private let ditherPipeline: MTLRenderPipelineState
    private let blurCompositePipeline: MTLRenderPipelineState
    private let gradientTexture: MTLTexture
    private var fieldTexture: MTLTexture?
    private var cellTexture: MTLTexture?
    private var joinMaskTexture: MTLTexture?
    private let finalPassDescriptor = MTLRenderPassDescriptor()
    private let blurSourcePassDescriptor = MTLRenderPassDescriptor()
    private var fieldSize = MTLSize(width: 1, height: 1, depth: 1)
    private var time: Float = 0
    private var reveal: Float = 0
    private var animationTiming = DitherAnimationTiming()
    private var paletteBuffer: MTLBuffer
    private var lastPalette: [SIMD3<Float>] = []
    private(set) var lastRenderMetrics: RenderMetrics?
    private let usesFusedFieldAndCellPass: Bool
    private let usesTopBlur: Bool
    private let blurScale: Float
    private let usesTwoDimensionalThreadgroups: Bool
    private var topBlurResources: TopBlurResources?

    private struct TopBlurResources {
        let source: MTLTexture
        let levels: [MTLTexture]
        let kernels: [MPSImageGaussianBlur]
        let scale: Float
    }

    // Swift serializes static initialization. Immutable Metal objects are shared;
    // failed initialization remains a thrown error rather than terminating the app.
    private static let sharedResources = Result { try SharedMetalResources() }

    private struct CoverageKey: Hashable {
        let cell: Int
        let gap: Float
        let radius: Float
    }

    private var coverageTextures: [CoverageKey: MTLTexture] = [:]
    private let usesCoverageAtlas: Bool

    init(
        usesFusedFieldAndCellPass: Bool = true,
        usesCoverageAtlas: Bool = true,
        usesTopBlur: Bool = true,
        blurScale: Float = 1,
        usesTwoDimensionalThreadgroups: Bool = true
    ) throws {
        self.usesCoverageAtlas = usesCoverageAtlas
        self.usesFusedFieldAndCellPass = usesFusedFieldAndCellPass
        self.usesTopBlur = usesTopBlur
        self.blurScale = max(0.01, blurScale)
        self.usesTwoDimensionalThreadgroups = usesTwoDimensionalThreadgroups
        guard MemoryLayout<FieldUniforms>.stride == 64,
              MemoryLayout<DitherUniforms>.stride == 96 else {
            throw NSError(domain: "DitherMetal", code: 12, userInfo: [NSLocalizedDescriptionKey: "Swift and Metal uniform layouts do not match"])
        }
        let resources = try Self.sharedResources.get()
        guard let queue = resources.device.makeCommandQueue() else {
            throw NSError(domain: "DitherMetal", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create Metal command queue"])
        }
        device = resources.device
        self.queue = queue
        fieldPipeline = resources.fieldPipeline
        cellPipeline = resources.cellPipeline
        fusedCellComputePipeline = resources.fusedCellComputePipeline
        ditherPipeline = usesFusedFieldAndCellPass ? resources.optimizedDitherPipeline : resources.referenceDitherPipeline
        blurCompositePipeline = resources.blurCompositePipeline
        gradientTexture = resources.gradientTexture
        guard let paletteBuffer = device.makeBuffer(length: 8 * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared) else {
            throw NSError(domain: "DitherMetal", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not allocate palette buffer"])
        }
        self.paletteBuffer = paletteBuffer
    }

    func render(to drawable: CAMetalDrawable, size: CGSize, configuration: DitherConfiguration, advance: Bool) throws {
        let drawableWidth = drawable.texture.width
        let drawableHeight = drawable.texture.height
        let ratio = Float(drawableWidth) / max(Float(size.width), 1)
        let cell = max(1, Int(configuration.pixelSize * ratio))
        try render(to: drawable.texture, width: drawableWidth, height: drawableHeight, cell: cell, configuration: configuration, advance: advance, drawable: drawable, waitUntilCompleted: false, scale: ratio)
    }

    func render(to target: MTLTexture, width: Int, height: Int, cell: Int, configuration: DitherConfiguration, advance: Bool = true, atTime: Float? = nil) throws {
        try render(to: target, width: width, height: height, cell: cell, configuration: configuration, advance: advance, atTime: atTime, drawable: nil, waitUntilCompleted: true, scale: blurScale)
    }

    func render(to target: MTLTexture, width: Int, height: Int, cell: Int, configuration: DitherConfiguration, scale: Float, advance: Bool = true, atTime: Float? = nil) throws {
        try render(to: target, width: width, height: height, cell: cell, configuration: configuration, advance: advance, atTime: atTime, drawable: nil, waitUntilCompleted: true, scale: scale)
    }

    func resetAnimationTiming() {
        animationTiming.reset()
    }

    func seedAnimationTiming() {
        animationTiming.seed(now: CACurrentMediaTime())
    }

    var isIntroComplete: Bool {
        reveal >= 1
    }

    var sharedGradientResourceIdentifier: ObjectIdentifier {
        ObjectIdentifier(gradientTexture)
    }

    static func topBlurSigma(at fraction: Float, maxSigma: Float = topBlurMaximumSigma) -> Float {
        let t = min(1, max(0, fraction))
        return max(0, maxSigma * exp(-topBlurDecayCoefficient * t) * pow(1 - t, 2))
    }

    static func topBlurStripPixels(scale: Float) -> Int {
        max(1, Int((topBlurStripPoints * max(0.01, scale)).rounded(.up)))
    }

    func restartIntro() {
        reveal = 0
    }

    private func render(to target: MTLTexture, width: Int, height: Int, cell: Int, configuration: DitherConfiguration, advance: Bool, atTime: Float? = nil, drawable: CAMetalDrawable?, waitUntilCompleted: Bool, scale: Float) throws {
        let cpuStart = CACurrentMediaTime()
        let delta = Float(animationTiming.advance(now: cpuStart, isAdvancing: advance))
        if advance && !configuration.disableAnimation && atTime == nil {
            time += delta
        }
        if let atTime {
            time = atTime
        }
        if configuration.intro {
            reveal = min(1, reveal + delta / 1.8)
        } else {
            reveal = 1
        }
        let cell = max(1, min(cell, width, height))
        let columns = max(1, width / cell)
        let rows = max(1, height / cell)
        if cellTexture == nil || fieldSize.width != columns || fieldSize.height != rows {
            if !usesFusedFieldAndCellPass {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: columns, height: rows, mipmapped: false)
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                fieldTexture = device.makeTexture(descriptor: descriptor)
            }
            let cellDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: columns, height: rows, mipmapped: false)
            cellDescriptor.usage = usesFusedFieldAndCellPass ? [.shaderRead, .shaderWrite] : [.renderTarget, .shaderRead]
            cellDescriptor.storageMode = .private
            cellTexture = device.makeTexture(descriptor: cellDescriptor)
            let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: columns, height: rows, mipmapped: false)
            maskDescriptor.storageMode = .private
            maskDescriptor.usage = [.shaderRead, .shaderWrite]
            joinMaskTexture = device.makeTexture(descriptor: maskDescriptor)
            fieldSize = MTLSize(width: columns, height: rows, depth: 1)
        }
        guard let cellTexture else {
            throw NSError(domain: "DitherMetal", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not allocate field texture"])
        }
        var field = FieldUniforms(
            resolution: SIMD2<Float>(Float(columns * cell), Float(rows * cell)),
            cell: Float(cell),
            time: time,
            waveSpeed: max(0, configuration.waveSpeed),
            waveDirection: DitherConfiguration.waveDirectionVector(for: configuration.waveDirection),
            waveFrequency: configuration.waveFrequency,
            waveAmplitude: configuration.waveAmplitude,
            scale: max(0.05, configuration.scale),
            contrast: configuration.contrast,
            brightness: configuration.brightness,
            intro: reveal,
            reach: 1.5
        )
        var dither = DitherUniforms(
            fieldSize: SIMD2<Int32>(Int32(columns), Int32(rows)),
            cellDevice: Float(cell),
            mode: Int32(configuration.ditherMode),
            colorNum: max(2, configuration.colorNum),
            ditherStrength: min(1, max(0, configuration.ditherStrength)),
            wave: configuration.waveColor,
            background: configuration.backgroundColor,
            paletteCount: Int32(min(8, configuration.palette.count)),
            transparent: configuration.transparent ? 1 : 0,
            gap: min(0.45, max(0, configuration.gap)),
            cornerRadius: min(0.5, max(0, configuration.cornerRadius)),
            joinAdjacentSquares: configuration.joinAdjacentSquares ? 1 : 0,
            viewportSize: SIMD2<Int32>(Int32(width), Int32(height))
        )
        if configuration.palette != lastPalette {
            var paletteData = [SIMD3<Float>](repeating: SIMD3<Float>(), count: 8)
            for (index, color) in configuration.palette.prefix(8).enumerated() {
                paletteData[index] = color
            }
            guard let replacement = paletteData.withUnsafeBytes({ bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return nil as MTLBuffer?
                }
                return device.makeBuffer(bytes: baseAddress, length: bytes.count, options: .storageModeShared)
            }) else {
                throw NSError(domain: "DitherMetal", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not allocate palette buffer"])
            }
            paletteBuffer = replacement
            lastPalette = configuration.palette
        }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw NSError(domain: "DitherMetal", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not create Metal command buffer"])
        }
        var renderPassCount = 0
        var computeDispatchCount = 0
        var gaussianEncodeCount = 0
        var fusedComputeEncoder: MTLComputeCommandEncoder?
        defer {
            fusedComputeEncoder?.endEncoding()
        }
        if usesFusedFieldAndCellPass {
            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw NSError(domain: "DitherMetal", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not create fused field and cell compute encoder"])
            }
            fusedComputeEncoder = computeEncoder
            computeEncoder.setComputePipelineState(fusedCellComputePipeline)
            computeEncoder.setTexture(cellTexture, index: 0)
            computeEncoder.setTexture(gradientTexture, index: 1)
            computeEncoder.setBytes(&field, length: MemoryLayout<FieldUniforms>.stride, index: 0)
            computeEncoder.setBytes(&dither, length: MemoryLayout<DitherUniforms>.stride, index: 1)
            computeEncoder.setBuffer(paletteBuffer, offset: 0, index: 2)
            dispatch(
                computeEncoder,
                width: columns,
                height: rows,
                pipeline: fusedCellComputePipeline
            )
            computeDispatchCount += 1
        } else {
            guard let fieldTexture else {
                throw NSError(domain: "DitherMetal", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not allocate field texture"])
            }
            let fieldPass = MTLRenderPassDescriptor()
            fieldPass.colorAttachments[0].texture = fieldTexture
            fieldPass.colorAttachments[0].loadAction = .dontCare
            fieldPass.colorAttachments[0].storeAction = .store
            guard let fieldEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: fieldPass) else {
                throw NSError(domain: "DitherMetal", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not create field encoder"])
            }
            fieldEncoder.setRenderPipelineState(fieldPipeline)
            fieldEncoder.setFragmentBytes(&field, length: MemoryLayout<FieldUniforms>.stride, index: 0)
            fieldEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            fieldEncoder.endEncoding()
            renderPassCount += 1
            let cellPass = MTLRenderPassDescriptor()
            cellPass.colorAttachments[0].texture = cellTexture
            cellPass.colorAttachments[0].loadAction = .dontCare
            cellPass.colorAttachments[0].storeAction = .store
            guard let cellEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: cellPass) else {
                throw NSError(domain: "DitherMetal", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not create cell encoder"])
            }
            cellEncoder.setRenderPipelineState(cellPipeline)
            cellEncoder.setFragmentTexture(fieldTexture, index: 0)
            cellEncoder.setFragmentBytes(&dither, length: MemoryLayout<DitherUniforms>.stride, index: 0)
            cellEncoder.setFragmentBuffer(paletteBuffer, offset: 0, index: 1)
            cellEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            cellEncoder.endEncoding()
            renderPassCount += 1
        }
        var coverageTexture: MTLTexture?
        var newCoverageKey: CoverageKey?
        if usesFusedFieldAndCellPass && usesCoverageAtlas && cell <= 128 && (dither.gap > 0 || dither.cornerRadius > 0) {
            let key = CoverageKey(cell: cell, gap: dither.gap, radius: dither.cornerRadius)
            if let cached = coverageTextures[key] {
                coverageTexture = cached
            } else {
                let resources = try Self.sharedResources.get()
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: cell, height: cell * (dither.gap > 0 ? 1 : 16), mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.shaderRead, .shaderWrite]
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw NSError(domain: "DitherMetal", code: 14)
                }
                guard let computeEncoder = fusedComputeEncoder else {
                    throw NSError(domain: "DitherMetal", code: 14)
                }
                computeEncoder.setComputePipelineState(resources.coverageComputePipeline)
                computeEncoder.setTexture(texture, index: 0)
                computeEncoder.setBytes(&dither, length: MemoryLayout<DitherUniforms>.stride, index: 0)
                dispatch(
                    computeEncoder,
                    width: cell,
                    height: texture.height,
                    pipeline: resources.coverageComputePipeline
                )
                computeDispatchCount += 1
                newCoverageKey = key
                coverageTexture = texture
            }
        }
        if coverageTexture != nil && dither.joinAdjacentSquares > 0 && dither.gap == 0 && dither.cornerRadius > 0 {
            guard let joinMaskTexture else {
                throw NSError(domain: "DitherMetal", code: 15)
            }
            guard let encoder = fusedComputeEncoder else {
                throw NSError(domain: "DitherMetal", code: 15)
            }
            let resources = try Self.sharedResources.get()
            encoder.memoryBarrier(scope: .textures)
            encoder.setComputePipelineState(resources.joinMaskComputePipeline)
            encoder.setTexture(cellTexture, index: 0)
            encoder.setTexture(joinMaskTexture, index: 1)
            encoder.setBytes(&dither, length: MemoryLayout<DitherUniforms>.stride, index: 0)
            dispatch(
                encoder,
                width: columns,
                height: rows,
                pipeline: resources.joinMaskComputePipeline,
                usesTwoDimensionalThreadgroups: usesTwoDimensionalThreadgroups
            )
            computeDispatchCount += 1
        }
        fusedComputeEncoder?.endEncoding()
        fusedComputeEncoder = nil
        if usesTopBlur {
            try encodeTopBlur(
                commandBuffer: commandBuffer,
                width: width,
                height: height,
                scale: scale,
                dither: dither,
                coverageTexture: coverageTexture,
                joinMaskTexture: joinMaskTexture,
                paletteBuffer: paletteBuffer
            )
            renderPassCount += 1
            gaussianEncodeCount = Self.topBlurGaussianSigmas.count
        }
        let finalPass = finalPassDescriptor
        finalPass.colorAttachments[0].texture = target
        finalPass.colorAttachments[0].loadAction = usesFusedFieldAndCellPass ? .dontCare : .clear
        finalPass.colorAttachments[0].storeAction = .store
        finalPass.colorAttachments[0].clearColor = MTLClearColor(red: Double(configuration.backgroundColor.x), green: Double(configuration.backgroundColor.y), blue: Double(configuration.backgroundColor.z), alpha: 1)
        guard let finalEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: finalPass) else {
            throw NSError(domain: "DitherMetal", code: 9, userInfo: [NSLocalizedDescriptionKey: "Could not create composite encoder"])
        }
        renderPassCount += 1
        if let coverageTexture {
            finalEncoder.setRenderPipelineState(try Self.sharedResources.get().atlasDitherPipeline)
            finalEncoder.setFragmentTexture(coverageTexture, index: 1)
            finalEncoder.setFragmentTexture(joinMaskTexture, index: 2)
        } else {
            finalEncoder.setRenderPipelineState(ditherPipeline)
        }
        finalEncoder.setFragmentTexture(cellTexture, index: 0)
        finalEncoder.setFragmentBytes(&dither, length: MemoryLayout<DitherUniforms>.stride, index: 0)
        finalEncoder.setFragmentBuffer(paletteBuffer, offset: 0, index: 1)
        let stripHeight = usesTopBlur ? min(height, Self.topBlurStripPixels(scale: scale)) : 0
        if stripHeight < height {
            finalEncoder.setScissorRect(MTLScissorRect(x: 0, y: stripHeight, width: width, height: height - stripHeight))
            finalEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if usesTopBlur {
            encodeTopBlurComposite(encoder: finalEncoder, width: width, stripHeight: stripHeight, scale: scale)
        }
        finalEncoder.endEncoding()
        if let drawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
        // Publish only after submission: a failed encoder must not leave an
        // uninitialized atlas in the cache for the next frame.
        if let newCoverageKey, let coverageTexture {
            if coverageTextures.count >= 8 {
                coverageTextures.removeAll(keepingCapacity: true)
            }
            coverageTextures[newCoverageKey] = coverageTexture
        }
        let submissionElapsed = CACurrentMediaTime() - cpuStart
        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                throw error
            }
            let gpuElapsed = commandBuffer.gpuStartTime > 0 && commandBuffer.gpuEndTime > commandBuffer.gpuStartTime
                ? commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
                : nil
            lastRenderMetrics = RenderMetrics(
                cpuElapsed: submissionElapsed,
                gpuElapsed: gpuElapsed,
                renderPassCount: renderPassCount,
                computeDispatchCount: computeDispatchCount,
                gaussianEncodeCount: gaussianEncodeCount
            )
        }
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        width: Int,
        height: Int,
        pipeline: MTLComputePipelineState,
        usesTwoDimensionalThreadgroups: Bool = false
    ) {
        let threadgroupWidth = min(pipeline.threadExecutionWidth, width)
        let threadgroupHeight: Int
        if usesTwoDimensionalThreadgroups {
            threadgroupHeight = min(
                8,
                pipeline.maxTotalThreadsPerThreadgroup / threadgroupWidth,
                height
            )
        } else {
            threadgroupHeight = 1
        }
        let threads = MTLSize(
            width: threadgroupWidth,
            height: threadgroupHeight,
            depth: 1
        )
        let groups = MTLSize(
            width: (width + threadgroupWidth - 1) / threadgroupWidth,
            height: (height + threadgroupHeight - 1) / threadgroupHeight,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
    }

    private func encodeTopBlur(
        commandBuffer: MTLCommandBuffer,
        width: Int,
        height: Int,
        scale: Float,
        dither: DitherUniforms,
        coverageTexture: MTLTexture?,
        joinMaskTexture: MTLTexture?,
        paletteBuffer: MTLBuffer
    ) throws {
        let stripHeight = min(height, Self.topBlurStripPixels(scale: scale))
        let maxSigma = Self.topBlurMaximumSigma * max(0.01, scale)
        let padding = max(1, Int(ceil(maxSigma * 3)))
        let sourceHeight = min(height, stripHeight + padding)
        let scaleChanged = topBlurResources?.scale != scale
        if topBlurResources == nil || topBlurResources?.source.width != width || topBlurResources?.source.height != sourceHeight || scaleChanged {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: sourceHeight, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let source = device.makeTexture(descriptor: descriptor) else {
                throw NSError(domain: "DitherMetal", code: 16, userInfo: [NSLocalizedDescriptionKey: "Could not allocate top blur source"])
            }
            // Each level is sampled only while sigma exceeds the previous level.
            // Crop destination height instead of blurring every level across the strip.
            let sigmas = Self.topBlurGaussianSigmas
            descriptor.pixelFormat = .rgba16Float
            var levels: [MTLTexture] = []
            for index in sigmas.indices {
                let minimumSigma: Float = index == 0 ? 0 : sigmas[index - 1]
                var contributingRows = stripHeight
                while contributingRows > 1 && Self.topBlurSigma(at: Float(contributingRows - 1) / Float(Self.topBlurStripPixels(scale: scale))) <= minimumSigma {
                    contributingRows -= 1
                }
                // Bilinear sampling needs the row just beyond the last contribution.
                descriptor.height = min(sourceHeight, contributingRows + 1)
                guard let level = device.makeTexture(descriptor: descriptor) else {
                    throw NSError(domain: "DitherMetal", code: 16, userInfo: [NSLocalizedDescriptionKey: "Could not allocate top blur level"])
                }
                levels.append(level)
            }
            topBlurResources = TopBlurResources(
                source: source,
                levels: levels,
                kernels: sigmas.map {
                    let kernel = MPSImageGaussianBlur(device: device, sigma: $0 * max(0.01, scale))
                    kernel.edgeMode = .clamp
                    return kernel
                },
                scale: scale
            )
        }
        guard let resources = topBlurResources else {
            return
        }
        var sourceDither = dither
        let sourcePass = blurSourcePassDescriptor
        sourcePass.colorAttachments[0].texture = resources.source
        sourcePass.colorAttachments[0].loadAction = .dontCare
        sourcePass.colorAttachments[0].storeAction = .store
        guard let sourceEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: sourcePass) else {
            throw NSError(domain: "DitherMetal", code: 17, userInfo: [NSLocalizedDescriptionKey: "Could not create top blur source encoder"])
        }
        sourceEncoder.setRenderPipelineState(coverageTexture == nil ? ditherPipeline : try Self.sharedResources.get().atlasDitherPipeline)
        sourceEncoder.setFragmentTexture(cellTexture, index: 0)
        if let coverageTexture {
            sourceEncoder.setFragmentTexture(coverageTexture, index: 1)
            sourceEncoder.setFragmentTexture(joinMaskTexture, index: 2)
        }
        sourceEncoder.setFragmentBytes(&sourceDither, length: MemoryLayout<DitherUniforms>.stride, index: 0)
        sourceEncoder.setFragmentBuffer(paletteBuffer, offset: 0, index: 1)
        sourceEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        sourceEncoder.endEncoding()
        for (kernel, level) in zip(resources.kernels, resources.levels) {
            kernel.encode(commandBuffer: commandBuffer, sourceTexture: resources.source, destinationTexture: level)
        }
    }

    private func encodeTopBlurComposite(encoder: MTLRenderCommandEncoder, width: Int, stripHeight: Int, scale: Float) {
        guard let resources = topBlurResources else {
            return
        }
        var uniforms = TopBlurUniforms(stripHeight: Float(Self.topBlurStripPixels(scale: scale)))
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(stripHeight), znear: 0, zfar: 1))
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: stripHeight))
        encoder.setRenderPipelineState(blurCompositePipeline)
        encoder.setFragmentTexture(resources.source, index: 0)
        for (index, level) in resources.levels.enumerated() {
            encoder.setFragmentTexture(level, index: index + 1)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TopBlurUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    fileprivate static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct FieldUniforms {
    float2 resolution;
    float cell;
    float time;
    float waveSpeed;
    float2 waveDirection;
    float waveFrequency;
    float waveAmplitude;
    float scale;
    float contrast;
    float brightness;
    float intro;
    float reach;
};

struct DitherUniforms {
    int2 fieldSize;
    float cellDevice;
    int mode;
    float colorNum;
    float ditherStrength;
    float3 wave;
    float3 background;
    int paletteCount;
    float transparent;
    float gap;
    float cornerRadius;
    int joinAdjacentSquares;
    int2 viewportSize;
};

struct TopBlurUniforms {
    float stripHeight;
};

struct Raster {
    float4 position [[position]];
};

vertex Raster ditherVertex(uint id [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };
    Raster result;
    result.position = float4(positions[id], 0.0, 1.0);
    return result;
}

float4 mod289(float4 value) {
    return value - floor(value * (1.0 / 289.0)) * 289.0;
}

float4 permute(float4 value) {
    return mod289(((value * 34.0) + 1.0) * value);
}

float4 taylorInvSqrt(float4 value) {
    return 1.79284291400159 - 0.85373472095314 * value;
}

float2 fade(float2 value) {
    return value * value * value * (value * (value * 6.0 - 15.0) + 10.0);
}

float cnoise(float2 point) {
    float4 integerPart = floor(point.xyxy) + float4(0.0, 0.0, 1.0, 1.0);
    float4 fractionalPart = fract(point.xyxy) - float4(0.0, 0.0, 1.0, 1.0);
    integerPart = mod289(integerPart);
    float4 ix = integerPart.xzxz;
    float4 iy = integerPart.yyww;
    float4 fx = fractionalPart.xzxz;
    float4 fy = fractionalPart.yyww;
    float4 index = permute(permute(ix) + iy);
    float4 gx = fract(index * (1.0 / 41.0)) * 2.0 - 1.0;
    float4 gy = abs(gx) - 0.5;
    float4 tx = floor(gx + 0.5);
    gx -= tx;
    float2 g00 = float2(gx.x, gy.x);
    float2 g10 = float2(gx.y, gy.y);
    float2 g01 = float2(gx.z, gy.z);
    float2 g11 = float2(gx.w, gy.w);
    float4 normalizer = taylorInvSqrt(float4(dot(g00, g00), dot(g01, g01), dot(g10, g10), dot(g11, g11)));
    g00 *= normalizer.x;
    g01 *= normalizer.y;
    g10 *= normalizer.z;
    g11 *= normalizer.w;
    float n00 = dot(g00, float2(fx.x, fy.x));
    float n10 = dot(g10, float2(fx.y, fy.y));
    float n01 = dot(g01, float2(fx.z, fy.z));
    float n11 = dot(g11, float2(fx.w, fy.w));
    float2 fadeXY = fade(fractionalPart.xy);
    float2 nx = mix(float2(n00, n01), float2(n10, n11), fadeXY.x);
    return 2.3 * mix(nx.x, nx.y, fadeXY.y);
}

float fbm(float2 point, constant FieldUniforms &uniforms) {
    float value = 0.0;
    float amplitude = 1.0;
    for (int index = 0; index < 4; index++) {
        value += amplitude * abs(cnoise(point));
        point *= uniforms.waveFrequency;
        amplitude *= uniforms.waveAmplitude;
        if (amplitude == 0.0) {
            break;
        }
    }
    return value;
}

float pattern(float2 point, constant FieldUniforms &uniforms) {
    float2 shifted = point - uniforms.time * uniforms.waveSpeed * uniforms.waveDirection;
    float warpX = fbm(shifted + float2(17.3, 41.7), uniforms);
    float warpY = fbm(shifted + float2(73.1, 11.9), uniforms);
    float2 vectorWarp = float2(warpX, warpY) - 0.5;
    return fbm(shifted + vectorWarp, uniforms);
}

float displayedFieldValue(float2 position, constant FieldUniforms &uniforms) {
    float2 corner = (position - 0.5) * uniforms.cell;
    float2 uv = corner / uniforms.resolution - 0.5;
    uv.x *= uniforms.resolution.x / uniforms.resolution.y;
    float2 warp = float2(0.0);
    float value = pattern((uv + warp) / max(uniforms.scale, 0.05), uniforms);
    value = (value - 0.5) * uniforms.contrast + 0.5 + uniforms.brightness;
    float show = clamp((uniforms.intro * uniforms.reach - length(uv)) / 0.45, 0.0, 1.0);
    return clamp(value, 0.0, 1.0) * show * show * (3.0 - 2.0 * show);
}


// Each texel stores both horizontal gradients, cutting each noise sample
// from four texture instructions to two without reducing float precision.
fragment float4 ditherGradient(Raster input [[stage_in]]) {
    float2 lattice = floor(input.position.xy);
    float4 x = mod289(float4(lattice.x, lattice.x + 1.0, lattice.x, lattice.x + 1.0));
    float4 index = permute(permute(x) + lattice.y);
    float4 gx = fract(index * (1.0 / 41.0)) * 2.0 - 1.0;
    float4 gy = abs(gx) - 0.5;
    gx -= floor(gx + 0.5);
    float2 first = float2(gx.x, gy.x);
    float2 second = float2(gx.y, gy.y);
    float4 normalizer = taylorInvSqrt(float4(dot(first, first), dot(second, second), dot(first, first), dot(second, second)));
    return float4(first * normalizer.x, second * normalizer.y);
}

float cachedNoise(float2 point, texture2d<float, access::read> gradients) {
    float4 integerPart = floor(point.xyxy) + float4(0.0, 0.0, 1.0, 1.0);
    float4 fractionalPart = fract(point.xyxy) - float4(0.0, 0.0, 1.0, 1.0);
    integerPart = mod289(integerPart);
    float4 ix = integerPart.xzxz;
    float4 iy = integerPart.yyww;
    float4 fx = fractionalPart.xzxz;
    float4 fy = fractionalPart.yyww;
    float4 topGradients = gradients.read(uint2(ix.x, iy.x));
    float4 bottomGradients = gradients.read(uint2(ix.z, iy.z));
    float2 g00 = topGradients.xy;
    float2 g10 = topGradients.zw;
    float2 g01 = bottomGradients.xy;
    float2 g11 = bottomGradients.zw;
    float n00 = dot(g00, float2(fx.x, fy.x));
    float n10 = dot(g10, float2(fx.y, fy.y));
    float n01 = dot(g01, float2(fx.z, fy.z));
    float n11 = dot(g11, float2(fx.w, fy.w));
    float2 fadeXY = fade(fractionalPart.xy);
    float2 nx = mix(float2(n00, n01), float2(n10, n11), fadeXY.x);
    return 2.3 * mix(nx.x, nx.y, fadeXY.y);
}

float cachedFBM(float2 point, constant FieldUniforms &uniforms, texture2d<float, access::read> gradients) {
    float value = 0.0;
    float amplitude = 1.0;
    for (int index = 0; index < 4; index++) {
        value += amplitude * abs(cachedNoise(point, gradients));
        point *= uniforms.waveFrequency;
        amplitude *= uniforms.waveAmplitude;
        if (amplitude == 0.0) {
            break;
        }
    }
    return value;
}

float cachedPattern(float2 point, constant FieldUniforms &uniforms, texture2d<float, access::read> gradients) {
    float2 shifted = point - uniforms.time * uniforms.waveSpeed * uniforms.waveDirection;
    float warpX = cachedFBM(shifted + float2(17.3, 41.7), uniforms, gradients);
    float warpY = cachedFBM(shifted + float2(73.1, 11.9), uniforms, gradients);
    float2 vectorWarp = float2(warpX, warpY) - 0.5;
    return cachedFBM(shifted + vectorWarp, uniforms, gradients);
}

float cachedFieldValue(float2 position, constant FieldUniforms &uniforms, texture2d<float, access::read> gradients) {
    float2 corner = (position - 0.5) * uniforms.cell;
    float2 uv = corner / uniforms.resolution - 0.5;
    uv.x *= uniforms.resolution.x / uniforms.resolution.y;
    float2 warp = float2(0.0);
    float value = cachedPattern((uv + warp) / max(uniforms.scale, 0.05), uniforms, gradients);
    value = (value - 0.5) * uniforms.contrast + 0.5 + uniforms.brightness;
    float show = clamp((uniforms.intro * uniforms.reach - length(uv)) / 0.45, 0.0, 1.0);
    return clamp(value, 0.0, 1.0) * show * show * (3.0 - 2.0 * show);
}

float quantizedFieldValue(float displayed) {
    float scaled = displayed * 255.0;
    float redByte = floor(scaled);
    float greenByte = rint(fract(scaled) * 255.0);
    return redByte / 255.0 + greenByte / (255.0 * 255.0);
}

fragment float4 ditherField(
    Raster input [[stage_in]],
    constant FieldUniforms &uniforms [[buffer(0)]]) {
    float displayed = displayedFieldValue(input.position.xy, uniforms);
    return float4(floor(displayed * 255.0) / 255.0, fract(displayed * 255.0), 0.0, 1.0);
}

constant float bayer8[64] = {
    0.0 / 64.0, 48.0 / 64.0, 12.0 / 64.0, 60.0 / 64.0, 3.0 / 64.0, 51.0 / 64.0, 15.0 / 64.0, 63.0 / 64.0,
    32.0 / 64.0, 16.0 / 64.0, 44.0 / 64.0, 28.0 / 64.0, 35.0 / 64.0, 19.0 / 64.0, 47.0 / 64.0, 31.0 / 64.0,
    8.0 / 64.0, 56.0 / 64.0, 4.0 / 64.0, 52.0 / 64.0, 11.0 / 64.0, 59.0 / 64.0, 7.0 / 64.0, 55.0 / 64.0,
    40.0 / 64.0, 24.0 / 64.0, 36.0 / 64.0, 20.0 / 64.0, 43.0 / 64.0, 27.0 / 64.0, 39.0 / 64.0, 23.0 / 64.0,
    2.0 / 64.0, 50.0 / 64.0, 14.0 / 64.0, 62.0 / 64.0, 1.0 / 64.0, 49.0 / 64.0, 13.0 / 64.0, 61.0 / 64.0,
    34.0 / 64.0, 18.0 / 64.0, 46.0 / 64.0, 30.0 / 64.0, 33.0 / 64.0, 17.0 / 64.0, 45.0 / 64.0, 29.0 / 64.0,
    10.0 / 64.0, 58.0 / 64.0, 6.0 / 64.0, 54.0 / 64.0, 9.0 / 64.0, 57.0 / 64.0, 5.0 / 64.0, 53.0 / 64.0,
    42.0 / 64.0, 26.0 / 64.0, 38.0 / 64.0, 22.0 / 64.0, 41.0 / 64.0, 25.0 / 64.0, 37.0 / 64.0, 21.0 / 64.0
};

constant float bayer4[16] = {
    0.0 / 16.0, 8.0 / 16.0, 2.0 / 16.0, 10.0 / 16.0,
    12.0 / 16.0, 4.0 / 16.0, 14.0 / 16.0, 6.0 / 16.0,
    3.0 / 16.0, 11.0 / 16.0, 1.0 / 16.0, 9.0 / 16.0,
    15.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0, 5.0 / 16.0
};

constant float bayer2[4] = { 0.0 / 4.0, 2.0 / 4.0, 3.0 / 4.0, 1.0 / 4.0 };

float threshold(float2 cell, int mode) {
    if (mode == 1) {
        int2 coordinate = int2(fmod(cell, 4.0));
        return bayer4[coordinate.y * 4 + coordinate.x];
    }
    if (mode == 2) {
        int2 coordinate = int2(fmod(cell, 2.0));
        return bayer2[coordinate.y * 2 + coordinate.x];
    }
    if (mode == 3) {
        float2 rotated = float2(cell.x + cell.y, cell.x - cell.y) * 0.70710678 / 4.0;
        return clamp(length(fract(rotated) - 0.5) * 1.41421356, 0.0, 0.999);
    }
    if (mode == 4) {
        return abs(fract(cell.y / 4.0) - 0.5) * 2.0 * 0.999;
    }
    if (mode == 5) {
        float first = abs(fract((cell.x + cell.y) / 6.0) - 0.5) * 2.0;
        float second = abs(fract((cell.x - cell.y) / 6.0) - 0.5) * 2.0;
        return min(first, second) * 0.999;
    }
    if (mode == 6) {
        return fract(52.9829189 * fract(dot(cell, float2(0.06711056, 0.00583715))));
    }
    if (mode == 7) {
        return 0.25;
    }
    int2 coordinate = int2(fmod(cell, 8.0));
    return bayer8[coordinate.y * 8 + coordinate.x];
}

float4 quantizedCellColor(
    float value,
    float2 cell,
    constant DitherUniforms &uniforms,
    constant float3 *palette);

fragment float4 ditherCell(
    Raster input [[stage_in]],
    texture2d<float, access::read> field [[texture(0)]],
    constant DitherUniforms &uniforms [[buffer(0)]],
    constant float3 *palette [[buffer(1)]]) {
    uint2 cellPixel = uint2(input.position.xy);
    float2 cell = float2(cellPixel);
    int2 maximum = uniforms.fieldSize - 1;
    int2 coordinate = clamp(int2(cell), int2(0), maximum);
    float4 sampleValue = field.read(uint2(coordinate));
    float value = sampleValue.r + sampleValue.g / 255.0;
    return quantizedCellColor(value, cell, uniforms, palette);
}

float4 quantizedCellColor(
    float value,
    float2 cell,
    constant DitherUniforms &uniforms,
    constant float3 *palette) {
    // These cases are algebraically zero, so avoid threshold work without changing output.
    float thresholdValue = (uniforms.ditherStrength == 0.0 || uniforms.mode == 7)
        ? 0.0
        : (threshold(cell, uniforms.mode) - 0.25) * uniforms.ditherStrength;
    float levels = max(uniforms.colorNum, 1.01) - 1.0;
    float opacityValue = value + thresholdValue / levels;
    opacityValue = clamp(opacityValue - mix(0.2, 0.0, smoothstep(0.45, 0.8, opacityValue)), 0.0, 1.0);
    float alpha = floor(opacityValue * levels + 0.5) / levels;
    if (uniforms.paletteCount > 1) {
        float count = float(uniforms.paletteCount);
        float paletteValue = value + thresholdValue / (count - 1.0);
        paletteValue = clamp(paletteValue - mix(0.2, 0.0, smoothstep(0.45, 0.8, paletteValue)), 0.0, 1.0);
        int index = int(floor(paletteValue * (count - 1.0) + 0.5));
        float3 color = mix(uniforms.background, palette[index], alpha);
        return uniforms.transparent > 0.5
            ? float4(palette[index] * alpha, alpha)
            : float4(color, alpha);
    }
    if (uniforms.transparent > 0.5) {
        return float4(uniforms.wave * alpha, alpha);
    }
    return float4(mix(uniforms.background, uniforms.wave, alpha), alpha);
}

fragment float4 ditherFusedCell(
    Raster input [[stage_in]],
    constant FieldUniforms &fieldUniforms [[buffer(0)]],
    constant DitherUniforms &ditherUniforms [[buffer(1)]],
    constant float3 *palette [[buffer(2)]],
    texture2d<float, access::read> gradients [[texture(0)]]) {
    float displayed = cachedFieldValue(input.position.xy, fieldUniforms, gradients);
    float value = quantizedFieldValue(displayed);
    return quantizedCellColor(value, floor(input.position.xy), ditherUniforms, palette);
}

kernel void ditherFusedCellCompute(
    texture2d<float, access::write> output [[texture(0)]],
    texture2d<float, access::read> gradients [[texture(1)]],
    constant FieldUniforms &fieldUniforms [[buffer(0)]],
    constant DitherUniforms &ditherUniforms [[buffer(1)]],
    constant float3 *palette [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(output.get_width()) || gid.y >= uint(output.get_height())) {
        return;
    }
    float2 position = float2(gid) + 0.5;
    float displayed = cachedFieldValue(position, fieldUniforms, gradients);
    float value = quantizedFieldValue(displayed);
    output.write(quantizedCellColor(value, floor(position), ditherUniforms, palette), gid);
}

fragment float4 ditherUpscale(
    Raster input [[stage_in]],
    texture2d<float, access::read> cellColors [[texture(0)]],
    constant DitherUniforms &uniforms [[buffer(0)]]) {
    int2 outputPixel = int2(input.position.xy);
    int cellSize = int(uniforms.cellDevice);
    int2 gridSize = uniforms.fieldSize * cellSize;
    int2 padding = (uniforms.viewportSize - gridSize) / 2;
    int2 gridPixel = outputPixel - padding;
    if (any(gridPixel < 0) || any(gridPixel >= gridSize)) {
        if (uniforms.transparent > 0.5) {
            return float4(0.0);
        }
        return float4(uniforms.background, 1.0);
    }
    uint2 pixel = uint2(gridPixel);
    float2 cell = floor(float2(pixel) / uniforms.cellDevice);
    int2 maximum = uniforms.fieldSize - 1;
    int2 coordinate = clamp(int2(cell), int2(0), maximum);
    float4 cellColor = cellColors.read(uint2(coordinate));
    float3 backgroundColor = uniforms.background;
    float shape = 1.0;
    if (uniforms.gap > 0.0 || uniforms.cornerRadius > 0.0) {
        float2 local = fmod(float2(pixel) + 0.5, uniforms.cellDevice);
        float2 size = float2(uniforms.cellDevice);
        float2 inset = min(uniforms.gap * size, size * 0.49);
        float2 point = local - size * 0.5;
        float2 halfSize = max(size * 0.5 - inset, float2(0.5));
        float radius = min(uniforms.cornerRadius * size.x, min(halfSize.x, halfSize.y));
        bool hasLeft = false;
        bool hasRight = false;
        bool hasTop = false;
        bool hasBottom = false;
        bool canJoin = uniforms.joinAdjacentSquares > 0 && uniforms.gap == 0.0 && cellColor.a > 0.0 && radius > 0.0;
        if (canJoin) {
            int2 cellCoordinate = int2(cell);
            hasLeft = cellCoordinate.x > 0 && cellColors.read(uint2(cellCoordinate + int2(-1, 0))).a > 0.0;
            hasRight = cellCoordinate.x < uniforms.fieldSize.x - 1 && cellColors.read(uint2(cellCoordinate + int2(1, 0))).a > 0.0;
            hasTop = cellCoordinate.y > 0 && cellColors.read(uint2(cellCoordinate + int2(0, -1))).a > 0.0;
            hasBottom = cellCoordinate.y < uniforms.fieldSize.y - 1 && cellColors.read(uint2(cellCoordinate + int2(0, 1))).a > 0.0;
            bool leftSide = point.x < 0.0;
            bool topSide = point.y < 0.0;
            if ((leftSide && (hasLeft || topSide && hasTop)) ||
                (!leftSide && (hasRight || topSide && hasTop)) ||
                (leftSide && (!topSide && (hasLeft || hasBottom))) ||
                (!leftSide && (!topSide && (hasRight || hasBottom)))) {
                radius = 0.0;
            }
        }
        float2 distanceToCorner = abs(point) - (halfSize - radius);
        float distance = length(max(distanceToCorner, float2(0.0))) + min(max(distanceToCorner.x, distanceToCorner.y), 0.0) - radius;
        shape = 1.0 - smoothstep(-0.75, 0.75, distance);
        if (canJoin) {
            if ((hasLeft && point.x < -halfSize.x + 1.0) ||
                (hasRight && point.x > halfSize.x - 1.0) ||
                (hasTop && point.y < -halfSize.y + 1.0) ||
                (hasBottom && point.y > halfSize.y - 1.0)) {
                shape = 1.0;
            }
        }
    }
    if (uniforms.transparent > 0.5) {
        return float4(cellColor.rgb * shape, cellColor.a * shape);
    }
    return float4(mix(backgroundColor, cellColor.rgb, shape), 1.0);
}

fragment float4 ditherUpscaleOptimized(
    Raster input [[stage_in]],
    texture2d<float, access::read> cellColors [[texture(0)]],
    constant DitherUniforms &uniforms [[buffer(0)]]) {
    int2 outputPixel = int2(input.position.xy);
    int cellSize = int(uniforms.cellDevice);
    int2 gridSize = uniforms.fieldSize * cellSize;
    int2 padding = (uniforms.viewportSize - gridSize) / 2;
    int2 gridPixel = outputPixel - padding;
    if (any(gridPixel < 0) || any(gridPixel >= gridSize)) {
        if (uniforms.transparent > 0.5) {
            return float4(0.0);
        }
        return float4(uniforms.background, 1.0);
    }
    uint2 pixel = uint2(gridPixel);
    float2 cell = floor(float2(pixel) / uniforms.cellDevice);
    int2 maximum = uniforms.fieldSize - 1;
    int2 coordinate = clamp(int2(cell), int2(0), maximum);
    float4 cellColor = cellColors.read(uint2(coordinate));
    float3 backgroundColor = uniforms.background;
    float shape = 1.0;
    if (uniforms.gap > 0.0 || uniforms.cornerRadius > 0.0) {
        float2 local = float2(pixel) + 0.5 - cell * uniforms.cellDevice;
        float2 size = float2(uniforms.cellDevice);
        float2 inset = min(uniforms.gap * size, size * 0.49);
        float2 point = local - size * 0.5;
        float2 halfSize = max(size * 0.5 - inset, float2(0.5));
        float radius = min(uniforms.cornerRadius * size.x, min(halfSize.x, halfSize.y));
        bool hasLeft = false;
        bool hasRight = false;
        bool hasTop = false;
        bool hasBottom = false;
        bool canJoin = uniforms.joinAdjacentSquares > 0 && uniforms.gap == 0.0 && cellColor.a > 0.0 && radius > 0.0;
        if (canJoin) {
            int2 cellCoordinate = int2(cell);
            // Only the two neighbors facing this pixel can affect its corner or edge.
            bool leftSide = point.x < 0.0;
            bool topSide = point.y < 0.0;
            if (leftSide || cellSize == 1) {
                hasLeft = cellCoordinate.x > 0 && cellColors.read(uint2(cellCoordinate + int2(-1, 0))).a > 0.0;
            }
            if (!leftSide || cellSize == 1) {
                hasRight = cellCoordinate.x < uniforms.fieldSize.x - 1 && cellColors.read(uint2(cellCoordinate + int2(1, 0))).a > 0.0;
            }
            if (topSide || cellSize == 1) {
                hasTop = cellCoordinate.y > 0 && cellColors.read(uint2(cellCoordinate + int2(0, -1))).a > 0.0;
            }
            if (!topSide || cellSize == 1) {
                hasBottom = cellCoordinate.y < uniforms.fieldSize.y - 1 && cellColors.read(uint2(cellCoordinate + int2(0, 1))).a > 0.0;
            }
            if (hasLeft || hasRight || hasTop || hasBottom) {
                radius = 0.0;
            }
        }
        float2 distanceToCorner = abs(point) - (halfSize - radius);
        float distance = length(max(distanceToCorner, float2(0.0))) + min(max(distanceToCorner.x, distanceToCorner.y), 0.0) - radius;
        shape = 1.0 - smoothstep(-0.75, 0.75, distance);
        if (canJoin) {
            if ((hasLeft && point.x < -halfSize.x + 1.0) ||
                (hasRight && point.x > halfSize.x - 1.0) ||
                (hasTop && point.y < -halfSize.y + 1.0) ||
                (hasBottom && point.y > halfSize.y - 1.0)) {
                shape = 1.0;
            }
        }
    }
    if (uniforms.transparent > 0.5) {
        return float4(cellColor.rgb * shape, cellColor.a * shape);
    }
    return float4(mix(backgroundColor, cellColor.rgb, shape), 1.0);
}

float ditherCoverageValue(float2 position, constant DitherUniforms &uniforms) {
    int cellSize = int(uniforms.cellDevice);
    int2 atlasPixel = int2(position);
    int mask = atlasPixel.y / cellSize;
    float2 local = float2(atlasPixel.x, atlasPixel.y % cellSize) + 0.5;
    float2 size = float2(uniforms.cellDevice);
    float2 inset = min(uniforms.gap * size, size * 0.49);
    float2 point = local - size * 0.5;
    float2 halfSize = max(size * 0.5 - inset, float2(0.5));
    float radius = min(uniforms.cornerRadius * size.x, min(halfSize.x, halfSize.y));
    bool hasLeft = (mask & 1) != 0;
    bool hasRight = (mask & 2) != 0;
    bool hasTop = (mask & 4) != 0;
    bool hasBottom = (mask & 8) != 0;
    bool canJoin = mask != 0 && uniforms.gap == 0.0 && radius > 0.0;
    if (canJoin) {
        bool leftSide = point.x < 0.0;
        bool topSide = point.y < 0.0;
        if ((leftSide && (hasLeft || topSide && hasTop)) ||
            (!leftSide && (hasRight || topSide && hasTop)) ||
            (leftSide && (!topSide && (hasLeft || hasBottom))) ||
            (!leftSide && (!topSide && (hasRight || hasBottom)))) {
            radius = 0.0;
        }
    }
    float2 distanceToCorner = abs(point) - (halfSize - radius);
    float distance = length(max(distanceToCorner, float2(0.0))) + min(max(distanceToCorner.x, distanceToCorner.y), 0.0) - radius;
    float shape = 1.0 - smoothstep(-0.75, 0.75, distance);
    if (canJoin) {
        if ((hasLeft && point.x < -halfSize.x + 1.0) ||
            (hasRight && point.x > halfSize.x - 1.0) ||
            (hasTop && point.y < -halfSize.y + 1.0) ||
            (hasBottom && point.y > halfSize.y - 1.0)) {
            shape = 1.0;
        }
    }
    return shape;
}

fragment float ditherCoverage(
    Raster input [[stage_in]],
    constant DitherUniforms &uniforms [[buffer(0)]]) {
    return ditherCoverageValue(input.position.xy, uniforms);
}

kernel void ditherCoverageCompute(
    texture2d<float, access::write> output [[texture(0)]],
    constant DitherUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(output.get_width()) || gid.y >= uint(output.get_height())) {
        return;
    }
    output.write(ditherCoverageValue(float2(gid) + 0.5, uniforms), gid);
}

fragment uint ditherJoinMask(
    Raster input [[stage_in]],
    texture2d<float, access::read> cellColors [[texture(0)]],
    constant DitherUniforms &uniforms [[buffer(0)]]) {
    int2 coordinate = int2(input.position.xy);
    if (cellColors.read(uint2(coordinate)).a <= 0.0) {
        return 0;
    }
    uint mask = 0;
    if (coordinate.x > 0 && cellColors.read(uint2(coordinate + int2(-1, 0))).a > 0.0) mask |= 1;
    if (coordinate.x < uniforms.fieldSize.x - 1 && cellColors.read(uint2(coordinate + int2(1, 0))).a > 0.0) mask |= 2;
    if (coordinate.y > 0 && cellColors.read(uint2(coordinate + int2(0, -1))).a > 0.0) mask |= 4;
    if (coordinate.y < uniforms.fieldSize.y - 1 && cellColors.read(uint2(coordinate + int2(0, 1))).a > 0.0) mask |= 8;
    return mask;
}

kernel void ditherJoinMaskCompute(
    texture2d<float, access::read> cellColors [[texture(0)]],
    texture2d<uint, access::write> output [[texture(1)]],
    constant DitherUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(output.get_width()) || gid.y >= uint(output.get_height())) {
        return;
    }
    int2 coordinate = int2(gid);
    if (cellColors.read(gid).a <= 0.0) {
        output.write(0, gid);
        return;
    }
    uint mask = 0;
    if (coordinate.x > 0 && cellColors.read(uint2(coordinate + int2(-1, 0))).a > 0.0) mask |= 1;
    if (coordinate.x < uniforms.fieldSize.x - 1 && cellColors.read(uint2(coordinate + int2(1, 0))).a > 0.0) mask |= 2;
    if (coordinate.y > 0 && cellColors.read(uint2(coordinate + int2(0, -1))).a > 0.0) mask |= 4;
    if (coordinate.y < uniforms.fieldSize.y - 1 && cellColors.read(uint2(coordinate + int2(0, 1))).a > 0.0) mask |= 8;
    output.write(mask, gid);
}

fragment float4 ditherUpscaleAtlas(
    Raster input [[stage_in]],
    texture2d<float, access::read> cellColors [[texture(0)]],
    texture2d<float, access::read> coverage [[texture(1)]],
    texture2d<uint, access::read> joinMasks [[texture(2)]],
    constant DitherUniforms &uniforms [[buffer(0)]]) {
    int2 outputPixel = int2(input.position.xy);
    int cellSize = int(uniforms.cellDevice);
    int2 gridSize = uniforms.fieldSize * cellSize;
    int2 padding = (uniforms.viewportSize - gridSize) / 2;
    int2 gridPixel = outputPixel - padding;
    if (any(gridPixel < 0) || any(gridPixel >= gridSize)) {
        if (uniforms.transparent > 0.5) {
            return float4(0.0);
        }
        return float4(uniforms.background, 1.0);
    }
    uint2 pixel = uint2(gridPixel);
    float2 cell = floor(float2(pixel) / uniforms.cellDevice);
    int2 maximum = uniforms.fieldSize - 1;
    int2 coordinate = clamp(int2(cell), int2(0), maximum);
    float4 cellColor = cellColors.read(uint2(coordinate));
    float3 backgroundColor = uniforms.background;
    float shape = 1.0;
    int mask = 0;
    if (uniforms.joinAdjacentSquares > 0 && uniforms.gap == 0.0 && uniforms.cornerRadius > 0.0) {
        mask = int(joinMasks.read(uint2(coordinate)).r);
    }
    uint2 localPixel = pixel - uint2(cell) * uint(cellSize);
    shape = coverage.read(uint2(localPixel.x, localPixel.y + uint(mask * cellSize))).r;
    if (uniforms.transparent > 0.5) {
        return float4(cellColor.rgb * shape, cellColor.a * shape);
    }
    return float4(mix(backgroundColor, cellColor.rgb, shape), 1.0);
}

fragment float4 ditherTopBlurComposite(
    Raster input [[stage_in]],
    texture2d<float, access::sample> sharp [[texture(0)]],
    texture2d<float, access::sample> sigmaHalf [[texture(1)]],
    texture2d<float, access::sample> sigmaTwo [[texture(2)]],
    texture2d<float, access::sample> sigmaMaximum [[texture(3)]],
    constant TopBlurUniforms &uniforms [[buffer(0)]]) {
    // Metal fragment positions already address pixel centers, starting at the top.
    constexpr sampler samplerState(coord::pixel, address::clamp_to_edge, filter::linear);
    float t = clamp(input.position.y / max(uniforms.stripHeight, 1.0), 0.0, 1.0);
    constexpr float maximumSigma = 5.0;
    float sigma = maximumSigma * exp(-\(topBlurDecayCoefficient) * t) * (1.0 - t) * (1.0 - t);
    float2 position = input.position.xy;
    constexpr float sigmaHalfValue = maximumSigma * 0.1;
    constexpr float sigmaTwoValue = maximumSigma * 0.4;
    if (sigma <= sigmaHalfValue) {
        return mix(sharp.sample(samplerState, position), sigmaHalf.sample(samplerState, position), sigma / sigmaHalfValue);
    }
    if (sigma <= sigmaTwoValue) {
        return mix(sigmaHalf.sample(samplerState, position), sigmaTwo.sample(samplerState, position), (sigma - sigmaHalfValue) / (sigmaTwoValue - sigmaHalfValue));
    }
    if (sigma <= maximumSigma) {
        return mix(sigmaTwo.sample(samplerState, position), sigmaMaximum.sample(samplerState, position), (sigma - sigmaTwoValue) / (maximumSigma - sigmaTwoValue));
    }
    return sigmaMaximum.sample(samplerState, position);
}
"""
}

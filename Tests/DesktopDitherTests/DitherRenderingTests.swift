import Metal
import Testing
@testable import DesktopDither

@Test
func wallpaperModeProducesPremultipliedTransparencyForEveryPalette() throws {
    let renderer = try DitherMetalRenderer(usesTopBlur: false)
    let size = 64
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: size,
        height: size,
        mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget, .shaderRead]
    let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
    for palette: [SIMD3<Float>] in [[], [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)]] {
        for transparent in [false, true] {
            var configuration = DitherConfiguration()
            configuration.intro = false
            configuration.transparent = transparent
            configuration.palette = palette
            configuration.backgroundColor = SIMD3<Float>(1, 1, 1)
            configuration.gap = 0.2
            configuration.cornerRadius = 0.2
            try renderer.render(
                to: texture,
                width: size,
                height: size,
                cell: 8,
                configuration: configuration,
                advance: false,
                atTime: 3
            )
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            pixels.withUnsafeMutableBytes { buffer in
                texture.getBytes(
                    buffer.baseAddress!,
                    bytesPerRow: size * 4,
                    from: MTLRegionMake2D(0, 0, size, size),
                    mipmapLevel: 0
                )
            }
            let alphas = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
            if transparent {
                #expect(alphas.contains { $0 == 0 })
                #expect(alphas.contains { $0 > 0 })
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    let alpha = Int(pixels[offset + 3])
                    #expect((0..<3).allSatisfy { Int(pixels[offset + $0]) <= alpha + 1 })
                }
            } else {
                #expect(alphas.allSatisfy { $0 == 255 })
            }
        }
    }
}

@Test(arguments: [0, 1, 2, 3, 4, 5])
func fusedFieldAndCellPassMatchesReferenceAcrossModesAndShapes(variant: Int) throws {
    let width = variant.isMultiple(of: 2) ? 192 : 193
    let height = variant.isMultiple(of: 2) ? 144 : 137
    let cell = [1, 2, 4, 6, 13, 32][variant]
    let previousRenderer = try PreviousDitherMetalRenderer(usesFusedFieldAndCellPass: true)
    let referenceRenderer = try DitherMetalRenderer(usesFusedFieldAndCellPass: true, usesCoverageAtlas: false, usesTopBlur: false)
    let optimizedRenderer = try DitherMetalRenderer(usesFusedFieldAndCellPass: true, usesTopBlur: false)
    let previousTexture = try makeSharedTexture(
        device: previousRenderer.device,
        width: width,
        height: height
    )
    let referenceTexture = try makeSharedTexture(
        device: referenceRenderer.device,
        width: width,
        height: height
    )
    let optimizedTexture = try makeSharedTexture(
        device: optimizedRenderer.device,
        width: width,
        height: height
    )

    for mode in 0...7 {
        for shape in [
            (gap: Float(0), cornerRadius: Float(0), join: false),
            (gap: Float(0.18), cornerRadius: Float(0.32), join: false),
            (gap: Float(0), cornerRadius: Float(0.32), join: true)
        ] {
            var configuration = DitherConfiguration()
            configuration.intro = false
            configuration.ditherMode = mode
            configuration.ditherStrength = 0.73
            configuration.colorNum = 5
            configuration.waveFrequency = 1.7
            configuration.waveAmplitude = 0.62
            configuration.scale = 0.8
            configuration.contrast = 1.2
            configuration.brightness = -0.08
            configuration.waveSpeed = 0.05
            configuration.waveColor = SIMD3<Float>(0.9, 0.35, 0.15)
            configuration.backgroundColor = SIMD3<Float>(0.08, 0.12, 0.2)
            configuration.palette = variant.isMultiple(of: 2) ? [] : [
                SIMD3<Float>(0.95, 0.1, 0.2),
                SIMD3<Float>(0.1, 0.8, 0.35),
                SIMD3<Float>(0.2, 0.35, 0.95)
            ]
            configuration.transparent = (mode + variant).isMultiple(of: 2)
            configuration.scale = [Float(0.05), 0.3, 0.8, 1, 2, 4][variant]
            configuration.waveDirection = Float(variant * 45)
            configuration.ditherStrength = variant == 0 ? 0 : 0.73
            configuration.waveAmplitude = variant == 5 ? 0 : 0.62
            configuration.gap = shape.gap
            configuration.cornerRadius = shape.cornerRadius
            configuration.joinAdjacentSquares = shape.join

            try previousRenderer.render(
                to: previousTexture,
                width: width,
                height: height,
                cell: cell,
                configuration: configuration,
                advance: false,
                atTime: Float(variant) * 10.75
            )

            try referenceRenderer.render(
                to: referenceTexture,
                width: width,
                height: height,
                cell: cell,
                configuration: configuration,
                advance: false,
                atTime: Float(variant) * 10.75
            )
            try optimizedRenderer.render(
                to: optimizedTexture,
                width: width,
                height: height,
                cell: cell,
                configuration: configuration,
                advance: false,
                atTime: Float(variant) * 10.75
            )

            let referencePixels = readPixels(from: referenceTexture, width: width, height: height)
            let optimizedPixels = readPixels(from: optimizedTexture, width: width, height: height)
            let previousPixels = readPixels(from: previousTexture, width: width, height: height)
            let referenceMismatchCount = zip(previousPixels, referencePixels).filter { $0 != $1 }.count
            let optimizedMismatchCount = zip(previousPixels, optimizedPixels).filter { $0 != $1 }.count
            #expect(referenceMismatchCount == 0, "Current reference differs from preserved renderer for mode \(mode), shape \(shape)")
            #expect(optimizedMismatchCount == 0, "Next renderer differs from preserved renderer for mode \(mode), shape \(shape)")
        }
    }
}

private func makeSharedTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget, .shaderRead]
    return try #require(device.makeTexture(descriptor: descriptor))
}

private func readPixels(from texture: MTLTexture, width: Int, height: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        texture.getBytes(
            buffer.baseAddress!,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
    }
    return pixels
}

@Test
func coverageCacheSurvivesSettingChangesEvictionAndLargeCellFallback() throws {
    let renderer = try DitherMetalRenderer(usesTopBlur: false)
    let previous = try PreviousDitherMetalRenderer()
    let width = 389
    let height = 263
    let actual = try makeSharedTexture(device: renderer.device, width: width, height: height)
    let expected = try makeSharedTexture(device: previous.device, width: width, height: height)
    var configuration = DitherConfiguration()
    configuration.intro = false
    // More than eight coverage keys forces eviction. Revisit early keys after
    // changing palette, alpha, dimensions, and joining to catch stale GPU data.
    for step in Array(0..<12) + [0, 1, 2, 12, 13] {
        let cell = step >= 12 ? 129 : 2 + step
        configuration.gap = step.isMultiple(of: 3) ? 0 : Float(step) * 0.025
        configuration.cornerRadius = Float(step + 1) * 0.025
        configuration.joinAdjacentSquares = step.isMultiple(of: 2)
        configuration.transparent = step.isMultiple(of: 2)
        configuration.scale = 0.05
        configuration.waveFrequency = 3.7
        configuration.waveAmplitude = 0.62
        configuration.palette = step.isMultiple(of: 2) ? [] : [
            SIMD3<Float>(0.15, 0.8, 0.4),
            SIMD3<Float>(0.9, 0.1, 0.3)
        ]
        let frameWidth = step.isMultiple(of: 2) ? width : width - 7
        try previous.render(
            to: expected,
            width: frameWidth,
            height: height,
            cell: cell,
            configuration: configuration,
            advance: false,
            atTime: 100
        )
        try renderer.render(
            to: actual,
            width: frameWidth,
            height: height,
            cell: cell,
            configuration: configuration,
            advance: false,
            atTime: 100
        )
        let expectedBytes = readPixels(from: expected, width: frameWidth, height: height)
        let actualBytes = readPixels(from: actual, width: frameWidth, height: height)
        let mismatches = zip(expectedBytes, actualBytes).filter { $0 != $1 }.count
        #expect(mismatches == 0, "Coverage cache or fallback differs at step \(step)")
    }
}

@Test(arguments: [Float(1), Float(2)])
func topBlurLeavesPixelsBelowStripUntouched(atScale scale: Float) throws {
    let width = Int(128 * scale)
    let height = Int(160 * scale)
    let sharpRenderer = try DitherMetalRenderer(usesTopBlur: false, blurScale: scale)
    let blurRenderer = try DitherMetalRenderer(usesTopBlur: true, blurScale: scale)
    let sharp = try makeSharedTexture(device: sharpRenderer.device, width: width, height: height)
    let blurred = try makeSharedTexture(device: blurRenderer.device, width: width, height: height)
    var configuration = DitherConfiguration()
    configuration.intro = false
    configuration.ditherMode = 6
    configuration.transparent = true
    configuration.waveAmplitude = 0.8
    configuration.scale = 0.35
    try sharpRenderer.render(to: sharp, width: width, height: height, cell: Int(4 * scale), configuration: configuration, scale: scale, advance: false, atTime: 2)
    try blurRenderer.render(to: blurred, width: width, height: height, cell: Int(4 * scale), configuration: configuration, scale: scale, advance: false, atTime: 2)
    let sharpPixels = readPixels(from: sharp, width: width, height: height)
    let blurredPixels = readPixels(from: blurred, width: width, height: height)
    let stripHeight = DitherMetalRenderer.topBlurStripPixels(scale: scale)
    let lowerByteCount = width * max(0, height - stripHeight) * 4
    #expect(Array(sharpPixels.suffix(lowerByteCount)) == Array(blurredPixels.suffix(lowerByteCount)))
    #expect(Array(sharpPixels.prefix(width * stripHeight * 4)) != Array(blurredPixels.prefix(width * stripHeight * 4)))
    let seamStart = (stripHeight - 2) * width * 4
    let seamEnd = (stripHeight + 2) * width * 4
    #expect(Array(sharpPixels[seamStart..<seamEnd]) == Array(blurredPixels[seamStart..<seamEnd]))
    for offset in stride(from: 0, to: blurredPixels.count, by: 4) {
        let alpha = Int(blurredPixels[offset + 3])
        #expect((0..<3).allSatisfy { Int(blurredPixels[offset + $0]) <= alpha + 1 })
    }
}

@Test(arguments: [Float(1), Float(2)])
func topBlurMatchesGaussianReferenceAtDifferentHeights(scale: Float) throws {
    let width = Int(96 * scale)
    let height = Int(120 * scale)
    let renderer = try DitherMetalRenderer()
    let sharpRenderer = try DitherMetalRenderer(usesTopBlur: false)
    let sharp = try makeSharedTexture(device: renderer.device, width: width, height: height)
    let blurred = try makeSharedTexture(device: renderer.device, width: width, height: height)
    var configuration = DitherConfiguration()
    configuration.intro = false
    configuration.waveAmplitude = 0.8
    configuration.scale = 0.2
    configuration.gap = 0.18
    configuration.cornerRadius = 0.3
    configuration.transparent = true
    configuration.palette = [SIMD3<Float>(1, 0.1, 0.2), SIMD3<Float>(0.2, 1, 0.3), SIMD3<Float>(0.1, 0.3, 1)]
    try sharpRenderer.render(to: sharp, width: width, height: height, cell: Int(4 * scale), configuration: configuration, scale: scale, advance: false, atTime: 2)
    try renderer.render(to: blurred, width: width, height: height, cell: Int(4 * scale), configuration: configuration, scale: scale, advance: false, atTime: 2)
    let source = readPixels(from: sharp, width: width, height: height)
    let result = readPixels(from: blurred, width: width, height: height)
    let levels: [Float] = [0] + DitherMetalRenderer.topBlurGaussianSigmas
    for pointY in [0, 8, 24, 40, 56, 80, 100, 103] {
        let y = Int(Float(pointY) * scale)
        let sigma = DitherMetalRenderer.topBlurSigma(at: (Float(y) + 0.5) / (DitherMetalRenderer.topBlurStripPoints * scale))
        let upper = try #require(levels.firstIndex { $0 >= sigma })
        let lower = max(0, upper - 1)
        let weight = upper == lower ? 0 : (sigma - levels[lower]) / (levels[upper] - levels[lower])
        for x in [0, width / 3, width / 2, width - 1] {
            let a = gaussianReference(source, width: width, height: height, x: x, y: y, sigma: levels[lower] * scale)
            let b = gaussianReference(source, width: width, height: height, x: x, y: y, sigma: levels[upper] * scale)
            for channel in 0..<4 {
                let expected = a[channel] + (b[channel] - a[channel]) * weight
                let actual = Float(result[(y * width + x) * 4 + channel]) / 255
                // MPS uses an approximate Gaussian. This bound also includes BGRA8 rounding.
                #expect(abs(actual - expected) < 0.02, "Gaussian mismatch at \(x),\(y), sigma \(sigma), channel \(channel)")
            }
        }
    }
}

@Test
func topBlurRecreatesResourcesForSmallAndResizedViewports() throws {
    let renderer = try DitherMetalRenderer()
    var configuration = DitherConfiguration()
    configuration.intro = false
    configuration.cornerRadius = 0.3
    configuration.joinAdjacentSquares = true
    for (width, height, cell, scale) in [
        (1, 1, 1, Float(1)),
        (13, 7, 3, Float(2)),
        (96, 160, 6, Float(1)),
        (97, 161, 6, Float(2)),
        (260, 270, 129, Float(1)),
        (96, 160, 6, Float(1))
    ] {
        let freshRenderer = try DitherMetalRenderer()
        let actual = try makeSharedTexture(device: renderer.device, width: width, height: height)
        let expected = try makeSharedTexture(device: renderer.device, width: width, height: height)
        try renderer.render(to: actual, width: width, height: height, cell: cell, configuration: configuration, scale: scale, advance: false, atTime: 2)
        try freshRenderer.render(to: expected, width: width, height: height, cell: cell, configuration: configuration, scale: scale, advance: false, atTime: 2)
        #expect(readPixels(from: actual, width: width, height: height) == readPixels(from: expected, width: width, height: height))
    }
}

private func gaussianReference(_ pixels: [UInt8], width: Int, height: Int, x: Int, y: Int, sigma: Float) -> SIMD4<Float> {
    if sigma == 0 {
        let offset = (y * width + x) * 4
        return SIMD4<Float>((0..<4).map { Float(pixels[offset + $0]) / 255 })
    }
    let radius = Int(ceil(3 * sigma))
    let weights = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
    let normalization = weights.reduce(0, +)
    var value = SIMD4<Float>(repeating: 0)
    for dy in -radius...radius {
        let row = min(height - 1, max(0, y + dy))
        for dx in -radius...radius {
            let column = min(width - 1, max(0, x + dx))
            let offset = (row * width + column) * 4
            let weight = weights[dy + radius] * weights[dx + radius] / (normalization * normalization)
            for channel in 0..<4 {
                value[channel] += Float(pixels[offset + channel]) / 255 * weight
            }
        }
    }
    return value
}

@Test
func topBlurProfileIsMonotonicAndHasSmoothZeroBoundary() {
    let samples = (0...100).map { DitherMetalRenderer.topBlurSigma(at: Float($0) / 100) }
    #expect(samples.first == DitherMetalRenderer.topBlurMaximumSigma)
    #expect(samples.last == 0)
    for pair in zip(samples, samples.dropFirst()) {
        #expect(pair.0 >= pair.1)
    }
    #expect(DitherMetalRenderer.topBlurSigma(at: 0.999) > 0)
    #expect(DitherMetalRenderer.topBlurSigma(at: 1.001) == 0)
}

@Test
func topBlurUsesThe104PointStripAndReducedMaximumSigma() {
    #expect(DitherMetalRenderer.topBlurStripPoints == 104)
    #expect(DitherMetalRenderer.topBlurStripPixels(scale: 1) == 104)
    #expect(DitherMetalRenderer.topBlurStripPixels(scale: 2) == 208)
    #expect(DitherMetalRenderer.topBlurMaximumSigma == 5)
    #expect(DitherMetalRenderer.topBlurGaussianSigmas == [0.5, 2, 5])
    #expect(DitherMetalRenderer.topBlurSigma(at: 0) == 5)
    #expect(DitherMetalRenderer.topBlurSigma(at: 1) == 0)
}

@Test
func productionBlurUsesTwoRenderPassesAndOwnOperationCounters() throws {
    let renderer = try DitherMetalRenderer(usesTopBlur: true, blurScale: 1)
    let target = try makeSharedTexture(device: renderer.device, width: 160, height: 140)
    var configuration = DitherConfiguration()
    configuration.intro = false
    configuration.cornerRadius = 0.3
    configuration.joinAdjacentSquares = true
    try renderer.render(
        to: target,
        width: 160,
        height: 140,
        cell: 4,
        configuration: configuration,
        scale: 1,
        advance: false,
        atTime: 2
    )
    let metrics = try #require(renderer.lastRenderMetrics)
    #expect(metrics.renderPassCount == 2)
    #expect(metrics.computeDispatchCount == 3)
    #expect(metrics.gaussianEncodeCount == 3)

    let sharpRenderer = try DitherMetalRenderer(usesTopBlur: false)
    let sharpTarget = try makeSharedTexture(device: sharpRenderer.device, width: 160, height: 140)
    try sharpRenderer.render(
        to: sharpTarget,
        width: 160,
        height: 140,
        cell: 4,
        configuration: configuration,
        advance: false,
        atTime: 2
    )
    let sharpMetrics = try #require(sharpRenderer.lastRenderMetrics)
    #expect(sharpMetrics.renderPassCount == 1)
    #expect(sharpMetrics.gaussianEncodeCount == 0)
}

@Test
func topBlurProfileHasBroaderMidStripFalloffWithSameSeam() {
    let fraction: Float = 0.5
    let oldProfile = DitherMetalRenderer.topBlurMaximumSigma
        * exp(-4 * fraction)
        * pow(1 - fraction, 2)
    let newProfile = DitherMetalRenderer.topBlurSigma(at: fraction)
    #expect(newProfile > oldProfile)
    #expect(DitherMetalRenderer.topBlurSigma(at: 0) == DitherMetalRenderer.topBlurMaximumSigma)
    #expect(DitherMetalRenderer.topBlurSigma(at: 1) == 0)
    #expect(DitherMetalRenderer.topBlurSigma(at: 1.001) == 0)
}

import Foundation

struct DitherAnimationTiming {
    private var lastTime: TimeInterval?

    mutating func advance(now: TimeInterval, isAdvancing: Bool) -> TimeInterval {
        guard let previous = lastTime else {
            lastTime = now
            return 0
        }

        guard isAdvancing else {
            return 0
        }

        lastTime = now
        return max(0, now - previous)
    }

    mutating func seed(now: TimeInterval) {
        lastTime = now
    }

    mutating func reset() {
        lastTime = nil
    }
}

struct DitherRenderSchedulingPolicy {
    static let maximumFramesPerSecond: Double = 30
    static let minimumFramesPerSecond: Double = 4
    static let referenceSpeed: Float = 0.05

    static func interval(
        for configuration: DitherConfiguration,
        introComplete: Bool
    ) -> TimeInterval? {
        if configuration.intro && !introComplete {
            return 1 / maximumFramesPerSecond
        }

        guard !configuration.disableAnimation,
              configuration.waveSpeed.isFinite,
              configuration.waveSpeed > 0 else {
            return nil
        }

        let speed = Double(configuration.waveSpeed)
        let scaleValue = configuration.scale.isFinite ? configuration.scale : 1
        let frequencyValue = configuration.waveFrequency.isFinite ? configuration.waveFrequency : 3
        let contrastValue = configuration.contrast.isFinite ? configuration.contrast : 1
        let scale = max(1, min(3, 1 / Double(max(abs(scaleValue), 0.05))))
        let frequency = max(1, min(2, Double(abs(frequencyValue)) / 3))
        let contrast = max(1, min(1.5, Double(abs(contrastValue))))
        let detailMultiplier = scale * frequency * contrast
        // Lower cadence saves GPU work, but increases temporal sampling between wave positions.
        let framesPerSecond = min(
            maximumFramesPerSecond,
            max(minimumFramesPerSecond, speed / Double(referenceSpeed) * maximumFramesPerSecond * detailMultiplier)
        )
        return 1 / framesPerSecond
    }
}

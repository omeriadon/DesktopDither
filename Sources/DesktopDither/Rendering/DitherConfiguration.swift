import simd

struct DitherConfiguration: Equatable {
    // Direction uses compass degrees: 0° is up, 90° is right, and angles increase clockwise.
    // 135° preserves the original diagonal shift of (1, 1) per unit of wave speed.
    static let defaultWaveDirection: Float = 135

    var waveSpeed: Float = 0.05
    var waveDirection: Float = Self.defaultWaveDirection
    var waveFrequency: Float = 3
    var waveAmplitude: Float = 0.3
    var waveColor = SIMD3<Float>(repeating: 0.5)
    var backgroundColor = SIMD3<Float>(repeating: 0)
    var colorNum: Float = 4
    var pixelSize: Float = 2
    var disableAnimation = false
    var ditherMode = 0
    var ditherStrength: Float = 1
    var palette: [SIMD3<Float>] = []
    var scale: Float = 1
    var contrast: Float = 1
    var brightness: Float = 0
    var intro = true
    var transparent = false
    var dpr: Float = 0
    var gap: Float = 0
    var cornerRadius: Float = 0
    var joinAdjacentSquares = false

    static func normalizedWaveDirection(_ degrees: Float) -> Float? {
        guard degrees.isFinite else {
            return nil
        }
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized >= 0 ? normalized : normalized + 360
        let snapped = (positive / 45).rounded() * 45
        return snapped >= 360 ? 0 : snapped
    }

    static func waveDirectionVector(for degrees: Float) -> SIMD2<Float> {
        let normalized = normalizedWaveDirection(degrees) ?? defaultWaveDirection
        let radians = normalized * .pi / 180
        let legacyMagnitude = sqrt(Float(2))
        return SIMD2<Float>(sin(radians), -cos(radians)) * legacyMagnitude
    }

    static func compassDirection(for degrees: Float) -> String {
        let normalized = normalizedWaveDirection(degrees) ?? defaultWaveDirection
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((normalized / 45).rounded()) % directions.count
        return directions[index]
    }
}

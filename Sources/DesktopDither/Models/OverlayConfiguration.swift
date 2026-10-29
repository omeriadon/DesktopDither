import Foundation

struct OverlayConfiguration: Equatable, Codable, Sendable {
    var opacity: Double = 1

    var normalized: Self {
        Self(opacity: opacity.isFinite ? min(1, max(0, opacity)) : 1)
    }
}

import Foundation
import simd

@MainActor
final class DitherSettings: NSObject {
    static let shared = DitherSettings()
    static let didChangeNotification = Notification.Name("local.dither.appex.settingsDidChange")

    // Keep desktop effect preferences separate from the screen saver.
    private static let moduleIdentifier = "local.desktopglow.dither"
    private let defaults: UserDefaults

    private let defaultsValues: [String: Any] = [
        "waveSpeed": 0.05, "waveDirection": Double(DitherConfiguration.defaultWaveDirection), "waveFrequency": 3.0, "waveAmplitude": 0.3,
        "waveColor": "#808080", "backgroundColor": "#000000", "colorNum": 4.0,
        "pixelSize": 2.0, "disableAnimation": false, "ditherMode": 0, "ditherStrength": 1.0,
        "palette": "", "scale": 1.0, "contrast": 1.0, "brightness": 0.0,
        "intro": true, "transparent": false, "dpr": 0.0, "gap": 0.0,
        "cornerRadius": 0.0, "joinAdjacentSquares": false, "backgroundStyle": "custom", "colorPlacement": "squares",
        "squareStyle": "white"
    ]

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.moduleIdentifier) ?? UserDefaults.standard
        super.init()
        self.defaults.register(defaults: defaultsValues)
    }

    var configuration: DitherConfiguration {
        var result = DitherConfiguration()
        let storedWaveSpeed = number(for: "waveSpeed", fallback: result.waveSpeed)
        let storedWaveDirection = number(for: "waveDirection", fallback: result.waveDirection)
        if storedWaveSpeed < 0 {
            result.waveSpeed = abs(storedWaveSpeed)
            result.waveDirection = DitherConfiguration.normalizedWaveDirection(storedWaveDirection + 180)
                ?? result.waveDirection
            defaults.set(result.waveSpeed, forKey: "waveSpeed")
            defaults.set(result.waveDirection, forKey: "waveDirection")
        } else {
            result.waveSpeed = storedWaveSpeed
            result.waveDirection = DitherConfiguration.normalizedWaveDirection(storedWaveDirection)
                ?? result.waveDirection
        }
        result.waveFrequency = max(0.01, number(for: "waveFrequency", fallback: result.waveFrequency))
        result.waveAmplitude = max(0, number(for: "waveAmplitude", fallback: result.waveAmplitude))
        result.waveColor = color(defaults.string(forKey: "waveColor"), fallback: result.waveColor)
        result.backgroundColor = color(defaults.string(forKey: "backgroundColor"), fallback: result.backgroundColor)
        switch defaults.string(forKey: "backgroundStyle") {
        case "black":
            result.backgroundColor = .zero
        case "white":
            result.backgroundColor = SIMD3<Float>(repeating: 1)
        case "dim":
            result.backgroundColor = result.waveColor * 0.2
        default:
            break
        }
        if defaults.string(forKey: "colorPlacement") == "background" {
            result.backgroundColor = result.waveColor
            result.waveColor = defaults.string(forKey: "squareStyle") == "black"
                ? .zero
                : SIMD3<Float>(repeating: 1)
        }
        result.colorNum = max(2, number(for: "colorNum", fallback: result.colorNum))
        result.pixelSize = min(4096, max(1, number(for: "pixelSize", fallback: result.pixelSize)))
        result.disableAnimation = defaults.bool(forKey: "disableAnimation")
        result.ditherMode = min(7, max(0, defaults.integer(forKey: "ditherMode")))
        result.ditherStrength = min(1, max(0, number(for: "ditherStrength", fallback: result.ditherStrength)))
        result.palette = defaults.string(forKey: "palette")?
            .split(separator: ",")
            .compactMap { paletteColor(String($0).trimmingCharacters(in: .whitespaces)) } ?? []
        if defaults.string(forKey: "colorPlacement") == "background" {
            result.palette = []
        }
        result.scale = max(0.05, number(for: "scale", fallback: result.scale))
        result.contrast = number(for: "contrast", fallback: result.contrast)
        result.brightness = number(for: "brightness", fallback: result.brightness)
        result.intro = defaults.bool(forKey: "intro")
        result.transparent = defaults.bool(forKey: "transparent")
        // Ignore the legacy render-scale override; always use the display backing scale.
        result.dpr = 0
        result.gap = min(0.45, max(0, number(for: "gap", fallback: result.gap)))
        result.cornerRadius = min(0.5, max(0, number(for: "cornerRadius", fallback: result.cornerRadius)))
        result.joinAdjacentSquares = defaults.bool(forKey: "joinAdjacentSquares")
        return result
    }

    func value(for key: String) -> Any {
        defaults.object(forKey: key) ?? ""
    }

    var values: [String: Any] {
        defaultsValues.keys.reduce(into: [:]) { result, key in
            result[key] = value(for: key)
        }
    }

    func set(_ value: Any, for key: String) {
        if let text = value as? String, defaultsValues[key] is Double {
            guard let number = Double(text), number.isFinite else {
                return
            }
            if key == "waveDirection" {
                let direction = DitherConfiguration.normalizedWaveDirection(Float(number))
                    ?? DitherConfiguration.defaultWaveDirection
                defaults.set(Double(direction), forKey: key)
            } else {
                defaults.set(number, forKey: key)
            }
        } else {
            defaults.set(value, forKey: key)
        }
        defaults.synchronize()
    }

    func apply(_ values: DitherOptionsValues) {
        for (key, value) in values.textFields {
            set(value, for: key)
        }
        for (key, value) in values.checks {
            set(value, for: key)
        }
        set(values.ditherMode, for: "ditherMode")
    }
    func reload() {
        defaults.synchronize()
    }

    private func number(for key: String, fallback: Float) -> Float {
        guard let value = defaults.object(forKey: key) as? NSNumber else {
            return fallback
        }
        let number = value.floatValue
        return number.isFinite ? number : fallback
    }

    private func color(_ value: String?, fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard let value else {
            return fallback
        }
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else {
            return fallback
        }
        return SIMD3<Float>(Float((number >> 16) & 255) / 255, Float((number >> 8) & 255) / 255, Float(number & 255) / 255)
    }

    private func paletteColor(_ value: String) -> SIMD3<Float>? {
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else {
            return nil
        }
        return SIMD3<Float>(Float((number >> 16) & 255) / 255, Float((number >> 8) & 255) / 255, Float(number & 255) / 255)
    }

}

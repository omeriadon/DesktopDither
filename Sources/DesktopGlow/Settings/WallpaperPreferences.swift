import Foundation

struct WallpaperPreferences: Codable, Equatable, Sendable {
    var configuration = OverlayConfiguration()
    var enabled = true
    var displayScope = DisplayScope.all
    var pauseWhenCovered = true
    var respectLowPowerMode = true
    var respectReduceMotion = true

    var normalized: Self {
        var result = self
        result.configuration = configuration.normalized
        return result
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: "wallpaper.preferences"),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return saved.normalized
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: "wallpaper.preferences")
        }
    }
}

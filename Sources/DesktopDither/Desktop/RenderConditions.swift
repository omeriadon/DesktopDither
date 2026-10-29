import Foundation

struct RenderConditions: Equatable, Sendable {
    var displaysAsleep = false
    var sessionInactive = false
    var lowPowerMode = false
    var reduceMotion = false
    var thermallyConstrained = false

    func pauseReason(for preferences: WallpaperPreferences) -> String? {
        if !preferences.enabled {
            return "Desktop layer is paused."
        }
        if displaysAsleep || sessionInactive {
            return "Paused while your display or session is asleep."
        }
        if thermallyConstrained {
            return "Paused while your Mac cools down."
        }
        if preferences.respectLowPowerMode && lowPowerMode {
            return "Paused for Low Power Mode."
        }
        if preferences.respectReduceMotion && reduceMotion {
            return "Paused for Reduce Motion."
        }
        return nil
    }
}

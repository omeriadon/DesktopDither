import AppKit
import Foundation
import Testing
@testable import DesktopGlow

@Test
func effectLayerFitsBetweenWallpaperAndDesktopIcons() {
    #expect(DesktopLayering.effectLevel.rawValue > Int(CGWindowLevelForKey(.desktopWindow)))
    #expect(DesktopLayering.isBelowDesktopIcons)
}

@Test
func renderPoliciesPauseAndResumeWithoutChangingPreferences() {
    var conditions = RenderConditions()
    var preferences = WallpaperPreferences()
    #expect(conditions.pauseReason(for: preferences) == nil)
    conditions.displaysAsleep = true
    #expect(conditions.pauseReason(for: preferences) != nil)
    conditions.displaysAsleep = false
    conditions.sessionInactive = true
    #expect(conditions.pauseReason(for: preferences) != nil)
    conditions.sessionInactive = false
    conditions.lowPowerMode = true
    #expect(conditions.pauseReason(for: preferences) != nil)
    preferences.respectLowPowerMode = false
    #expect(conditions.pauseReason(for: preferences) == nil)
    conditions.reduceMotion = true
    #expect(conditions.pauseReason(for: preferences) != nil)
    preferences.respectReduceMotion = false
    #expect(conditions.pauseReason(for: preferences) == nil)
    conditions.thermallyConstrained = true
    #expect(conditions.pauseReason(for: preferences) != nil)
}

@Test
func invalidSavedPreferencesFallBackWithoutChangingOtherDomains() throws {
    let suite = "DesktopGlowTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
    }
    defaults.set(Data("invalid".utf8), forKey: "wallpaper.preferences")
    #expect(WallpaperPreferences.load(from: defaults) == WallpaperPreferences())
    var saved = WallpaperPreferences()
    saved.displayScope = .main
    saved.configuration.opacity = 0.3
    saved.enabled = false
    saved.save(to: defaults)
    #expect(WallpaperPreferences.load(from: defaults) == saved)
}

@Test @MainActor
func ditherTransparencyPersistsInItsOwnSettingsSuite() throws {
    let suite = "DesktopGlowDitherTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
    }
    let settings = DitherSettings(defaults: defaults)
    settings.apply(DitherOptionsValues(textFields: [:], checks: ["transparent": true], ditherMode: 0))
    #expect(settings.configuration.transparent)
    #expect(WallpaperPreferences.load(from: defaults) == WallpaperPreferences())
}

@Test @MainActor
func overlayNeverTakesFocusOrDesktopClicks() throws {
    _ = NSApplication.shared
    let screen = try #require(NSScreen.screens.first)
    let view = DesktopContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
    view.apply(OverlayConfiguration())
    let window = DesktopOverlayWindow(screen: screen, effectView: view)
    defer {
        window.close()
    }
    #expect(window.ignoresMouseEvents)
    #expect(!window.canBecomeMain)
    #expect(!window.canBecomeKey)
    #expect(view.subviews.count == 1)
    #expect(view.layer?.isOpaque == false)
    #expect(!window.isOpaque)
    #expect(window.level == DesktopLayering.effectLevel)
    view.setPaused(true)
    #expect(view.isPaused)
    view.apply(OverlayConfiguration(opacity: 0.5))
    #expect(view.isPaused)
    view.setPaused(false)
    #expect(!view.isPaused)
}

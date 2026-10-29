import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DesktopDither

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

@Test @MainActor
func compositorOpacityTargetsDitherOnlyAndPreservesSelectedBackground() throws {
    _ = NSApplication.shared
    let suite = "DesktopGlowCompositorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
    }
    let settings = DitherSettings(defaults: defaults)
    settings.set("#336699", for: "backgroundColor")
    settings.set("custom", for: "backgroundStyle")
    settings.set(false, for: "transparent")
    settings.set(false, for: "intro")
    settings.set(0, for: "waveSpeed")
    let view = DesktopContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 120), effectSettings: settings)
    view.apply(OverlayConfiguration(opacity: 0.25))
    #expect(view.layer?.opacity == 1)
    #expect(view.subviews.first?.alphaValue == 0.25)
    let opaqueComponents = view.layer?.backgroundColor?.components ?? []
    #expect(opaqueComponents.count >= 3)
    #expect(abs(opaqueComponents[0] - 0.2) < 0.01)
    #expect(abs(opaqueComponents[1] - 0.4) < 0.01)
    #expect(abs(opaqueComponents[2] - 0.6) < 0.01)

    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderBack(nil)
    defer {
        view.setPaused(true)
        window.close()
    }
    view.setPaused(false)
    #expect(view.renderedFrames > 0)
    #expect(view.renderError == nil)
    let framesBeforeOpacityOnlyUpdate = view.renderedFrames
    view.apply(OverlayConfiguration(opacity: 0.75))
    #expect(view.renderedFrames == framesBeforeOpacityOnlyUpdate)
    #expect(view.subviews.first?.alphaValue == 0.75)

    settings.set(true, for: "transparent")
    view.apply(OverlayConfiguration(opacity: -1))
    #expect(view.layer?.opacity == 1)
    #expect(view.subviews.first?.alphaValue == 0)
    let clearComponents = view.layer?.backgroundColor?.components ?? []
    #expect(clearComponents.last == 0)
    view.apply(OverlayConfiguration(opacity: 2))
    #expect(view.subviews.first?.alphaValue == 1)
}

@Test @MainActor
func desktopAppearanceControlsPreserveEffectDraftsAndSynchronizeTransparency() throws {
    _ = NSApplication.shared
    let suite = "DesktopDitherControlsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
    }
    let settings = DitherSettings(defaults: defaults)
    var changes: [WallpaperPreferences] = []
    let controller = SettingsWindowController(preferences: WallpaperPreferences(), ditherSettings: settings) {
        changes.append($0)
    }
    let window = try #require(controller.window)
    defer {
        window.close()
    }
    let tabs = try #require(window.contentView?.subviews.compactMap { $0 as? NSTabView }.first)
    let effectHost = try #require(tabs.tabViewItems[0].view as? NSHostingView<DitherOptionsView>)
    let model = effectHost.rootView.model
    model.setText("0.37", for: "waveAmplitude")
    tabs.selectTabViewItem(at: 1)
    let desktop = try #require(tabs.tabViewItems[1].view)
    let opacity = try #require(appearanceControl(in: desktop, identifier: "effects.opacity") as? NSSlider)
    opacity.doubleValue = 0.4
    #expect(opacity.sendAction(opacity.action, to: opacity.target))
    #expect(changes.last?.configuration.opacity == 0.4)
    #expect(model.textValues["waveAmplitude"] == "0.37")

    let transparent = try #require(appearanceControl(in: desktop, identifier: "effects.transparent") as? NSButton)
    transparent.state = .on
    #expect(transparent.sendAction(transparent.action, to: transparent.target))
    #expect(settings.configuration.transparent)
    #expect(model.checks["transparent"] == true)
    #expect(model.textValues["waveAmplitude"] == "0.37")

    model.setTransparent(false)
    let save = try #require(model.onSave)
    save()
    #expect(!settings.configuration.transparent)
    #expect(transparent.state == .off)
    model.setTransparent(true)
    let cancel = try #require(model.onCancel)
    cancel()
    #expect(model.checks["transparent"] == false)
    #expect(transparent.state == .off)


}

@MainActor
private func appearanceControl(in view: NSView, identifier: String) -> NSView? {
    if view.accessibilityIdentifier() == identifier {
        return view
    }
    for child in view.subviews {
        if let control = appearanceControl(in: child, identifier: identifier) {
            return control
        }
    }
    return nil
}

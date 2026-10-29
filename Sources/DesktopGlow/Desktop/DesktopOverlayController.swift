import AppKit

@MainActor
final class DesktopOverlayController: NSObject, NSWindowDelegate {
    private struct Overlay {
        let window: DesktopOverlayWindow
        let view: DesktopContentView
    }

    private(set) var preferences: WallpaperPreferences
    private var overlays: [UInt32: Overlay] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var conditions = RenderConditions()
    var statusChanged: (() -> Void)?

    var status: String {
        if let reason = conditions.pauseReason(for: preferences) {
            return reason
        }
        let running = overlays.values.filter { !$0.view.isPaused }.count
        if running == 0 {
            return overlays.isEmpty ? "No display is available." : "Paused while the desktop is covered."
        }
        return "Dither effect running on \(running) display\(running == 1 ? "" : "s")."
    }

    var diagnostics: [[String: Any]] {
        overlays.map { display, overlay in
            [
                "displayID": display,
                "windowID": overlay.window.windowNumber,
                "level": overlay.window.level.rawValue,
                "ignoresMouseEvents": overlay.window.ignoresMouseEvents,
                "canBecomeKey": overlay.window.canBecomeKey,
                "paused": overlay.view.isPaused,
                "content": "Metal dither renderer",
                "renderedFrames": overlay.view.renderedFrames,
                "renderError": overlay.view.renderError ?? "",
                "transparent": DitherSettings.shared.configuration.transparent,
                "frame": NSStringFromRect(overlay.window.frame)
            ]
        }
    }

    init(preferences: WallpaperPreferences) {
        self.preferences = preferences.normalized
        super.init()
    }

    func start() {
        guard observers.isEmpty, DesktopLayering.isBelowDesktopIcons else {
            return
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.conditions.displaysAsleep = true
            self?.updateRenderingState()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.conditions.displaysAsleep = true
            self?.updateRenderingState()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.conditions.displaysAsleep = false
            self?.refreshEnvironment()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.conditions.displaysAsleep = false
            self?.refreshEnvironment()
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            self?.conditions.sessionInactive = true
            self?.updateRenderingState()
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            self?.conditions.sessionInactive = false
            self?.refreshEnvironment()
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.updateRenderingState()
        }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in
            self?.refreshEnvironment()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.reconcileDisplays()
        }
        observe(.default, .NSProcessInfoPowerStateDidChange) { [weak self] in
            self?.refreshEnvironment()
        }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in
            self?.refreshEnvironment()
        }
        refreshEnvironment()
        reconcileDisplays()
    }

    func update(_ preferences: WallpaperPreferences) {
        let previousScope = self.preferences.displayScope
        self.preferences = preferences.normalized
        if previousScope != self.preferences.displayScope {
            reconcileDisplays()
        } else {
            for overlay in overlays.values {
                overlay.view.apply(self.preferences.configuration)
            }
            updateRenderingState()
        }
    }

    func stop() {
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
        for overlay in overlays.values {
            overlay.view.setPaused(true)
            overlay.window.delegate = nil
            overlay.window.close()
        }
        overlays.removeAll()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateRenderingState()
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        action: @MainActor @escaping @Sendable () -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                action()
            }
        }
        observers.append((center, token))
    }

    private func refreshEnvironment() {
        conditions.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        conditions.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let thermal = ProcessInfo.processInfo.thermalState
        conditions.thermallyConstrained = thermal == .serious || thermal == .critical
        updateRenderingState()
    }

    private func reconcileDisplays() {
        let screens = preferences.displayScope == .main ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
        let displayIDs = Set(screens.compactMap(displayID))
        for identifier in Array(overlays.keys) where !displayIDs.contains(identifier) {
            if let removed = overlays.removeValue(forKey: identifier) {
                removed.view.setPaused(true)
                removed.window.delegate = nil
                removed.window.close()
            }
        }
        for screen in screens {
            guard let identifier = displayID(screen) else {
                continue
            }
            if let existing = overlays[identifier] {
                existing.window.setFrame(screen.frame, display: false)
                existing.view.apply(preferences.configuration)
            } else {
                let view = DesktopContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.apply(preferences.configuration)
                view.setPaused(true)
                let window = DesktopOverlayWindow(screen: screen, effectView: view)
                window.delegate = self
                overlays[identifier] = Overlay(window: window, view: view)
            }
        }
        updateRenderingState()
    }

    private func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func updateRenderingState() {
        let globallyPaused = conditions.pauseReason(for: preferences) != nil
        for overlay in overlays.values {
            if globallyPaused {
                overlay.view.setPaused(true)
                if overlay.window.isVisible {
                    overlay.window.orderOut(nil)
                }
                continue
            }
            if !overlay.window.isVisible {
                overlay.window.orderFrontRegardless()
            }
            let covered = !overlay.window.occlusionState.contains(.visible)
            let noVisibleParticles = preferences.configuration.opacity == 0
            overlay.view.setPaused(noVisibleParticles || (preferences.pauseWhenCovered && covered))
        }
        statusChanged?()
    }
}

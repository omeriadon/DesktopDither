import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private var preferences = WallpaperPreferences()
    private var overlayController: DesktopOverlayController?
    private var settingsController: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = WallpaperPreferences.load(from: defaults)
        createMenu()
        let controller = DesktopOverlayController(preferences: preferences)
        overlayController = controller
        controller.statusChanged = { [weak self] in
            guard let self else {
                return
            }
            self.settingsController?.updateStatus(self.overlayController?.status ?? "")
        }
        controller.start()
        showSettings()
        if let pathIndex = CommandLine.arguments.firstIndex(of: "--diagnostics"),
           CommandLine.arguments.indices.contains(pathIndex + 1) {
            let path = CommandLine.arguments[pathIndex + 1]
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.writeDiagnostics(to: path)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayController?.stop()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func createMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "Desktop Glow")
        item.button?.toolTip = "Desktop Glow"
        item.button?.setAccessibilityLabel("Desktop Glow controls")
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let toggle = NSMenuItem(title: "Pause Desktop Layer", action: #selector(toggleEffects), keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Desktop Glow", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        updateMenu()
    }

    private func apply(_ preferences: WallpaperPreferences) {
        self.preferences = preferences.normalized
        self.preferences.save(to: defaults)
        overlayController?.update(self.preferences)
        updateMenu()
    }

    private func updateMenu() {
        toggleItem?.title = preferences.enabled ? "Pause Desktop Layer" : "Resume Desktop Layer"
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(preferences: preferences) { [weak self] preferences in
                self?.apply(preferences)
            }
        }
        settingsController?.reload(preferences)
        settingsController?.updateStatus(overlayController?.status ?? "")
        settingsController?.showWindow(nil)
        NSApplication.shared.activate()
    }

    @objc private func toggleEffects() {
        preferences.enabled.toggle()
        apply(preferences)
        settingsController?.reload(preferences)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func writeDiagnostics(to path: String) {
        let result: [String: Any] = [
            "status": overlayController?.status ?? "",
            "overlays": overlayController?.diagnostics ?? [],
            "desktopLevel": CGWindowLevelForKey(.desktopWindow),
            "iconLevel": CGWindowLevelForKey(.desktopIconWindow)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

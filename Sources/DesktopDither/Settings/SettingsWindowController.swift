import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var preferences: WallpaperPreferences
    private let onChange: (WallpaperPreferences) -> Void
    private let enabled = NSButton(checkboxWithTitle: "Enable desktop layer", target: nil, action: nil)
    private let displays = NSPopUpButton()
    private let opacity = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "")
    private let covered = NSButton(checkboxWithTitle: "Pause when the desktop is fully covered", target: nil, action: nil)
    private let lowPower = NSButton(checkboxWithTitle: "Pause in Low Power Mode", target: nil, action: nil)
    private let reduceMotion = NSButton(checkboxWithTitle: "Respect Reduce Motion", target: nil, action: nil)
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let ditherSettings = DitherSettings.shared
    private let ditherModel = DitherOptionsModel()

    init(preferences: WallpaperPreferences, onChange: @escaping (WallpaperPreferences) -> Void) {
        self.preferences = preferences
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 820),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Desktop Dither Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        ditherModel.onSave = { [weak self] in
            guard let self else {
                return
            }
            do {
                let values = try self.ditherModel.values()
                self.ditherSettings.apply(values)
                self.ditherModel.loadValues(
                    self.ditherSettings.values,
                    configuration: self.ditherSettings.configuration,
                    resetScroll: false
                )
                self.onChange(self.preferences.normalized)
            } catch {
                self.updateStatus(error.localizedDescription)
            }
        }
        ditherModel.onCancel = { [weak self] in
            guard let self else {
                return
            }
            self.ditherModel.loadValues(self.ditherSettings.values, configuration: self.ditherSettings.configuration)
        }
        window.delegate = self
        buildContent()
        reload(preferences)
        window.center()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        ditherModel.beginPreview()
    }

    func windowWillClose(_ notification: Notification) {
        ditherModel.endPreview()
    }

    func reload(_ preferences: WallpaperPreferences) {
        self.preferences = preferences
        ditherModel.loadValues(ditherSettings.values, configuration: ditherSettings.configuration)
        enabled.state = preferences.enabled ? .on : .off
        displays.selectItem(at: DisplayScope.allCases.firstIndex(of: preferences.displayScope) ?? 0)
        opacity.doubleValue = preferences.configuration.opacity
        covered.state = preferences.pauseWhenCovered ? .on : .off
        lowPower.state = preferences.respectLowPowerMode ? .on : .off
        reduceMotion.state = preferences.respectReduceMotion ? .on : .off
        refreshValues()
    }

    func updateStatus(_ status: String) {
        statusField.stringValue = status
    }

    private func buildContent() {
        guard let content = window?.contentView else {
            return
        }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        let effectTab = NSTabViewItem(identifier: "effect")
        effectTab.label = "Effect"
        let ditherView = NSHostingView(rootView: DitherOptionsView(model: ditherModel))
        ditherView.setAccessibilityIdentifier("dither.options")
        effectTab.view = ditherView
        tabs.addTabViewItem(effectTab)

        let desktopTab = NSTabViewItem(identifier: "desktop")
        desktopTab.label = "Desktop"
        let desktopContent = NSView()
        desktopTab.view = desktopContent
        tabs.addTabViewItem(desktopTab)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        desktopContent.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: desktopContent.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: desktopContent.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: desktopContent.topAnchor, constant: 24),
            root.bottomAnchor.constraint(lessThanOrEqualTo: desktopContent.bottomAnchor, constant: -20)
        ])

        let title = NSTextField(labelWithString: "Desktop Dither")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        root.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "A live dither effect rendered behind your desktop icons. Wallpaper remains visible when enabled below.")
        subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitle)

        configure(enabled, label: "Enable desktop layer", identifier: "effects.enabled")
        root.addArrangedSubview(enabled)
        displays.addItems(withTitles: DisplayScope.allCases.map(\.title))
        configure(displays, label: "Displays for the desktop layer", identifier: "effects.displays")
        configure(opacity, label: "Desktop layer opacity", identifier: "effects.opacity")
        let appearance = NSGridView(views: [
            [label("Opacity"), sliderRow(opacity, value: opacityValue)],
            [label("Displays"), displays]
        ])
        appearance.rowSpacing = 14
        appearance.columnSpacing = 20
        appearance.column(at: 0).width = 85
        appearance.column(at: 1).xPlacement = .fill
        root.addArrangedSubview(section("Appearance", content: appearance))

        configure(covered, label: covered.title, identifier: "power.covered")
        configure(lowPower, label: lowPower.title, identifier: "power.lowPower")
        configure(reduceMotion, label: reduceMotion.title, identifier: "power.reduceMotion")
        let policies = NSStackView(views: [covered, lowPower, reduceMotion])
        policies.orientation = .vertical
        policies.alignment = .leading
        policies.spacing = 9
        root.addArrangedSubview(section("Efficiency", content: policies))

        statusField.font = .systemFont(ofSize: 12)
        statusField.textColor = .secondaryLabelColor
        statusField.setAccessibilityIdentifier("effects.status")
        root.addArrangedSubview(statusField)
        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetPreferences))
        reset.bezelStyle = .rounded
        reset.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        reset.imagePosition = .imageLeading
        reset.setAccessibilityLabel("Reset effect settings to defaults")
        reset.setAccessibilityIdentifier("effects.reset")
        root.addArrangedSubview(reset)
        for view in root.arrangedSubviews where view is NSBox || view is NSTextField {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
    }

    private func label(_ title: String) -> NSTextField {
        NSTextField(labelWithString: title)
    }

    private func sliderRow(_ slider: NSSlider, value: NSTextField) -> NSView {
        slider.isContinuous = true
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        value.alignment = .right
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.widthAnchor.constraint(equalToConstant: 45).isActive = true
        return NSStackView(views: [slider, value])
    }

    private func section(_ title: String, content: NSView) -> NSBox {
        let box = NSBox()
        box.title = title
        let container = NSView()
        box.contentView = container
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])
        return box
    }

    private func configure(_ control: NSControl, label: String, identifier: String) {
        control.target = self
        control.action = #selector(changePreferences)
        control.setAccessibilityLabel(label)
        control.setAccessibilityIdentifier(identifier)
    }

    private func refreshValues() {
        opacityValue.stringValue = String(format: "%.0f%%", opacity.doubleValue * 100)
    }

    @objc private func changePreferences() {
        preferences.enabled = enabled.state == .on
        preferences.configuration.opacity = opacity.doubleValue
        preferences.displayScope = DisplayScope.allCases[max(0, displays.indexOfSelectedItem)]
        preferences.pauseWhenCovered = covered.state == .on
        preferences.respectLowPowerMode = lowPower.state == .on
        preferences.respectReduceMotion = reduceMotion.state == .on
        refreshValues()
        onChange(preferences.normalized)
    }

    @objc private func resetPreferences() {
        reload(WallpaperPreferences())
        onChange(preferences)
    }
}

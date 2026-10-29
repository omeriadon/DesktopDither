import AppKit
import QuartzCore

@MainActor
final class DesktopContentView: NSView {
    private let ditherView: DitherPreviewView
    private let effectSettings: DitherSettings
    private(set) var isPaused = true

    convenience override init(frame frameRect: NSRect) {
        self.init(frame: frameRect, effectSettings: .shared)
    }

    init(frame frameRect: NSRect, effectSettings: DitherSettings = .shared) {
        ditherView = DitherPreviewView(frame: frameRect)
        self.effectSettings = effectSettings
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        ditherView = DitherPreviewView(frame: .zero)
        effectSettings = .shared
        super.init(coder: coder)
        configure()
    }

    func apply(_ configuration: OverlayConfiguration) {
        let effectConfiguration = effectSettings.configuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = 1
        layer?.backgroundColor = effectConfiguration.transparent
            ? NSColor.clear.cgColor
            : NSColor(
                srgbRed: CGFloat(effectConfiguration.backgroundColor.x),
                green: CGFloat(effectConfiguration.backgroundColor.y),
                blue: CGFloat(effectConfiguration.backgroundColor.z),
                alpha: 1
            ).cgColor
        ditherView.alphaValue = CGFloat(configuration.normalized.opacity)
        CATransaction.commit()
        ditherView.setConfiguration(effectConfiguration)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        ditherView.setActive(!paused)
    }

    var renderError: String? {
        ditherView.lastRenderError
    }

    var renderedFrames: Int {
        ditherView.renderedFrames
    }

    private func configure() {
        ditherView.useDesktopPresentation()
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.masksToBounds = true
        ditherView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ditherView)
        NSLayoutConstraint.activate([
            ditherView.leadingAnchor.constraint(equalTo: leadingAnchor),
            ditherView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ditherView.topAnchor.constraint(equalTo: topAnchor),
            ditherView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

import AppKit
import QuartzCore

@MainActor
final class DesktopContentView: NSView {
    private let ditherView: DitherPreviewView
    private(set) var isPaused = true

    override init(frame frameRect: NSRect) {
        ditherView = DitherPreviewView(frame: frameRect)
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        ditherView = DitherPreviewView(frame: .zero)
        super.init(coder: coder)
        configure()
    }

    func apply(_ configuration: OverlayConfiguration) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = Float(configuration.normalized.opacity)
        CATransaction.commit()
        ditherView.setConfiguration(DitherSettings.shared.configuration)
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

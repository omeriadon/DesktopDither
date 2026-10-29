import AppKit
import QuartzCore

final class DitherPreviewView: NSView {
    static let displayAspectRatio: CGFloat = 16.0 / 9.0

    private let metalLayer = CAMetalLayer()
    private var renderer: DitherMetalRenderer?
    private var timer: Timer?
    private var configuration = DitherConfiguration()
    private var isActive = false
    var scalesCellsForPreview = true
    private(set) var lastRenderError: String?
    private(set) var renderedFrames = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.cornerRadius = 16
        metalLayer.masksToBounds = true
        layer = metalLayer
        do {
            renderer = try DitherMetalRenderer()
        } catch {
            lastRenderError = error.localizedDescription
            NSLog("Desktop Dither: Metal initialization failed: %@", error.localizedDescription)
        }
        metalLayer.device = renderer?.device
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Live dither preview")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func setConfiguration(_ configuration: DitherConfiguration) {
        guard self.configuration != configuration else {
            return
        }
        if self.configuration.intro == false && configuration.intro {
            renderer?.restartIntro()
        }
        self.configuration = configuration
        if isActive {
            stopTimer()
            startTimerIfNeeded()
        }
        renderFrame(advance: false)
    }

    func setActive(_ active: Bool) {
        guard isActive != active else {
            return
        }
        isActive = active
        if active {
            startTimerIfNeeded()
            renderFrame(advance: false)
        } else {
            stopTimer()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopTimer()
        } else {
            startTimerIfNeeded()
            renderFrame(advance: false)
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        stopTimer()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        startTimerIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderFrame(advance: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderFrame(advance: false)
    }

    func useDesktopPresentation() {
        scalesCellsForPreview = false
        metalLayer.cornerRadius = 0
        setAccessibilityElement(false)
    }

    private func startTimerIfNeeded() {
        guard isActive,
              window != nil,
              !isHiddenOrHasHiddenAncestor,
              timer == nil,
              renderer != nil,
              let interval = renderInterval else {
            return
        }
        renderer?.seedAnimationTiming()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                guard self.isActive, self.window != nil, !self.isHiddenOrHasHiddenAncestor else {
                    self.stopTimer()
                    return
                }
                self.renderFrame(advance: true)
                let nextInterval = self.renderInterval
                if nextInterval != self.timer?.timeInterval {
                    self.stopTimer()
                    self.startTimerIfNeeded()
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        renderer?.resetAnimationTiming()
    }

    private var renderInterval: TimeInterval? {
        DitherRenderSchedulingPolicy.interval(
            for: configuration,
            introComplete: renderer?.isIntroComplete ?? true
        )
    }

    private func renderFrame(advance: Bool) {
        guard window != nil,
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 0,
              bounds.height > 0,
              let renderer else {
            return
        }
        let scale = window?.backingScaleFactor ?? 1
        let drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if metalLayer.drawableSize != drawableSize {
            metalLayer.drawableSize = drawableSize
        }
        guard let drawable = metalLayer.nextDrawable() else {
            return
        }
        do {
            var previewConfiguration = configuration
            if scalesCellsForPreview, let screenWidth = window?.screen?.frame.width, screenWidth > 0 {
                previewConfiguration.pixelSize *= Float(bounds.width / screenWidth)
            }
            try renderer.render(to: drawable, size: bounds.size, configuration: previewConfiguration, advance: advance)
            renderedFrames += 1
            lastRenderError = nil
        } catch {
            lastRenderError = error.localizedDescription
            NSLog("Dither: preview render failed: %@", String(describing: error))
        }
    }
}

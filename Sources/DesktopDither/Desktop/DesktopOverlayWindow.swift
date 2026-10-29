import AppKit

@MainActor
final class DesktopOverlayWindow: NSWindow {
    init(screen: NSScreen, effectView: NSView) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        title = "Desktop Dither overlay"
        level = DesktopLayering.effectLevel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        contentView = effectView
        setFrame(screen.frame, display: false)
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

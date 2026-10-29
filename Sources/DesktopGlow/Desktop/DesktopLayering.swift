import AppKit
import CoreGraphics

enum DesktopLayering {
    static var effectLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    }

    static var isBelowDesktopIcons: Bool {
        effectLevel.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow))
    }
}

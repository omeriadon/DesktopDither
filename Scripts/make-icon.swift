import AppKit
import Foundation

let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024,
    pixelsHigh: 1024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Could not create icon bitmap.")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let frame = NSRect(origin: .zero, size: size).insetBy(dx: 50, dy: 50)
let background = NSBezierPath(roundedRect: frame, xRadius: 205, yRadius: 205)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.08, green: 0.33, blue: 0.29, alpha: 1),
    ending: NSColor(calibratedRed: 0.02, green: 0.10, blue: 0.13, alpha: 1)
)
gradient?.draw(in: background, angle: 100)
let symbolConfiguration = NSImage.SymbolConfiguration(paletteColors: [.white])
if let keyboard = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfiguration) {
    keyboard.draw(in: NSRect(x: 190, y: 235, width: 644, height: 550))
}
if let sparkle = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfiguration) {
    sparkle.draw(in: NSRect(x: 692, y: 678, width: 130, height: 142))
}
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon.")
}
try png.write(to: URL(fileURLWithPath: output))

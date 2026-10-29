import CoreGraphics
import Foundation

let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
let selected = windows.enumerated().compactMap { index, window -> [String: Any]? in
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let level = window[kCGWindowLayer as String] as? Int ?? 0
    guard level < 0 || ["Dock", "Desktop Glow", "DesktopGlow"].contains(owner) else {
        return nil
    }
    return [
        "order": index,
        "owner": owner,
        "level": level,
        "windowID": window[kCGWindowNumber as String] ?? 0,
        "onscreen": window[kCGWindowIsOnscreen as String] ?? false,
        "bounds": window[kCGWindowBounds as String] ?? [:]
    ]
}
let result: [String: Any] = [
    "queriedDesktopLevel": CGWindowLevelForKey(.desktopWindow),
    "queriedIconLevel": CGWindowLevelForKey(.desktopIconWindow),
    "windows": selected
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)

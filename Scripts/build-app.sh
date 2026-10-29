#!/bin/bash
set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$package_root"

# Use the installed full Xcode toolchain when Command Line Tools lack SwiftUI macros.
if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode 27.2 rc.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode 27.2 rc.app/Contents/Developer"
fi

swift build -c release 2>&1 | xcsift -f toon -w
binary_directory="$(swift build -c release --show-bin-path)"
app_bundle="$package_root/dist/Desktop Dither.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$binary_directory/DesktopDither" "$app_bundle/Contents/MacOS/DesktopDither"

cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DesktopDither</string>
    <key>CFBundleIdentifier</key>
    <string>local.desktopglow.app</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>Desktop Dither</string>
    <key>CFBundleDisplayName</key>
    <string>Desktop Dither</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

icon_work="$(mktemp -d)"
trap 'rm -rf "$icon_work"' EXIT
mkdir -p "$icon_work/AppIcon.iconset"
swift "$package_root/Scripts/make-icon.swift" "$icon_work/source.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_work/source.png" --out "$icon_work/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$icon_work/source.png" --out "$icon_work/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_work/AppIcon.iconset" -o "$app_bundle/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$app_bundle"
codesign --verify --strict "$app_bundle"
echo "$app_bundle"

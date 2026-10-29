# Desktop Dither

A macOS desktop wallpaper renderer built with AppKit and Metal.

The desktop layer renders the Metal dither effect copied from Dither Screen Saver. The Effect tab reuses its settings view and live preview. Enable **Show wallpaper behind effect** in the color section and click **Save** to remove the solid background while retaining the effect. Cancel restores the saved effect settings.

## Open and build

Open `Package.swift` in Xcode to edit the project. Xcode MCP is unavailable in this session, so verification uses Swift Package Manager, never `xcodebuild`.

```sh
./Scripts/build-app.sh
open 'dist/Desktop Dither.app'
```

The local app is ad-hoc signed. The script selects the installed full Xcode toolchain locally without changing `xcode-select`. It requires macOS 26 or later and has no third-party dependencies.

## Desktop host

One transparent, borderless window is created for each selected display. Its queried window level is `.desktopWindow + 1`, below `.desktopIconWindow`. It ignores mouse events, cannot become key or main, and leaves wallpaper and desktop interaction alone. It uses public AppKit APIs without injection, private SkyLight calls, Accessibility permission, wallpaper replacement, or a privileged helper.

Settings provide a master enable switch, **Effect opacity** and **Show wallpaper behind effect** under Desktop → Appearance, all-displays/menu-bar-display selection, and visibility/power-policy controls. Opacity is applied to the dither sublayer, so an opaque effect fades toward its selected background and a transparent effect fades toward wallpaper without rerendering Metal for slider-only changes. Desktop preferences persist in the app defaults; effect settings use the separate `local.desktopglow.dither` suite. Screen saver preferences are untouched. Closing Settings leaves the menu-bar app running; its menu pauses the layer or quits the app.

The renderer adapts between 4 and 30 frames per second while moving. At the default scale and detail, wave speed 0.05 uses 30 fps and 0.01 uses 6 fps. Smaller scale, higher frequency, and higher contrast raise the cadence conservatively. The intro uses 30 fps, then switches to the selected cadence. Zero speed or disabled animation stops the timer after the intro; settings and resize changes still redraw. This trades temporal sampling for lower GPU work while preserving spatial resolution. Screen/session/power/occlusion changes control its timer. Disabled layers are ordered out. Closing Settings stops its preview while the desktop effect continues under the selected policies.

## Rendering integration

`DesktopContentView` hosts `DitherPreviewView` in desktop mode, with square screen edges and cell sizing at the display backing scale. Each selected screen owns a separate renderer. `apply(_:)` updates opacity and the saved effect configuration; `setPaused(_:)` starts or stops rendering. Transparent shader output uses premultiplied alpha for both single-color and multicolor palettes.

## Research and verification

`Research/desktop-layering.md` records Apple documentation, alternatives, local window-level evidence, and limitations. Public window levels fit the required ordering on this Mac: wallpaper, dither effect, icons/widgets, normal apps, Dock/menu bar. Widget layering is observed behavior rather than a dedicated Apple wallpaper-extension contract. Fullscreen, Stage Manager, Mission Control, lock/unlock, and every Space transition have not been exhaustively exercised.

Tests cover window-level placement, click-through/focus refusal, pause-policy decisions, preference persistence, opacity validation, and GPU transparency output for single-color and multicolor rendering.

```sh
set -o pipefail
DEVELOPER_DIR='/Applications/Xcode 27.2 rc.app/Contents/Developer' swift test -c release --experimental-lto-mode full -debug-info-format none 2>&1 | tee Research/release-tests.log | xcsift -f toon -w
```

## Performance measurements

See `Research/render-performance.md` for measurements and limits. Run the opt-in GPU and live cadence benchmarks with:

```sh
set -o pipefail
DEVELOPER_DIR='/Applications/Xcode 27.2 rc.app/Contents/Developer' DESKTOP_GLOW_BENCHMARK=1 swift test -c release --experimental-lto-mode full -debug-info-format none --filter 'measureLiveRenderCadence|measureRendererGPUCost' 2>&1 | tee /tmp/desktopglow-benchmark.log | xcsift -f toon -w
```

The raw log retains `GPU_BENCHMARK` and `CADENCE_BENCHMARK` records. Ordinary tests skip these measurements.

Release uses SwiftPM optimization and full experimental link-time optimization, with debug information omitted. LTO affects CPU code generation and linking; it is not a GPU optimization. Renderer metrics report only this renderer's own render encoders, compute dispatches, and Gaussian encodes; MPS internal passes are not counted.

## Variable top blur

The dither grid has a 104-point top strip with a maximum Gaussian sigma of 5 points. Blur decreases exponentially with a smooth taper to zero at the lower boundary. Only the grid is blurred; desktop wallpaper and other windows are not sampled. Reusable strip textures and Apple Metal Performance Shaders provide three Gaussian levels at 0.5, 2, and 5 points. See [implementation and verification](Research/top-blur.md).

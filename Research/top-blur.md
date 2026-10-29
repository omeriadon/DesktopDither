# Variable top blur and compositor opacity

The production path generates the dither cell grid with compute, followed by two explicit render passes: the cropped blur source and final composition. Coverage atlas generation and joined-neighbor masks also use compute, so rounded shapes do not add render passes. The independent nonfused reference path remains available for tests.

## Blur profile and work bounds

The strip remains 104 logical points high, with maximum Gaussian sigma 5 points. Its broader falloff is `sigma(t) = 5 * exp(-3t) * (1-t)^2`, replacing the previous exponential coefficient 4. The coefficient is defined once in Swift and emitted into the Metal shader source. The maximum, boundary and zero boundary slope are unchanged.

The source is a reusable BGRA8 strip with a maximum three-sigma sampling halo. It retains full-drawable grid coordinates, starts at Metal row zero, and matches the sharp output format. Three reusable MPS Gaussian outputs at sigma 0.5, 2 and 5 points use RGBA16Float. Each output is cropped to the rows where it contributes. The final draw interpolates adjacent levels without extrapolation and is scissored to the top strip. Pixels below and around its lower boundary remain byte-exact against sharp output.

A gentler curve makes the higher-sigma levels contribute farther down, so their cropped textures can gain rows. The operation count stays fixed; equal GPU cost is not guaranteed. This is an interpolation of fixed Gaussian levels, not an exact variable-sigma convolution. No wallpaper or other windows are captured.

## Operation count

With blur enabled, the production path has two explicit render encoders, one compute encoder containing one to three dispatches, and three MPS Gaussian encodes. A flat grid needs one dispatch. Joined rounded cells need a second dispatch, and a coverage cache miss needs a third. Initialization also generates a shared gradient texture once, outside per-frame counts. With blur disabled, the production path needs one final render encoder and no MPS blur encodes.

`RenderMetrics` counts renderer-owned render passes, compute dispatches and Gaussian encodes. It also counts the extra field/cell render passes in the test-only nonfused path. Apple does not guarantee an internal pass count for MPS. Two render passes therefore does not mean two total GPU operations.

The compute grid uses the same pixel-center coordinates, quantization and palette arithmetic as the preserved reference renderer. A texture memory barrier orders grid writes before join reads in the same compute encoder. Tracked texture dependencies order later render/MPS consumers. Coverage textures enter the cache only after command-buffer submission. Error paths close an active compute encoder without submitting incomplete work. Unused render pipeline objects from the compute migration were removed.

## Opacity and background

Desktop → Appearance contains Effect opacity and Show wallpaper behind effect. Opacity changes the dither subview's compositor alpha; the host stays at opacity 1. Wallpaper mode clears the host background. Background mode keeps the configured effect background color opaque, so lowering opacity fades into that color. At zero opacity the renderer can pause under the existing policy while the selected background stays visible.

The Desktop toggle and saved Effect transparency setting share one preference. The immediate Desktop action updates only the transparency field of the draft Effect model, preserving unrelated unsaved edits. Effect Save/Cancel refreshes the Desktop control. An opacity-only change with unchanged effect configuration does not redraw Metal. Resuming rendering after zero opacity can still require a frame.

This adds no shader uniform or Metal pass for opacity. WindowServer compositing is separate work and is not covered by offscreen GPU timings.

## Color and Apple sample review

There is no dedicated color/gamma correction pass. Palette, brightness and contrast are fused into grid generation. The blur source is non-sRGB BGRA8Unorm, the intermediates are RGBA16Float, and the presentation layer is tagged sRGB. The blur averages stored values without explicit linear-light conversion; floating-point intermediates do not change that transfer function.

[Apple's heap/event sample review](apple-heaps-events-review.md) covers temporary resource lifetimes, separable blur, aliasing and synchronization. Our source and three outputs remain live together for final composition, so they cannot alias each other. Persistent cached textures and a single tracked queue do not establish a benefit from adding heap events. No unmeasured heap/event migration or color-space change was introduced.

## Release build and verification

`Scripts/build-app.sh` uses release optimization and full LTO, with debug information omitted. It preserves the caller's toolchain selection and only selects the locally installed Xcode fallback if present. LTO affects CPU code generation and linking, not MPS internals or Metal mathematics. Full LTO with DWARF produced missing temporary-object dSYM warnings in this toolchain; the distribution configuration omits DWARF and the final checks are warning-free.

All 30 tests pass in the final configuration (`two-pass-final-release-tests.log`). They cover byte-exact reference images, 1x/2x blur output against a CPU Gaussian reference, transparency, strip boundaries, tiny/resized viewports, joined cells, cache reuse, and large-cell fallback. Numeric Gaussian comparisons allow 0.02 normalized channel error because MPS is approximate and the source is quantized.

Compositor tests attach a real window, verify that it rendered, then check that opacity-only changes leave the rendered-frame counter unchanged. Control-action tests exercise the opacity slider, Desktop transparency toggle, draft preservation and Effect Save/Cancel in an isolated preferences suite.

Final build/signature log: `two-pass-final-build.log`. Relaunch diagnostics: `two-pass-final-runtime.json`. Inspection images: `two-pass-final-images/`. Earlier artifacts retain their historical parameters.

## GPU measurements

`two-pass-final-benchmark.json` uses a 3024 × 1964 BGRA8 target, 2x scale, 4-device-pixel cells, 10 warm-up frames and 50 measured frames for each combination. All four sharp/blurred and opaque/transparent combinations rotate together at identical animation times, reducing ordering bias from GPU clocks.

- Opaque: sharp 0.554 ms; blurred 0.968 ms.
- Transparent: sharp 0.554 ms; blurred 0.981 ms.

Both blurred cases report two render passes, one compute dispatch and three Gaussian encodes. These are renderer-only GPU timestamps, excluding WindowServer, presentation and scanout. They do not establish identical compositor cost or energy usage. Earlier sequential transparency measurements in `two-pass-blur-benchmark.json` are retained as historical trials; final measurements interleave transparency modes as well as blur paths.

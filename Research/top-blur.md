# Variable top blur

The production renderer composites sharp dither below the top strip and variable blur inside it, in one final render pass. When `usesTopBlur` is enabled, it first renders the dither into a reusable `bgra8Unorm` source strip whose viewport uniforms retain the full drawable dimensions. The strip starts at Metal row zero (the visible top), with lower padding for the maximum Gaussian support. The source format matches the original sharp output exactly; Gaussian intermediate levels use `rgba16Float`. It is therefore a crop of the dither output, not a capture of desktop windows or underlying wallpaper.

The visible strip is 104 logical points high. The renderer derives the backing scale from the drawable width divided by the logical view width; the offscreen overload accepts an explicit scale. The maximum Gaussian sigma is 5 logical points, converted to device pixels. MPS image Gaussian blur kernels at 0.5, 2, and 5 logical points are reused with the strip textures. The composite samples adjacent levels and linearly interpolates them over [0, 0.5], [0.5, 2], and [2, 5], without extrapolation. This is a continuous approximation of a spatially varying Gaussian, not one exact Gaussian convolution whose sigma changes per pixel.

The sigma profile is

`sigma(t) = 5 * exp(-4t) * (1 - t)^2`, where `t` is normalized distance from the top of the strip.

It is monotonic, equals 5 at the top, reaches exactly zero at the 104-point boundary, and has zero first derivative there. The profile controls blur level only. It does not fade opacity. Premultiplied RGBA is preserved through the source and MPS intermediate textures, including transparent dither output.

The sharp full-frame pass remains unchanged when blur is disabled. Gaussian destination textures are cropped vertically to the rows where each level contributes; the highest-sigma levels process only the top few rows. Kernels use clamp-to-edge sampling. Source/level textures and kernels are reused until dimensions or backing scale change. Sharp and blurred composition share the final render encoder, avoiding a full-display load/store round trip. The source and intermediate textures are strip-sized, not full-display images. The blur composite uses a scissor restricted to the strip, so there are no blur texture lookups below the strip. Existing reference and image-equality tests explicitly construct the renderer with `usesTopBlur: false`.

Focused tests cover exact lower-frame equality at 1x and 2x, visible top-strip difference, the monotonic profile and zero boundary, premultiplied transparency, and the existing independent renderer cases. The opt-in `measureTopBlurGPUCostAndWriteInspectionCrops` test interleaves sharp and blurred fixed-time frames at 3024x1964 with cell 4 and scale 2. Set `DESKTOP_GLOW_BENCHMARK=1`; set `DESKTOP_GLOW_BLUR_BENCHMARK_OUTPUT` for machine-readable JSON and `DESKTOP_GLOW_BLUR_BENCHMARK_ARTIFACTS` for `top-blur-sharp.png` and `top-blur-blurred.png` inspection crops.

## Review and verification

Primary review corrected the initial vertical orientation, the level interpolation intervals, and a half-pixel sampling offset. Metal fragment positions are already pixel-centered and have their origin at the top. The corrected shader uses pixel coordinates directly, interpolates each adjacent pair only over its own sigma interval, and never extrapolates.

The focused suite compares GPU output against a CPU Gaussian reference at eight heights spanning the three transitions and the 104-point seam, four horizontal positions, all RGBA channels, and 1x/2x backing scale. It also checks the explicit 104-point strip and 5-point maximum. The tests include colored palettes, rounded/gapped transparent cells, premultiplied-alpha bounds, exact bytes below and around the 104-point boundary, single-pixel/tiny viewports, changes of size/backing scale, joined cells, and large-cell fallback. MPS approximates a Gaussian; numerical checks allow 0.02 normalized channel error, including BGRA8 quantization. The level-interpolated effect is not an exact per-pixel variable-sigma convolution. Earlier five-level/80-point benchmark results in historical research files describe the superseded implementation and are not current measurements.

Final test log: `taller-blur-final-tests.log`. Build/signing log: `taller-blur-final-build.log`. Inspection images: `taller-blur-tuned-images/`. Original optimization image cases continue to compare the preserved independent renderer with blur disabled.

## Measured GPU cost

The current benchmark uses a 3024 × 1964 offscreen BGRA8 target, 2x backing scale, 4-device-pixel cells, 10 warm-up frames and 50 measured frames per path. Sharp and blurred paths alternate order at identical animation times. The final output is `taller-blur-tuned-benchmark.json`, with inspection images under `taller-blur-tuned-images/`. The initial three-level trial used 0.3125/1.25/5-point levels and was slower; the final spacing is 0.5/2/5 points. MPS kernel choices and sampling cost mean fewer kernel encodes alone do not guarantee a faster result. Three Gaussian encodes replace five; MPS internal pass counts are implementation details.

- `taller-blur-benchmark.json`: initial three-level trial, 104-point strip and maximum sigma 5; sharp 0.818 ms; blurred 1.525 ms; added 0.707 ms per frame. Levels were 0.3125, 1.25, and 5.

- `top-blur-final-benchmark.json`: sharp 0.820 ms; blurred 1.306 ms; added 0.487 ms per frame.
- `top-blur-final-benchmark-repeat.json`: sharp 0.818 ms; blurred 1.337 ms; added 0.520 ms per frame.

GPU timestamps measure renderer work only, excluding WindowServer, presentation and scanout. These short warmed microbenchmarks vary with GPU clock and concurrent system activity; they do not establish battery savings or a whole-system cost. The earlier runtime diagnostics are `top-blur-final-runtime.json`; final DesktopDither relaunch diagnostics are `taller-blur-final-runtime.json`.

Final tuned run: sharp 0.797 ms, blurred 1.178 ms, added 0.381 ms per frame (50 samples per path). The fresh pre-change run (`taller-blur-before-benchmark.json`) measured 1.300 ms with the old 80-point, sigma-8, five-level blur. These are separate warmed runs, not a controlled isolation of height, sigma or number of encodes.

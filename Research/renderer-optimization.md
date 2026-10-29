# Renderer optimization, 29 October 2026

## Result

The optimized renderer retains the existing noise layers, resolution, animation speed, frame schedule, palettes, and cell geometry. In three paired runs on this Mac, dense four-device-pixel grids used roughly 20–25% less GPU time in the two settled runs. Coarse grids gained roughly 4–9% in those runs. These are command-buffer GPU durations, not whole-system GPU utilization or battery measurements.

## Changes

- Fuse procedural field generation and color resolution into one grid pass. Preserve the original intermediate UNORM quantization explicitly, including rounding, rather than changing threshold behavior. Production needs two render passes instead of three and no intermediate field texture.
- Precompute the noise function's fixed, repeating 289 × 289 gradient lattice on the GPU at renderer initialization. Store its normalized gradients in an RG32Float texture (668,168 bytes per renderer). Each noise evaluation reads these gradients instead of repeating permutation and normalization calculations. The moving noise values and all 12 evaluations per cell remain; this does not replace the wave with a lower-detail image.
- In the full-resolution composite, derive local coordinates by subtraction instead of floating-point remainder. Joined corners read only the two neighbors facing the current pixel. One-device-pixel cells preserve all four reads because their antialiased edge regions overlap.
- Use GPU-private intermediate textures and skip clearing a target that the fullscreen triangle overwrites completely.
- Ignore unchanged configuration and active-state updates, avoiding redundant static redraws and timer restarts.

The original shader path is retained behind an internal renderer initializer option for reproducible comparisons. It is not a UI setting. Shader and gradient resources are still created per renderer; initialization cost and multi-display resource sharing are not measured here.

## Paired GPU measurements

3024 × 1964 BGRA8 offscreen target on this Mac (Apple Silicon). Cell sizes below are device pixels. The benchmark uses the same dimensions, configuration, and fixed animation time for both paths. Six configurations are interleaved; baseline/optimized ordering alternates each cycle. Each configuration/path has 10 warm-up frames followed by 60 timed frames. Three independent invocations were run. No runtime settings were changed to obtain the savings.

The table gives medians from run 3. The final column includes the savings range across all three runs; run 1 had substantially higher absolute GPU durations, illustrating clock/load sensitivity.

| Configuration | Cell size | Baseline ms/frame | Optimized ms/frame | GPU time reduction | Range across runs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Bayer, dense grid | 4 | 0.822 | 0.643 | 21.8% | 21.7–23.4% |
| Gapped rounded cells, dense grid | 4 | 1.079 | 0.849 | 21.3% | 21.1–21.8% |
| Joined rounded cells, dense grid | 4 | 1.281 | 1.033 | 19.4% | 7.5–19.6% |
| No dithering, dense grid | 4 | 0.837 | 0.633 | 24.4% | 24.4–25.8% |
| Bayer, coarse grid | 16 | 0.358 | 0.342 | 4.4% | 4.4–13.7% |
| Joined rounded cells, coarse grid | 16 | 0.776 | 0.709 | 8.6% | 8.6–9.3% |

Configuration: speed 0.05, frequency 1.7, amplitude 0.62, scale 0.8, contrast 1.2, brightness −0.08, five opacity levels and a three-color palette. Intro disabled. Dense modes are Bayer8, radial, Noise, and None; coarse modes are Bayer8 and Noise with joins. This is a representative workload comparison, not exhaustive performance coverage of every setting.

Raw samples: `renderer-optimization-run-1.json`, `renderer-optimization-run-2.json`, and `renderer-optimization-run-3.json`. Machine-readable chart data: `renderer-optimization-summary.json`.

## Verification

- Release suite: all 18 tests pass, no compiler warnings.
- Release app packaged and ad hoc signature verified. Relaunched app reports 58 rendered frames on each of two displays after two seconds, with no render errors; see `runtime-optimized.json`.
- 144 fixed-time byte-for-byte BGRA image comparisons: eight dither modes × three shape configurations × six cell/scale/time/direction variants. Cells span 1, 2, 4, 6, 13 and 32 device pixels. Odd 193 × 137 targets exercise centered padding. Variants include zero dithering strength, zero secondary noise amplitude, plain colors, palettes and transparency.
- Existing checks cover premultiplied alpha, intro completion, pause/resume and cadence. Static-view verification now also confirms repeated unchanged settings/activation submit zero extra frames, while a real brightness change redraws once.
- The expanded image test caught and corrected two issues during review: fractional cell coordinates shifting threshold patterns, and one-pixel joined-cell edge overlap.

These comparisons cover the sampled configurations, not every possible floating-point boundary. Metal compilation, render submission, and output readback all execute on this machine. The benchmark excludes compositor work, display scanout, live drawable waiting, and other applications. There is no measured claim about battery life, power, or maximal optimization.

## Reproduce

Use the full installed Xcode toolchain; the selected Command Line Tools lack the required Swift Testing macro plugin.

```sh
set -o pipefail
export DEVELOPER_DIR='/Applications/Xcode 27.2 rc.app/Contents/Developer'
swift test -c release 2>&1 | xcsift -f toon -w
DESKTOP_GLOW_BENCHMARK=1 DESKTOP_GLOW_BENCHMARK_OUTPUT="$PWD/Research/renderer-optimization-repeat.json" swift test -c release --filter measureFusedFieldAndCellPass 2>&1 | xcsift -f toon -w
```

## 2D join-mask dispatch measurement

The existing compute helper used a threadgroup with `threadExecutionWidth × 1`
threads and one group row per image row. A bounded candidate used an
`executionWidth × 8` threadgroup for the join-mask kernel only. Field/cell and
coverage dispatches remain on the original layout because the first trial did
not show a consistent benefit there.

The baseline opt-in release benchmark was run before the change with
`measureRendererGPUCost`. Its six medians were 1.099, 1.084, 1.109, 1.073,
1.088, and 1.159 ms for modes 6/7 at speeds 0.05/0.01/0.00. The raw output is
`dispatch-baseline-20261029.log`.

The first all-kernel 2D trial was mixed: the raw samples are in
`dispatch-2d-benchmark-20261029.json`, with console output in the matching log.
The `executionWidth × 8` trial is in
`dispatch-2d-height8-benchmark-20261029.json`. Both showed small regressions on
some flat or coarse cases, so those layouts were not retained.

The retained join-mask-only trial used alternating one-dimensional and 2D
renderers in the same process for 60 measured samples after 10 warm-up frames.
Its raw samples are `dispatch-join-benchmark-20261029.json`, and the console
output is `dispatch-join-benchmark-20261029.log`. The dense joined case measured
1.407 ms for the old dispatch and 1.367 ms for the 2D dispatch (2.9% lower in
that run). The coarse joined case measured 0.744 ms and 0.740 ms (0.4% lower).
The other cases are controls; they use identical dispatch layouts and should
be interpreted as timing noise, not as an optimization result.

Both paths report the same renderer-owned operation counters: one final render
pass, two compute dispatches for joined cells (fused cell plus join mask), and
zero Gaussian encodes because the benchmark disables top blur. The differential
image test now renders the same fixed-time cases with both dispatch layouts and
requires byte equality across all eight modes, three shape configurations,
transparency variants, odd viewports, and six cell sizes. This verifies sampled
output, not every floating-point or device scheduling boundary.

The measurements are renderer command-buffer GPU durations on this Mac. They
exclude WindowServer composition, display scanout, other GPU activity, and
energy use. The retained result is a bounded kernel-local change; no claim is
made for whole-frame improvement outside the sampled joined-cell workload.

### Review repeat and production blur check

A second paired invocation (`dispatch-join-repeat-20261029.json` and `.log`)
measured dense joins at 0.6685 → 0.6537 ms (2.2% lower) and coarse joins at
0.3369 → 0.3355 ms (0.4% lower). Absolute times changed substantially between
runs; compare paired paths within a run. The repeated dense result supports a
small gain in the isolated workload, not a general application speedup.

The benchmark also accepts `DESKTOP_GLOW_DISPATCH_TOP_BLUR=1`, which enables
production top blur at 2x backing scale. The recorded invocation
(`dispatch-join-blur-20261029.json` and `.log`) was noisy: unchanged controls
varied by up to 15.7%, and the coarse joined case regressed by 11.9%. No stable
production-with-blur improvement is established by that run. Keep these raw
observations instead of reporting its apparent dense-grid gain as reliable.
The change preserves blur storage precision; no reduced-precision trial was
retained.

Reproduce the paired workload (offscreen; does not change display settings):

```sh
set -o pipefail
DEVELOPER_DIR='/Applications/Xcode 27.2 rc.app/Contents/Developer' DESKTOP_GLOW_BENCHMARK=1 swift test -c release --experimental-lto-mode full -debug-info-format none --filter measureTwoDimensionalComputeDispatch 2>&1 | xcsift -f toon -w
```

The release suite passed 31 tests with zero warnings/errors before review.
The benchmark additions for optional top blur compiled in release and both
filtered measurements passed. Packaging and signature checks do not launch the
app or alter the running desktop.

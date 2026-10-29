# Deep renderer optimization — final reviewed implementation

Measured 29 October 2026 on this Mac. This report supersedes the preliminary resource-sharing-only findings.

## Implemented

1. Share immutable Metal pipelines and the gradient texture across all displays/previews via thread-safe Swift static initialization. Mutable queues, palette buffers, animation and cell textures remain per renderer. Initialization failures propagate as errors rather than calling `fatalError`.
2. Pack two horizontal noise gradients into each RGBA32Float lookup texel. A noise evaluation now uses two gradient texture instructions instead of four. This keeps 32-bit components and the original gradient arithmetic, octaves and domain warp. The shared 289 × 289 lookup is now 1,336,336 bytes, twice the old per-renderer lookup size, but shared process-wide.
3. Cache rounded-cell coverage in R32Float atlases. Exact signed-distance and antialias calculations execute at atlas creation, not once per display pixel every frame. A key includes device-pixel cell size, gap and radius. Joinable atlases contain all 16 neighbor masks. Gapped atlases only need one mask. There are at most eight cached atlases per renderer, each capped at cell size 128; larger cells use the existing composite. Worst-case atlas storage is about 8 MiB per renderer, generally much smaller at normal cell sizes.
4. Calculate joined-neighbor masks once per grid cell into an R8Uint texture, then read the mask during final composition. Four neighbor tests run on the grid rather than repeatedly across each cell's screen pixels. The extra grid pass replaces much more full-display work.
5. Reuse the production render-pass descriptors. Publish newly generated coverage textures into the cache only after command-buffer submission so encoder failure cannot expose an uninitialized cache entry.

Flat output remains on the existing composite path with the paired-gradient improvement. Gapped output uses cached coverage. Joined rounded output uses cached coverage plus a grid mask pass. Existing static settling, cadence, sleep/occlusion policies, timing, resolution, palettes and desktop layering remain intact.

## GPU comparison against the previously optimized version

3024 × 1964 BGRA8 offscreen targets, identical settings and animation times, six interleaved configurations, rotated execution order, 10 warm-up frames and 60 measured frames per path/configuration. Three invocations, 3,240 GPU-duration observations in total. Run-3 medians follow; the range column includes all three runs.

| Configuration | Cell pixels | Previous ms | New ms | GPU time reduction | Range across runs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Bayer · dense | 4 | 0.647 | 0.586 | 9.4% | 9.2–9.6% |
| Gapped rounded · dense | 4 | 0.851 | 0.625 | 26.6% | 26.6–27.2% |
| Joined rounded · dense | 4 | 1.033 | 0.650 | 37.1% | 37.1–37.5% |
| No dithering · dense | 4 | 0.637 | 0.580 | 9.0% | 9.0–9.4% |
| Bayer · coarse | 16 | 0.350 | 0.349 | 0.3% | 0.3–1.8% |
| Joined rounded · coarse | 16 | 0.715 | 0.401 | 43.9% | 43.7–45.1% |

Coarse flat output is effectively unchanged. Other cases show stable additional improvements over the first optimization, not merely comparisons to the original unoptimized renderer.

Raw samples and logs: `deep-final-run-{1,2,3}.{json,log}`. `previous_ms` is the independent preserved renderer before this turn. `current_ms` is an ablation using shared paired gradients with coverage disabled. `optimized_ms` is the complete implementation. CPU submission samples are included separately; they exclude waiting for GPU completion. There is no consistent CPU submission improvement: the extra joined-mask pass increases encoding work. GPU savings are the principal steady-state result.

Configuration: frequency 1.7, amplitude 0.62, scale 0.8, contrast 1.2, brightness −0.08, speed 0.05, five opacity levels and a three-color palette. Intro disabled. Modes are Bayer8, radial, Noise and None, as defined in the benchmark source.

## Resource construction

The final initialization run measured 42.820 ms for the first preserved renderer, 1.692 ms for the first shared renderer, and 0.053 ms median for eight subsequent shared renderers. Nine new renderers referenced one gradient texture identity. Raw output: `deep-final-initialization.log`.

The first-constructor timings are sequential within one process, with the preserved renderer first, and are affected by Metal/driver caches. They are not an unbiased independent cold-process launch comparison. Warm reuse and the shared resource identity are the reliable architectural conclusions. No application launch speedup is claimed.

## Rejected experiments

- A flat fragment-shader specialization removed branches but increased GPU time about 15–27% in its trial; removed.
- A direct compute kernel calculated each flat cell and wrote its screen-pixel block without the fullscreen render pass. Dense cases became about 18–22% slower; coarse output was effectively unchanged. Removed. Raw trial samples: `compute-trial.json`.
- Full-resolution per-pixel neighbor lookups with an atlas helped, but the additional grid mask pass was faster for joins. Trial samples: `atlas-trial.json` and `mask-trial.json`.

## Verification and limits

- All 20 release tests passed without warnings. `deep-final-tests.log`.
- 144 fixed-time image cases compare the independent preserved renderer with paired gradients alone and the full new renderer. Six variants cover cells 1/2/4/6/13/32, eight dither modes, three shape configurations, palettes, plain colors, transparency, zero strength/amplitude, time/direction changes and both aligned/odd-sized viewports. Every compared BGRA byte matches.
- Another 17 image cases exercise more than eight coverage keys, eviction and reuse, changed palette/alpha/join state, changed dimensions, high-frequency small-scale noise and cells above the atlas limit. All compared bytes match.
- Existing tests cover premultiplied alpha, intro, static settling, unchanged-setting redraw suppression, cadence and pause/resume.
- Final release app built and signature verified. Relaunch diagnostics show both displays rendering without errors; see `deep-final-runtime.json`. Build log: `deep-final-build.log`.

GPU timestamps exclude WindowServer, presentation waiting, scanout and other applications. Atlas initialization/setting-change costs are excluded from warmed steady-state medians. Eight cached keys bound memory but do not make continuous setting scrubbing free. Image comparisons cover the tested inputs, not every possible floating-point boundary. No claim of maximal optimization, energy savings or battery improvement is made.

## Reproduce

```sh
set -o pipefail
export DEVELOPER_DIR='/Applications/Xcode 27.2 rc.app/Contents/Developer'
swift test -c release 2>&1 | xcsift -f toon -w
DESKTOP_GLOW_BENCHMARK=1 DESKTOP_GLOW_BENCHMARK_OUTPUT="$PWD/Research/deep-repeat.json" swift test -c release --filter measureFusedFieldAndCellPass 2>&1 | xcsift -f toon -w
DESKTOP_GLOW_BENCHMARK=1 swift test -c release --filter measureRendererInitializationAndSharedResources 2>&1 | xcsift -f toon -w
Scripts/build-app.sh
```

## Changed source files

- `Sources/DesktopGlow/Rendering/DitherMetalRenderer.swift`
- `Tests/DesktopGlowTests/PreviousDitherMetalRenderer.swift` (independent pre-change fixture)
- `Tests/DesktopGlowTests/DitherRenderingTests.swift`
- `Tests/DesktopGlowTests/RenderPerformanceTests.swift`

No commits or pushes; the source directory has no Git repository.

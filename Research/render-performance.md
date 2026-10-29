# Renderer efficiency investigation

Measured locally on 2026-10-29, Mac14,2, macOS 27.2 (26B123). Raw observations are in `render-performance.json`; the reproducible benchmark is `Tests/DesktopGlowTests/RenderPerformanceTests.swift`.

## Findings

The original view submitted 30 frames per second regardless of speed or `disableAnimation`. The shader still generated a procedural field, resolved cell colors, and composited the full display for an unchanged image. Wave speed only affected the sampled coordinates, so slowing motion did not reduce the computation per frame.

The Noise option is a dithering threshold mode. None selects a constant threshold. The underlying wave requires procedural noise in every mode; disabling that would change the effect itself. The shader already branched by mode. The optimization now also bypasses threshold evaluation at zero strength and stops FBM octaves after their amplitude reaches zero. Neither changes the mathematical output for valid settings.

## Implemented scheduling

- Default speed 0.05: 30 fps.
- Speed 0.01 at default detail: 6 fps.
- Moving output: 4–30 fps. Small scale, high frequency, and high contrast increase cadence conservatively.
- Intro: 30 fps until the reveal completes, followed immediately by the selected moving cadence or a stopped timer.
- Zero speed or disabled animation: no recurring draws after the intro. Configuration and size changes still redraw.
- Hidden or detached views stop drawing. Existing sleep, session, thermal, and power policies continue controlling activation.
- Resume seeds animation timing so a paused interval is excluded. Non-advancing redraws do not discard motion time. Drawable size is assigned only when it changes.

Lower cadence preserves spatial resolution and the wave's rate of travel, but changes temporal sampling. Dither transitions can look less smooth. This policy is a heuristic rather than a guarantee of imperceptible changes at every possible setting.

## Measurements

GPU benchmark: offscreen 3024 × 1964 BGRA target, four-device-pixel cells, default wave settings, intro disabled. Six speed/mode combinations interleaved over 100 cycles, with 20 warm-up cycles excluded. Each reported number is the median of 80 command-buffer GPU durations. Rendering is forced for each sample, including zero speed, to isolate cost per submitted frame.

The cleanest repeat measured:

| Speed | Noise GPU ms/frame | None GPU ms/frame |
| --- | ---: | ---: |
| 0.05 | 0.856 | 0.854 |
| 0.01 | 0.853 | 0.855 |
| 0 | 0.856 | 0.853 |

Other runs ranged around 1.2–1.7 ms/frame under different system GPU conditions. Noise versus None ranged from effectively identical to a modest difference; there is no stable large saving demonstrated by that switch. Lower speed does not materially reduce cost per frame. The main measured saving is fewer submitted frames.

A hosted live view, two seconds per speed with intro disabled, measured:

| Speed | Submitted frames | Observed fps |
| --- | ---: | ---: |
| 0.05 | 60 | 29.97 |
| 0.01 | 12 | 6.00 |
| 0 | 0 | 0 |

At 0.01 this is 80% fewer recurring frame submissions than the original 30 fps schedule. At zero it eliminates recurring rendering entirely after settling. This is not a claim of an 80% drop in Activity Monitor GPU percentage or power: WindowServer composition, other apps, GPU clocks, multiple displays, and preview windows affect system totals. The live cadence measurement uses a small view to isolate scheduling; GPU durations use the separate display-size offscreen target.

## Verification and limits

The release test suite passes all 16 tests with no warnings. Tests exercise Metal transparency, scheduling limits, actual static settling, intro completion, moving cadence after intro, configuration changes, and pause/resume. Opt-in measurements pass separately. The packaged app builds without warnings.

This is a targeted efficiency improvement, not proof of maximal optimization. Potential larger changes such as combining render passes, reusing work between displays, or replacing the full-resolution composite were not implemented because they need separate image-equivalence and GPU measurements. No system-wide energy or battery-life result is claimed.

# Cell-aware production blur

Measured on this Mac on 2026-10-29. The production square-cell renderer now filters
unique cell rows rather than repeatedly filtering identical pixel rows. It caches
Gaussian interval weights and the vertical blur profile. The four-pixel cell kernel
loads and quantizes each neighboring color once for all four horizontal pixel phases.
The final fragment evaluates only the contributing rows of the one or two active
blur levels. It retains full output resolution, procedural noise, cadence, palettes,
104-point strip, maximum sigma 5 points, and decay coefficient 3.

## Eligibility and output

The fast path requires square gapless cells, cell sizes 4 through 128 device pixels,
1x or 2x backing scale, dimensions divisible by the cell size, sufficient height for
the strip plus halo, and the fused field renderer. Rounded, gapped, joined rounded,
small, uneven, and other scale configurations retain the MPS path. The internal
`usesCellBlurFastPath: false` initializer selects the reference for comparisons.

The top strip is approximate relative to MPS: maximum observed channel difference
was 2/255. Pixels below it are byte-identical. Small-radius weights are recovered
from an offscreen MPS impulse once when resources are created; larger radii use
normalized discrete Gaussian interval sums. MPS itself approximates a Gaussian,
so this is not a claim of mathematical or universal byte equality. Existing
Gaussian-reference tolerance was preserved.

## Full renderer GPU measurements

3024 × 1968 BGRA8 offscreen output, scale 2, production blur enabled. Each row
compares identical scene/time/configuration, alternating old/new order. Every
invocation has 20 warmup and 80 measured frames per path per case. Three invocations
are retained. The table shows the median of the three per-run medians; ranges
include all three runs. Cell sizes are device pixels.

| Cell | Background | MPS ms/frame | Cell-aware ms/frame | Reduction range |
| ---: | --- | ---: | ---: | ---: |
| 4 | Opaque | 1.0045 | 0.8504 | 10.5–15.3% |
| 4 | Transparent | 1.0071 | 0.8434 | 16.0–16.3% |
| 8 | Opaque | 0.7575 | 0.5656 | 25.1–25.4% |
| 8 | Transparent | 0.7742 | 0.5680 | 26.0–27.2% |
| 16 | Opaque | 0.6773 | 0.4347 | 35.5–36.2% |
| 16 | Transparent | 0.6831 | 0.4341 | 35.5–37.2% |

Raw samples, CPU submission durations, operation counters, and first-frame CPU
costs are in `production-blur-cell-run-{1,2,3}.json` and matching logs. Joined
rounded controls use unchanged MPS code; their variations are noise, not gains.
Cases are measured in blocks, so clocks/load can change between configurations.
These are renderer command-buffer durations, excluding WindowServer, scanout,
live drawable acquisition and energy use. The running application was not replaced
or relaunched to obtain these measurements.

## Operations, memory and setup

A warmed eligible frame uses one explicit render pass and four compute dispatches
(fused field/cell plus three horizontal levels), with no recurring MPS Gaussian
encodes. The previous path uses two render passes, one compute dispatch, and three
MPS Gaussian encodes. MPS internal operations are unspecified. Weight recovery
adds one or two offscreen MPS operations on resource creation, excluded from the
warmed operation counters.

At the benchmark size, nominal blur texture/buffer payload is approximately
4.58 MB for cell 4, 2.33 MB for cell 8, and 1.20 MB for cell 16, versus 10.96 MB
of source/level textures for the MPS path. These exclude allocator padding, internal
MPS scratch memory and shared/field resources. Fallback resources may remain cached
if geometry changes, so these are active-path payloads, not process memory figures.

In run 3, the first dense opaque submission took 4.61 ms CPU for the new path versus
0.59 ms for MPS, including weight setup. Recreating resources for cells 8 and 16 took
about 0.45 and 0.39 ms respectively. Warm submission costs are recorded separately.
Shared pipeline compilation and executable startup precede those measurements.

## Verification

Twelve offscreen release tests pass with full LTO and zero compiler warnings.
The new differential covers 288 configurations: eight modes, two alpha modes,
three cell sizes, two backing scales and three fixed times, with palette and
single-color cases, nonblack backgrounds and fractional opacity levels. Maximum
observed difference was two channel levels in each time variant, with exact
below-strip equality. Additional tests cover cache recreation, changed height,
scale transitions, rounded and uneven fallback, and exact fallback equality.
Existing Gaussian, transparency, coverage-cache, sharp-renderer differential and
operation-counter tests also pass. No UI or preference tests were run in this pass.

The initial generic compute and unspecialized cell prototypes were rejected.
Review corrected strip scissoring, repeated alpha multiplication, sparse vertical
summation, unsupported benchmark dimensions and operation accounting before the
retained measurements. See `production-blur-compute-trial-20261029.md` for the
initial generic trial; its results do not describe this implementation.

Reproduce offscreen measurements:

```sh
set -o pipefail
DEVELOPER_DIR='/Applications/Xcode 27.2 rc.app/Contents/Developer' DESKTOP_GLOW_CELL_BLUR_BENCHMARK=1 swift test -c release --experimental-lto-mode full -debug-info-format none --filter measureProductionCellBlurFastPath 2>&1 | xcsift -f toon -w
```

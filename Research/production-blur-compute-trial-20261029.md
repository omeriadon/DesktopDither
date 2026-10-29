# Production blur compute trial

Date: 2026-10-29

## Scope

Offscreen Metal renderer only. The production MPS blur path was compared with two architectural candidates at 3024x1964, scale 2, cell 4:

- A two-dispatch separable compute blur with three horizontal levels and a fused vertical/interpolation pass.
- A square-cell fast path using exact discrete Gaussian interval sums over piecewise-constant cell pixels.

The legacy path remained available through an internal initializer switch during the trial.

## Results

The generic compute candidate was rejected. In a paired, order-alternated release benchmark after warmup:

- Legacy MPS path: median 1.21 ms.
- Generic compute path: median 4.31 ms.
- Legacy operation counts: 2 render passes, 1 compute dispatch, 3 Gaussian encodes.
- Generic compute operation counts: 2 render passes, 3 compute dispatches, 0 Gaussian encodes.

The square-cell interval candidate was also rejected. It produced top-strip differences up to 99 bytes against the legacy MPS reference in transparent square-cell cases. The existing Gaussian reference test remained within its 0.02 normalized bound, but the stronger paired differential requirement was not met.

## Verification

The candidate passed compilation and the existing offscreen Gaussian-reference test at scale 1 and 2. After removing the candidate, the unchanged production blur operation-counter test passed in release mode with full experimental LTO. No UI, window, preference, display, or app lifecycle operation was performed.

## Decision

Both initial candidates were discarded. The later corrected cell-row implementation is documented in `production-blur-cell-fastpath-20261029.md`. A future optimization needs MPS-compatible kernel recovery or a substantially more specialized geometry path before it can satisfy both performance and output-differential requirements.

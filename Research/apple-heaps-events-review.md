# Apple heaps and events review for variable top blur

## Conclusion

Apple’s sample is relevant as a resource-lifetime and synchronization pattern, not as a direct optimization recipe for the current top blur. The sample’s benefit comes from reusing heap-backed temporary storage whose lifetimes do not overlap, then explicitly ordering producer/consumer work with events or fences. The current top blur has three persistent Gaussian outputs—sigma 0.5, 2, and 5—sampled together by the final composition. Those outputs coexist until that composition completes, so blind aliasing would be invalid. A heap/event migration is justified only after proving non-overlap for a specific resource schedule and measuring allocation pressure or GPU memory; it is not implied by the number of MPS calls.

The bounded recommendation is to preserve the current persistent textures and single command-buffer/single-queue path while the noise/cell-grid and optional coverage/join generation move to compute. Consider heap aliasing only for a newly demonstrated non-overlapping temporary, with a tracked lifetime table and a correctness test. Consider events only if work is split across command buffers or queues, or if CPU submission can run ahead of a reused heap allocation. Neither condition is established by the current renderer evidence.

## Sources inspected

- Apple’s Markdown for [Implementing a multistage image filter using heaps and events](https://developer.apple.com/documentation/metal/implementing-a-multistage-image-filter-using-heaps-and-events.md), saved by the parent at `/tmp/apple-heaps-events.md`.
- Apple’s [heaps-and-fences companion documentation](https://developer.apple.com/documentation/metal/implementing-a-multistage-image-filter-using-heaps-and-fences).
- Apple’s [Memory heaps](https://developer.apple.com/documentation/metal/memory-heaps), [MTLEvent](https://developer.apple.com/documentation/metal/mtlevent), [MTLRenderCommandEncoder](https://developer.apple.com/documentation/metal/mtlrendercommandencoder), and [MTLComputeCommandEncoder](https://developer.apple.com/documentation/metal/mtlcomputecommandencoder) documentation.
- Apple’s [MPSImageGaussianBlur](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagegaussianblur) documentation.
- Apple’s [MTLPixelFormat](https://developer.apple.com/documentation/metal/mtlpixelformat) documentation and the archived [Metal resource objects and textures guide](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Mem-Obj/Mem-Obj.html).
- Apple’s [Correct gamma before applying image operations](https://developer.apple.com/documentation/accelerate/adjusting-the-brightness-and-contrast-of-an-image) guidance.
- Apple’s [Xcode build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference), specifically `LLVM_LTO`.
- Local implementation evidence in [DitherMetalRenderer.swift](../Sources/DesktopDither/Rendering/DitherMetalRenderer.swift), [top-blur.md](top-blur.md), and [DitherPreviewView.swift](../Sources/DesktopDither/Rendering/DitherPreviewView.swift).

The Apple documentation page identifies the sample as downloadable, but the direct Apple ZIP endpoints reachable from the page returned 404 during this review. No first-party Apple source archive was obtained. The source-level facts below therefore come from Apple’s published code excerpts in the Markdown page, not an independently downloaded project archive.

## What Apple’s sample actually does

### Filter graph and downsampling

Apple describes a graph with a downsample filter followed by a Gaussian blur filter. The downsample filter allocates a mipmapped texture from a scratch heap with shader-read and shader-write usage, copies the input into it with a blit encoder, and calls `generateMipmapsForTexture`. The documented code uses the input pixel format and dimensions for the heap texture. This is a full-image/mipmap workflow, not the current renderer’s three independently sized cropped outputs. ([Apple sample](https://developer.apple.com/documentation/metal/implementing-a-multistage-image-filter-using-heaps-and-events.md), “Manage dependencies between filters”)

The blur stage is described as a horizontal blur followed by a vertical blur for each mipmap level. The horizontal result goes to an `intermediaryTexture`; the vertical result goes to an output texture view. Apple explicitly states that the intermediary is unused after the iteration for that mipmap level. ([Apple sample](https://developer.apple.com/documentation/metal/implementing-a-multistage-image-filter-using-heaps-and-events.md), “Reuse memory and manage dependencies within a filter”)

The published sample excerpts do not expose the numerical kernel weights or the complete `AAPLBlur` shader source. The only authoritative kernel detail available here is that Apple’s separate `MPSImageGaussianBlur` API performs an approximate Gaussian convolution in both x and y directions; Apple says it is not mathematically exact and recommends `MPSImageConvolution` when an analytically clean Gaussian is required. ([MPSImageGaussianBlur](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagegaussianblur))

Therefore, the sample must not be treated as evidence that its blur kernel is identical to the current MPS kernels, or that its downsampling/mipmap schedule would improve a cropped top strip. The actual sample kernel weights remain unresolved because the first-party source archive was unavailable in this review.

### Temporary aliasing

The sample allocates `intermediaryTexture` from the dynamic heap for an iteration, encodes horizontal and vertical work, ends that compute encoder, and then calls `makeAliasable`. Apple explains that this marks the backing memory as reusable by subsequent allocations from the same dynamic heap. It signals the event after the blur work because reusing that memory creates a dependency between mipmap iterations. ([Apple sample](https://developer.apple.com/documentation/metal/implementing-a-multistage-image-filter-using-heaps-and-events.md), “Reuse memory and manage dependencies within a filter”)

This is safe only because the intermediary’s last use is complete before the next allocation may alias it. `makeAliasable` is not a permission to overwrite a resource that another encoded operation still reads. Apple’s heap documentation also says that heap resources require explicit fine-grained synchronization when the app creates and reuses memory, and that only heap resources with tracked hazard mode receive Metal’s heap hazard tracking. ([Heaps and fences](https://developer.apple.com/documentation/metal/implementing-a-multistage-image-filter-using-heaps-and-fences), “Optimize resource allocation and performance”; [Memory heaps](https://developer.apple.com/documentation/metal/memory-heaps))

### Event and fence lifetimes

The event wrapper owns both the `MTLEvent` object and a monotonically increasing signal counter. `wait` encodes a wait for the current counter; `signal` increments the counter and encodes the signal. Apple warns that pairing the wrong event object with the wrong counter can create synchronization errors. ([Apple sample](https://developer.apple.com/documentation/metal/implementing-a-multistage-image-filter-using-heaps-and-events.md), “Implement an event wrapper for synchronization routines”)

The sample waits at the start of the graph for the previous frame, signals after downsampling, waits before the blur consumes the downsample output, signals after each aliased intermediary is finished, waits before the next dependent iteration, waits before rendering to the drawable, and signals after the frame is presented. This is a frame-to-frame and stage-to-stage lifetime protocol, not a generic performance switch. ([Apple sample](https://developer.apple.com/documentation/metal/implementing-a-multistage-image-filter-using-heaps-and-events.md), “Manage dependencies between filters” and “Manage dependencies between frames”)

Apple contrasts events with fences: fences order work that has already begun before the fence point, while events can wait for work that begins later and can be placed outside encoder boundaries. Apple also describes event waits as command-buffer-level GPU scheduling and notes that they can coordinate command buffers on different queues. ([Apple sample](https://developer.apple.com/documentation/metal/implementing-a-multistage-image-filter-using-heaps-and-events.md), “Compare events with fences”; [MTLEvent](https://developer.apple.com/documentation/metal/mtlevent))

## Fit to the current variable top blur

### Current resource relationships

The local renderer defines three fixed Gaussian levels at sigma 0.5, 2, and 5 logical points, scales them for the display, and stores a cropped source plus three cropped `rgba16Float` level textures in persistent per-renderer `TopBlurResources`. The levels are recreated only when dimensions or scale change, and all three are bound by the final blur-composition draw. ([DitherMetalRenderer.swift](../Sources/DesktopDither/Rendering/DitherMetalRenderer.swift), `TopBlurResources` and `encodeTopBlur`)

The source is a cropped dither strip, not a capture of desktop windows or wallpaper. The source render encoder writes it, the MPS operations read it and write the three levels, and the final composition samples the source and all levels. The current design therefore has simultaneous live reads of every level at the final composition. ([top-blur.md](top-blur.md); [DitherMetalRenderer.swift](../Sources/DesktopDither/Rendering/DitherMetalRenderer.swift), `encodeTopBlur` and `encodeTopBlurComposite`)

The parent implementation is changing the noise/cell-grid and optional coverage/join generation from render to compute while retaining two explicit blur-related render passes: the strip source and final composition. That does not mean two total GPU stages. The compute work, MPS operations, and other render/compute encoders remain additional GPU stages. Apple defines a render encoder as one render pass and a compute encoder as one compute pass; the command buffer may contain multiple encoders/passes. ([MTLRenderCommandEncoder](https://developer.apple.com/documentation/metal/mtlrendercommandencoder); [MTLComputeCommandEncoder](https://developer.apple.com/documentation/metal/mtlcomputecommandencoder); local [DitherMetalRenderer.swift](../Sources/DesktopDither/Rendering/DitherMetalRenderer.swift))

The renderer creates one command buffer from one queue per render call and commits it after encoding. It does not currently use cross-queue synchronization. ([DitherMetalRenderer.swift](../Sources/DesktopDither/Rendering/DitherMetalRenderer.swift), command-queue creation and `render`)

### Why direct aliasing does not fit the three outputs

Aliasing one Gaussian level’s backing memory into another level would be incorrect while the final composition can sample both levels. The level outputs are not like Apple’s intermediary texture: Apple’s intermediary has a proven last use before the next allocation, while the current levels have a common later consumer. The same objection applies to aliasing the source with a level before all MPS reads and final-composition reads complete.

A possible future schedule could alias storage only if the algorithm changes so that a level is consumed, no longer sampled, and then released before the next level is produced. That would require changing the composition schedule, such as tiled/segmented composition or a sequential interpolation strategy, and would need a proof that no encoded command retains a later read. It is not a safe local substitution in the current all-levels-bound final pass.

Persistent textures also reduce the relevance of Apple’s allocation-cost argument. The current renderer pays allocation cost on resize/scale changes, not for every intermediate allocation in the middle of each frame. The sample’s heap advantage is strongest for repeated dynamic allocations and aliasing of temporaries; it does not establish a win for already-cached per-renderer textures. ([Heaps and fences](https://developer.apple.com/documentation/metal/implementing-a-multistage-image-filter-using-heaps-and-fences), “Optimize resource allocation and performance”; local [DitherMetalRenderer.swift](../Sources/DesktopDither/Rendering/DitherMetalRenderer.swift))

### Why events are not currently indicated

Within one command buffer on one queue, encoder order already expresses the intended producer/consumer sequence for the source, MPS levels, and final composition. Events would add explicit waits/signals without creating useful overlap. Apple’s sample needs events because it reuses dynamic heap memory across graph nodes and across frames, and because its event semantics can bridge command buffers/queues. The current renderer’s tracked resources are persistent and do not cross a queue boundary. This is an inference from the local command encoding plus Apple’s stated event use case, not a claim that events are universally slower.

Events become worth evaluating if the implementation introduces a ring of heap-backed frame resources, submits multiple command buffers before earlier ones finish, or moves independent work to another queue. In that case, the event counter must be owned and advanced as one lifetime protocol, with waits before every possible reuse and signals after the final GPU use—not merely after the encoder that writes a resource.

## Color and gamma audit

There is no dedicated gamma pass in the current design. Palette selection, contrast, and brightness are fused into the shader path; the final target and blur source are `bgra8Unorm`, while the MPS levels are `rgba16Float`. The local layer is tagged with an sRGB `CGColorSpace`, but the Metal pixel format is the non-sRGB `bgra8Unorm`, not `bgra8Unorm_sRGB`. ([DitherMetalRenderer.swift](../Sources/DesktopDither/Rendering/DitherMetalRenderer.swift); [DitherPreviewView.swift](../Sources/DesktopDither/Rendering/DitherPreviewView.swift))

Apple documents that an sRGB Metal texture converts sampled components to linear space and converts linear shader output back to sRGB when rendered to an sRGB color attachment. Apple’s `BGRA8Unorm` description does not include that conversion; the separate `BGRA8Unorm_sRGB` format does. ([MTLPixelFormat](https://developer.apple.com/documentation/metal/mtlpixelformat); [Metal resource objects and textures](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Mem-Obj/Mem-Obj.html))

Consequently, the current blur path operates on the stored numeric values in the `bgra8Unorm` source as provided to MPS, not on values that Metal has automatically linearized through an sRGB texture format. The `rgba16Float` intermediates preserve more precision, but they do not by themselves add an sRGB transfer-function pass. This is a color-space inference from the documented format behavior and the local formats.

Apple’s image-processing guidance says convolution and scaling generally produce better results in a linear response curve, recommending conversion from sRGB to linear before the operation and conversion back afterward. That is a correctness/design tradeoff, not evidence that adding two transfer-function passes will improve this stylized dither. A gamma-correct variant would need an explicit color-space policy for palette values, premultiplied alpha, MPS input/output, and the final layer; it should be compared against the current visual contract and measured separately. ([Adjusting brightness and contrast](https://developer.apple.com/documentation/accelerate/adjusting-the-brightness-and-contrast-of-an-image), “Correct gamma before applying image operations”)

The transparent wallpaper toggle changes shader alpha/output behavior and window compositing; it does not add app-side render passes. Any extra cost from compositing the transparent overlay belongs to the WindowServer/system composition path and requires system-level measurement, not inference from the Metal command buffer alone. The local UI and layer configuration show the toggle and non-opaque layer; they do not expose WindowServer timing. ([DitherOptionsView.swift](../Sources/DesktopDither/Settings/DitherOptionsView.swift); [DesktopContentView.swift](../Sources/DesktopDither/Rendering/DesktopContentView.swift); [DesktopOverlayWindow.swift](../Sources/DesktopDither/Desktop/DesktopOverlayWindow.swift))

## MPS encodes and actual GPU pass count

The renderer calls `MPSImageGaussianBlur.encode` once for each of the three persistent levels. That is an API-level kernel-encoding call, not a promise that the GPU executes exactly one hardware pass per call. Apple documents `MPSImageGaussianBlur` as a fast approximate Gaussian filter, but does not specify its internal decomposition, tiling, separability schedule, or hardware pass count. ([MPSImageGaussianBlur](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagegaussianblur))

Apple’s Metal command-structure documentation distinguishes app-encoded commands and encoders from the later GPU scheduling/execution stage. It says a compute encoder can contain multiple kernel commands in one compute pass, and that committing a command buffer schedules its encoded work asynchronously. Therefore, counting three `encode` calls cannot establish three GPU passes, nor can reducing that count guarantee lower GPU time. Use GPU counters/timeline inspection or controlled GPU timestamps for the actual device and driver. ([Setting up a command structure](https://developer.apple.com/documentation/metal/setting-up-a-command-structure); [Compute passes](https://developer.apple.com/documentation/metal/compute-passes); local [top-blur.md](top-blur.md))

The existing benchmark note correctly treats “three Gaussian encodes” as an API-level change and says MPS internal pass counts are implementation details. That distinction should remain in any optimization report. ([top-blur.md](top-blur.md), “Measured GPU cost”)

## Bounded implementation recommendations

1. Keep the three cached levels and the single final composition while the compute migration lands. Validate the current source/level/final ordering with GPU capture and image tests before changing allocation policy.

2. If memory pressure is a measured problem, prototype a heap only for resources with non-overlapping lifetimes: derive size/alignment from the exact descriptors, keep hazard tracking enabled unless a measured design proves otherwise, and record the last encoder/command-buffer use before every `makeAliasable` and reuse. Do not alias any of the three levels while the final pass samples all three.

3. Add an event only with a concrete dependency that crosses command-buffer or queue boundaries, or with a reused heap allocation that can be reached before the prior frame finishes. Use a wrapper that couples the event object and monotonic signal value, following Apple’s sample.

4. If blur quality is under review, compare the current stored-value blur with an explicitly linear-light variant. Treat this as a visual/color-management experiment, not a heap optimization. Preserve premultiplied-alpha behavior and test transparent output separately.

5. Measure MPS work with the Metal GPU timeline/counters on target hardware, and measure WindowServer/compositor impact separately when transparency is enabled. Do not use MPS encode count, app GPU timestamp alone, or Swift CPU optimization as a proxy for the whole-system result.

6. Treat full LTO as a Swift/Objective-C link optimization. Apple defines `LLVM_LTO` as optimization across executable-code file boundaries during linking. It can affect CPU-side submission, allocation, and setup overhead; it does not rewrite the already specified MSL blur mathematics or guarantee a different MPS implementation. Metal shader optimization is controlled by Metal’s shader/pipeline compilation path, which Apple documents separately. ([Xcode build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference), `LLVM_LTO`; [Minimizing the binary size of a shader library](https://developer.apple.com/documentation/metal/minimizing-the-binary-size-of-a-shader-library); [MTLRenderPipelineState](https://developer.apple.com/documentation/metal/mtlrenderpipelinestate))

## Unresolved factual uncertainty

- The first-party Apple ZIP/source archive for the events sample was not retrievable from the documented page during this review. The published Markdown exposes the allocation, downsample, horizontal/vertical blur, aliasing, and event calls, but not the sample’s numerical Gaussian weights or complete shader implementation.
- Apple’s public `MPSImageGaussianBlur` documentation does not specify internal hardware pass count, exact implementation, or whether a particular device/OS version fuses work. Those facts require device-specific capture/counters.
- No source inspected here quantifies the cost of WindowServer compositing for this overlay or proves that the transparent toggle changes system work by a particular amount.
- No evidence establishes that heap allocation would reduce memory or GPU time for the current persistent per-renderer textures. That remains a measurement question, not a consequence of Apple’s sample.

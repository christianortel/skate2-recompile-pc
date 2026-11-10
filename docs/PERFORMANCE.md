# Performance notes

This page records where frame time goes in Skate 2 PC, the runtime changes that address it, and how to measure a change. The figures were collected on one Windows PC with an NVIDIA GeForce RTX 4080 using the frame-time CSV (`--perf_log_csv`), Windows Performance Recorder CPU sampling with stacks, and RenderDoc frame captures. Other hardware has not been measured.

## Where the time goes

Skate 2's dense city views issue 5,000–9,000 draws per frame. Each guest draw is translated by the GPU command processor thread into Direct3D 12 commands, and that thread limits the frame rate in these views. The game's main thread spends most of its time in a spin-wait for the command processor rather than in game logic.

| Cost | Cause | Change |
| --- | --- | --- |
| ROV render target path | ROV performs blending and depth/stencil in pixel shaders; slow at 2× on the tested NVIDIA GPU | RTV profile, with the draw-extent fix below |
| CPU then GPU, not overlapped | A frame was submitted to the GPU only when complete, and the idle-clean synchronization then waited for all of it | `d3d12_submit_draw_interval` |
| Driver command-list replay on the command processor thread | `DeferredCommandList::Execute` plus `ExecuteCommandLists`, about 22% of the thread | `d3d12_async_submission` |
| Per-register and per-texture overhead | Register-table lookup on every register write, guest texture layout recomputed on every scaled-resolve check, locks and atomic counters in per-draw paths | `command-processor-overhead` patch |
| New-texture hitches | Every texture was a separate committed resource; areas loading 400–600 new textures in one frame stalled for 150–190 ms | `d3d12_texture_placed_resources` |
| Occlusion query stalls | Each query end submitted and waited for the GPU before writing the result | `d3d12_async_occlusion_queries` |
| Host presents at monitor refresh rate | The always-registered achievement toast requested a continuous UI repaint, so the presenter presented repeated frames at the monitor refresh rate | `idle-ui-repaint` patch |

## RTV black screen while bailing

With `render_target_path_d3d12=rtv`, the bail camera displayed a black screen. A RenderDoc capture of the bail frame showed the final 1280×720 resolve reading the depth render target at EDRAM tile 720 instead of the color target at tile 0. Unclipped full-screen passes used in the bail effect had their EDRAM extent estimated as the whole EDRAM. The depth target therefore wrapped around and took ownership of the color target's range before the resolve.

The draw-extent estimate executes the vertex shader of such draws on the CPU only when `execute_unclipped_draw_vs_on_cpu` is enabled for the host render target path. ReXGlue defaults it to false, while the Xenia source it is derived from documents true. `rexglue-0.10.0-unclipped-draw-extent.patch` restores true. The ROV path is unaffected because it uses `execute_unclipped_draw_vs_on_cpu_for_psi_render_backend`.

## Runtime settings

| Setting | Default | Effect |
| --- | --- | --- |
| `execute_unclipped_draw_vs_on_cpu` | true (was false) | Correct EDRAM extents for unclipped draws on the RTV path |
| `d3d12_submit_draw_interval` | 0 | Submit recorded work every N draws within a frame so the GPU starts while the frame is still being translated; 1024 measured best |
| `d3d12_async_submission` | false | Replay and execute submissions on a separate thread; frame-ending submissions still complete before the presenter is notified |
| `d3d12_texture_placed_resources` | true | Place textures up to 16 MB in shared 64 MB heaps; textures are only destroyed after their last GPU use, so ranges are reused immediately |
| `d3d12_async_occlusion_queries` | true | Leave the guest's pending markers in place and write query results when the GPU has completed them; pending results are delivered before the command processor waits for the guest |

`Launch Skate 2 - RTV Performance.cmd` selects RTV, 2×, unlimited frame rate, a submit interval of 1024 and the submission thread. The default launchers are unchanged and keep the ROV path. The RTV profile requires a runtime built with these patches; older runtimes reject the new settings.

## Measurements

Average frame rate of frames grouped by draw calls per frame, RTV unless stated, 2× rendering. Each row is a separate play session through dense areas, so the routes differ; compare the draw-call groups rather than overall averages.

| Configuration | 5k draws | 7k draws | 99th percentile frame time |
| --- | --- | --- | --- |
| ROV, 60 FPS mode | 33 FPS | 22 FPS | 51 ms |
| RTV with draw-extent fix, 60 FPS mode | 54 FPS | 30 FPS | — |
| RTV, unlimited | 70 FPS | 51 FPS | 21 ms |
| + command processor overhead patch¹ | 81 FPS | 58 FPS | — |
| + submit interval 1024 | 91 FPS | 69 FPS | 15.6 ms |
| + submission thread | 99 FPS | 78 FPS | 13.3 ms |

¹ Measured during a CPU profiling session and grouped by one-second windows rather than by individual frames.

Command processor CPU time per draw fell from about 2.5–2.7 µs to about 1.9 µs with the overhead patch. In 60 FPS mode, frames that miss the 16.7 ms guest refresh wait for the next one, so moderate overruns appear as a drop to 30 FPS; unlimited mode does not quantize frame times this way.

New-texture bursts with placed textures:

| Textures created in one frame | Committed resources | Placed resources |
| --- | --- | --- |
| ~430 | 155 ms | 15–21 ms |
| ~600 | 189 ms | 44 ms |

Submit intervals of 256, 512 and 1024 were compared; 1024 was fastest and showed no visual problems. Disabling idle-clean synchronization entirely is faster still but produced visible corruption, so it remains enabled.

## Not yet verified

- Lens-flare visibility with asynchronous occlusion queries has not been checked against the original behavior.
- One isolated 159 ms frame with few new textures remains unexplained.
- AMD and Intel GPUs, other NVIDIA GPUs, and lower-core-count CPUs have not been measured. ROV remains the default for this reason.

## Measuring a change

Pass `--perf_log_csv=<path>` (or `-PerformanceCapture` to `scripts/Launch-Skate2.ps1`) and compare frames grouped by `draw_calls` between runs over the same route. For CPU attribution, record with `wpr -start CPU -filemode` / `wpr -stop trace.etl` while the game runs, using a runtime built with debug information.

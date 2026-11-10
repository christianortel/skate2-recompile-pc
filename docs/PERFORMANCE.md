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

The game-side frame limiter, `skate2_frame_limit` (`off`, `auto` or a rate from 20 to 1000), paces each guest swap on an absolute schedule: deadlines advance by exactly one frame interval, the thread sleeps on a high-resolution waitable timer and spins for the final millisecond, and a frame more than one interval late restarts the schedule instead of rushing to catch up. `auto` targets the refresh rate of the window's monitor minus 3 frames or 3%, whichever is larger. See [Display and performance](DISPLAY.md#frame-limiter).

On NVIDIA GPUs, `skate2_nvidia_max_performance=on` sets the driver's Power management mode to Prefer maximum performance for `skate2.exe`, which can help because the CPU-side command processor limits the frame rate in dense views, leaving the GPU partly idle so the driver may drop it to lower clocks; see [NVIDIA power management](DISPLAY.md#nvidia-power-management).

`skate2_draw_distance_scale` and `skate2_lod_distance_scale` (0.5 to 8, default 1) push out the distance at which world objects stop being drawn and the distances at which characters and vehicles switch to lower-detail models. Values above 1 cost CPU and GPU time: a longer draw distance adds draws, which the command processor thread must translate in the dense views that already limit the frame rate, and detailed models add GPU work. Other passes, such as shadows, probably draw more too. The cost has not been measured; see [Draw distance and detail](DISPLAY.md#draw-distance-and-detail).

`Launch Skate 2 - RTV Performance.cmd` selects RTV, 2×, unlimited frame rate, a submit interval of 1024 and the submission thread. The default launchers pass no render path: they use the one saved from the settings panel or F4, or ROV when none is saved. The RTV profile requires a runtime built with these patches; older runtimes reject the new settings.

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
- The frame limiter's effect on frame-time consistency has not been measured in gameplay yet.
- The effect of `skate2_nvidia_max_performance` on frame rate and frame times has not been measured.
- Draw-distance and LOD-distance scaling have only been checked on the front end. Their in-game visuals and performance cost have not been checked.
- The GPU trace recorder has not made an in-game capture yet, and no trace has been replayed or opened in Xenia's tools.
- The settings panel's controller shortcut and controller navigation, the Steam Deck preset on a Deck, and saving from the panel have not been tested.
- One isolated 159 ms frame with few new textures remains unexplained.
- AMD and Intel GPUs, other NVIDIA GPUs, and lower-core-count CPUs have not been measured. ROV remains the default for this reason.

## GPU trace capture

The runtime can record the GPU commands of one or more frames, together with the guest memory they use, to a trace file for offline analysis.

Press **F9** in game to record the next frame. The key can be changed as `bind_gpu_trace` in the **Input/Keybinds/System** section of the F4 settings. The trace is written to `logs\gpu_traces\<TITLEID>_<YYYYMMDD-HHMMSS>_frame<N>.xtr` beside `skate2.exe`, where `<N>` is the number of the first recorded frame since startup. The log shows `GPU trace: capture requested`, then `GPU trace: recording 1 frame(s) to <path>` and, once the capture is complete, `GPU trace: wrote <frames> frame(s), <size> MB, to <path>`.

The settings are in the **GPU/Trace** section of the F4 settings, or can be given as `--name=value` options on the `skate2.exe` command line; the launchers do not pass them.

| Setting | Default | Effect |
| --- | --- | --- |
| `trace_gpu_frame_count` | 1 | Frames recorded per capture, from 1 to 1000 |
| `trace_gpu_capture_at_frame` | 0 (off) | Start a capture automatically after this many guest frames since startup. If saved to the config, it triggers on every launch |
| `trace_gpu_stream` | false | Record everything from startup until exit into one `..._stream.xtr` file; takes effect after a restart |
| `trace_gpu_prefix` | empty | Output folder; empty uses `logs\gpu_traces` beside the executable |

- The recorded frames run slowly, and the game stalls briefly when a capture starts.
- Files are large: about 10 MB of EDRAM contents, plus the memory written by the GPU and all data read during the recorded frames.
- For complete traces, use render scale 1. With resolution scaling the EDRAM snapshot is skipped, and render-to-texture data in the trace may be stale.
- Complete traces require the Direct3D 12 backend.
- The files use upstream Xenia's trace format, version 1, so Xenia's trace viewer and trace dump tools built from Xenia source should open them. This has not been tested.
- No replay tool is included.

## Measuring a change

Pass `--perf_log_csv=<path>` (or `-PerformanceCapture` to `scripts/Launch-Skate2.ps1`) and compare frames grouped by `draw_calls` between runs over the same route. For CPU attribution, record with `wpr -start CPU -filemode` / `wpr -stop trace.etl` while the game runs, using a runtime built with debug information.

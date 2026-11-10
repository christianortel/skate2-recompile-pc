# Display and performance

Use **Launch Skate 2.exe** in the player-package root for the default profile. The CMD launchers remain available for the same default and alternate profiles. A source checkout gains the native launcher after building; its CMD launchers also work. Close the game before changing profiles.

## Launch profiles

| Launcher | Rendering quality | Frame-rate mode |
| --- | --- | --- |
| **Launch Skate 2.exe** | Saved; 2x if none saved | Saved; unlimited if none saved. Default profile |
| **Launch Skate 2.cmd** | Saved; 2x if none saved | Saved; unlimited if none saved. Same default through CMD |
| **Launch Skate 2 - 1x Performance.cmd** | 1× | Unlimited; lower GPU load |
| **Launch Skate 2 - 4x Quality.cmd** | 4× | Unlimited; experimental |
| **Launch Skate 2 - 60 FPS.cmd** | Saved; 2x if none saved | Paced 60 FPS target |
| **Launch Skate 2 - RTV Performance.cmd** | 2× | Unlimited; RTV path with mid-frame and threaded submission. See [Performance notes](PERFORMANCE.md) |

**Launch Skate 2 - 2x Quality.cmd** and **Launch Skate 2 - Unlocked FPS.cmd** start the same default profile as the default launcher, so they also use your saved settings. The default launchers pass no frame-rate mode, render scale or render path: the values saved in `skate2.toml` from the [settings panel](#in-game-settings-panel) or F4 apply, and without saved values the game uses its default profile of unlimited frame rate, 2x rendering and the ROV render path. The other profiles set the values shown above at every start; only the RTV profile sets the render path, so the others use the saved one, or ROV.

All supplied profiles enable synchronous shader compilation and GPU idle-clean synchronization. Opening `skate2.exe` directly uses the same default profile, including these synchronization settings, and the same saved settings. It skips the launcher's checks for the game files and the Visual C++ runtime.

Earlier versions of the default launchers always passed unlimited, 2x and ROV, which overrode saved values. Settings saved before, for example a frame-rate mode, render scale or render path saved from F4, now take effect. If the game starts with different settings than before, check them in the settings panel (F1).

The native EXE runs the existing PowerShell startup logic. v0.1.1 changes the entrypoint and packaging while preserving the v0.1.0 game/runtime binaries and graphics fixes.

Actual frame rate depends on hardware and workload. If performance or visuals regress, restart with the 1× Performance launcher. [Performance notes](PERFORMANCE.md) describe the RTV profile, the related runtime settings, and measurements. Leave the runtime's **VSync** setting enabled: it also controls guest timing.

## In-game settings panel

Press **F1**, or hold **Back + Start** on an Xbox-compatible controller for about a second, to open the Skate 2 settings panel while the game runs. Press F1 or hold Back + Start again to close it. [Installation and controls](INSTALL.md#settings-and-controls) describes navigation and which controllers work. The key can be changed as `bind_skate2_settings` in the **Input/Keybinds/System** section of the F4 settings.

The panel collects the frame-rate, rendering, display, NVIDIA and world-detail settings described on this page, plus four presets. The bottom of the panel describes the selected entry. F4 still lists every runtime setting.

| Section | Entry | Setting | Applies |
| --- | --- | --- | --- |
| Frame rate | Frame-rate mode | `skate2_frame_rate` | After restart |
| Frame rate | Frame limiter | `skate2_frame_limit` | Live |
| Rendering | Render scale | `draw_resolution_scale_x`, `draw_resolution_scale_y` | After restart |
| Rendering | Render path | `render_target_path_d3d12` | After restart |
| Rendering | GPU submit interval | `d3d12_submit_draw_interval` | Live |
| Rendering | Submission thread | `d3d12_async_submission` | After restart |
| Display | VSync | `vsync` | Live |
| Display | Fullscreen | `fullscreen` | Live |
| Driver | NVIDIA max performance | `skate2_nvidia_max_performance` | After restart |
| World detail | Draw distance | `skate2_draw_distance_scale` | Live |
| World detail | LOD distance | `skate2_lod_distance_scale` | Live |

**Live** settings change immediately. The others show **After restart**, which becomes **Restart needed** once you change them; the bottom of the panel lists them until the game restarts. **Save to skate2.toml** writes the settings to the same file as **Save to config** in F4, and the default launchers start with the saved values. Unsaved changes last until the game closes.

- The frame limiter offers Off, Auto and common rates. **Custom limit** below it accepts any rate from 20 to 1000 FPS.
- Render scale offers 1x to 4x; 3x and 4x are experimental.
- VSync cannot be turned off while a frame-rate mode other than Original is active. The panel reports the change as rejected.
- Draw distance and LOD distance are sliders. A new value applies when you finish adjusting the slider; **Reset** returns it to 1.00x.

### Presets

| Preset | Frame rate | Scale | Render path | Submit interval | Submission thread |
| --- | --- | --- | --- | --- | --- |
| Quality | Unlimited | 2x | ROV | 0 | Off |
| Balanced | Unlimited | 2x | RTV | 1024 | On |
| Performance | Unlimited | 1x | RTV | 1024 | On |
| Steam Deck | 60 | 1x | RTV | 1024 | On |

A preset sets only these five settings. It leaves the frame limiter, display, NVIDIA and world-detail settings unchanged. The preset that matches the current settings is marked `*`. The submit interval changes immediately; the other four apply at the next start, unless a launch shortcut sets them (see below). Quality matches the default profile, which **Launch Skate 2.exe** uses when nothing is saved, and Balanced matches **Launch Skate 2 - RTV Performance.cmd**. The Steam Deck preset has not been tested on a Steam Deck.

### Launch shortcuts and saved settings

The default launchers, **Launch Skate 2.exe** without options, **Launch Skate 2.cmd**, **Launch Skate 2 - 2x Quality.cmd** and **Launch Skate 2 - Unlocked FPS.cmd**, pass none of the panel's settings. Values saved in `skate2.toml` therefore apply at the next start. A setting without a saved value uses the default profile: unlimited frame rate, 2x render scale and ROV. Saving leaves out values that equal the default profile and keeps any other choice, such as 1x or Original.

The other launch profiles, and [launch options](#advanced-launch-options) given to the native launcher or the PowerShell script, pass their own values at startup. These take precedence over values saved in `skate2.toml`, and the panel marks them **(L)**. The shortcut sets its own value again at every start, so a saved change to an **(L)** setting does not carry over when you start the game with the same shortcut. For a setting that applies after a restart, such as the render scale, the change then has no effect with that shortcut.

Saving writes the values in effect, including **(L)** values. For example, after starting with **Launch Skate 2 - 1x Performance.cmd**, saving also saves 1x, and the default launchers then start with it. Settings saved earlier from F4, which the default launchers used to override, now take effect as well; see [Launch profiles](#launch-profiles).

To keep the Performance or Steam Deck preset, select it in the panel, save, and restart with a default launcher. No supplied launcher sets these presets; the PowerShell script can for a single start:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Launch-Skate2.ps1 -FrameRate unlimited -RenderScale 1 -RenderTargetPath rtv -SubmitDrawInterval 1024 -AsyncSubmission
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Launch-Skate2.ps1 -FrameRate 60 -RenderScale 1 -RenderTargetPath rtv -SubmitDrawInterval 1024 -AsyncSubmission
```

## Performance troubleshooting

For a laptop or handheld, connect power and select an appropriate **Performance** or **Turbo** mode in the device's power controls. A reported slowdown on the tested laptop was traced to **Silent/low-power mode**. Available modes vary by device; this does not establish performance on ROG Ally or other untested hardware.

If it still feels slow, try **Launch Skate 2 - 1x Performance.cmd** and compare the same location. An FPS overlay can count presented frames without describing how regularly the game updates, so include visible stutter, game speed, power mode, and the selected launch profile in performance reports. A high overlay number alone does not confirm smooth gameplay.

## Rendering quality and 4K displays

Rendering scale increases internal resolution in both axes. It does not change the camera's aspect ratio. The default is 2×; 3× and 4× remain experimental.

The inspected main game target is 1152×640. Its scaled sizes are:

| Scale | Main target size |
| --- | --- |
| 1× | 1152×640 |
| 2× | 2304×1280 |
| 3× | 3456×1920 |
| 4× | 4608×2560 |

Other rendering passes can use different sizes. These are internal target dimensions, not selectable monitor resolutions. Fullscreen uses the desktop display mode; 4K output and higher scales still need broader testing. Increasing both axes can substantially increase GPU load and memory use.

## Advanced launch options

The native launcher accepts optional arguments for game-library entries. For example, set the entry's arguments to `--render-scale 1` for lower GPU load, or `--frame-rate 120 --render-scale 2` for a paced target. In PowerShell:

```powershell
& '.\Launch Skate 2.exe' --render-scale 1
```

Without arguments it passes no frame-rate mode or render scale, so the saved values apply, or unlimited and 2x when none are saved. An option sets only its own setting: `--render-scale 1` leaves the frame-rate mode to the saved value. Keep the EXE path and arguments in separate fields if your game library provides them.

Open Windows PowerShell in the repository or player-package folder. For a custom target and quality:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Launch-Skate2.ps1 -FrameRate 120 -RenderScale 2
```

Frame-rate choices are `original`, `60`, `120`, `144`, `165`, `200`, `240`, and `unlimited`. Rendering scales are `1`, `2`, `3`, and `4`. These frame modes are experimental; the number is a target, not a performance guarantee.

Explicit launcher options take precedence over saved settings for that start. When calling the PowerShell script directly, omitting `-FrameRate`, `-RenderScale` or `-RenderTargetPath` (`rov` or `rtv`) uses the saved value, or the default profile when none exists: unlimited, 2x and ROV. Restart to apply a new profile.

## Frame limiter

In unlimited mode the game finishes frames at uneven intervals, which shows as judder even at a high average frame rate. The frame limiter (`skate2_frame_limit`) holds each frame to an even, fixed schedule instead. It only ever slows the game down to the target; it cannot raise the frame rate.

| Value | Use |
| --- | --- |
| `off` | Default; no limiter |
| `auto` | A few frames below the refresh rate of the monitor showing the game. For G-Sync and FreeSync displays |
| `20` to `1000` | A fixed target, for example your display's refresh rate on a fixed-refresh display |

Combine it with the unlimited frame-rate mode:

```powershell
& '.\Launch Skate 2.exe' --frame-limit auto
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Launch-Skate2.ps1 -FrameRate unlimited -FrameLimit 60
```

A changed value applies immediately, without a restart. The limiter is also available in the [in-game settings panel](#in-game-settings-panel).

## NVIDIA power management

In dense areas the frame rate is limited by the CPU, so the GPU is partly idle and the NVIDIA driver may lower its clocks. The `skate2_nvidia_max_performance` option sets **Power management mode** to **Prefer maximum performance** in the NVIDIA driver profile for `skate2.exe`, which keeps the GPU at full clocks while the game runs. It is off by default; driver settings are only changed when you select it. It is also available in the [in-game settings panel](#in-game-settings-panel), where a change applies at the next start.

| Value | Effect |
| --- | --- |
| `off` | Default; driver settings are not changed |
| `on` | Sets Prefer maximum performance in the driver profile that lists `skate2.exe`, or in a new profile named "Skate 2 PC" if none does |
| `restore` | Removes that setting again, if it is still Prefer maximum performance |

```powershell
& '.\Launch Skate 2.exe' --nvidia-max-performance on
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Launch-Skate2.ps1 -NvidiaMaxPerformance on
```

The option is applied when the game starts. The driver keeps the change after the game closes, including for later launches without the option, until you launch once with `restore` or reset it in the NVIDIA Control Panel: **Manage 3D settings** > **Program Settings** > `skate2.exe` > **Power management mode** > **Use global setting**. If the global Power management mode is already Prefer maximum performance, `on` makes no difference.

On some PCs, changing driver settings requires administrator rights. The log in the `logs` folder beside `skate2.exe` then reports this, and the setting is not changed; set Power management mode in the NVIDIA Control Panel instead. The option has no effect on AMD or Intel GPUs or on Steam Deck.

## Draw distance and detail

Two settings control how much detail the game shows at a distance. Both are multipliers of the original console distances.

| Setting | Launcher option | Effect |
| --- | --- | --- |
| `skate2_draw_distance_scale` | `--draw-distance` | How far away world objects are still drawn. Small objects such as street furniture and building detail normally disappear at about 120 m; larger objects stay visible further, depending on their size. A value of 2 doubles both distances |
| `skate2_lod_distance_scale` | `--lod-distance` | How far away character and vehicle models keep full detail before switching to lower-detail versions. Characters normally switch to lower-detail models between about 15 and 25 m, vehicles between about 65 and 85 m. A value of 2 doubles these distances |

| Value | Effect |
| --- | --- |
| `1` | Default; the original distances |
| `0.5` to below `1` | Shorter distances: less detail, less work per frame |
| Above `1` to `8` | Longer distances, for example `2` for twice the original: more detail, more work per frame |

Values can have up to three decimals. Use a dot as the decimal separator, for example `1.5`, also on systems that normally use a comma.

```powershell
& '.\Launch Skate 2.exe' --draw-distance 2 --lod-distance 2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Launch-Skate2.ps1 -DrawDistanceScale 2 -LodDistanceScale 2
```

A changed value applies on the next frame, without a restart. Both settings are also available in the [in-game settings panel](#in-game-settings-panel).

These settings only change what is drawn from the part of the city the game has already loaded. They do not load more of the world: distant areas still appear in their simplified form and switch to full detail at the same points as before, so very high values may add little. Neither setting changes where the game places pedestrians and props around you as you skate; that is controlled separately.

Higher values cost CPU and GPU time, because more objects and more detailed models are drawn each frame. Other rendering passes, such as shadows, probably draw more as well. The cost has not been measured yet, and the settings have only been checked in the menus so far. If the frame rate drops, lower the values or return to `1`.

## Monitors and windowed mode

To select display 2, or run in a window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Launch-Skate2.ps1 -Monitor 2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Launch-Skate2.ps1 -Windowed
```

Both use the saved frame-rate mode, render scale and render path, or the default profile.

Monitor `0` is automatic. Positive indices follow the runtime's display enumeration. Fullscreen normally uses borderless desktop mode. Multiple-monitor behavior is still being tested.

## Ultrawide

True **21:9 and 32:9 support is not available yet**. Keep the original 16:9 aspect with side bars. On a 3840×1080 display, that gives a centered 1920×1080 image.

Stretching to fill an ultrawide panel does not widen the camera view and distorts proportions. Proper support requires changes to the camera, HUD, menus, replay, cutscenes, and effects; this work is on the [roadmap](KNOWN_ISSUES.md#planned-work).

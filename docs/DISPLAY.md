# Display and performance

Use the CMD launchers in the repository or player-package root to choose a profile. Close the game before changing profiles.

## Launch profiles

| Launcher | Rendering quality | Frame-rate mode |
| --- | --- | --- |
| **Launch Skate 2.cmd** | 2× | Unlimited; default profile |
| **Launch Skate 2 - 1x Performance.cmd** | 1× | Unlimited; lower GPU load |
| **Launch Skate 2 - 4x Quality.cmd** | 4× | Unlimited; experimental |
| **Launch Skate 2 - 60 FPS.cmd** | Saved/default quality | Paced 60 FPS target |

**Launch Skate 2 - 2x Quality.cmd** and **Launch Skate 2 - Unlocked FPS.cmd** select the same profile as the default launcher. All supplied profiles enable synchronous shader compilation and GPU idle-clean synchronization. Directly opening `skate2.exe` does not apply a launcher profile.

Actual frame rate depends on hardware and workload. If performance or visuals regress, restart with the 1× Performance launcher. Leave the runtime's **VSync** setting enabled: it also controls guest timing.

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

Open Windows PowerShell in the repository or player-package folder. For a custom target and quality:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Launch-Skate2.ps1 -FrameRate 120 -RenderScale 2
```

Frame-rate choices are `original`, `60`, `120`, `144`, `165`, `200`, `240`, and `unlimited`. Rendering scales are `1`, `2`, `3`, and `4`. These frame modes are experimental; the number is a target, not a performance guarantee.

Explicit launcher options take precedence over saved F4 settings. Omitting `-FrameRate` or `-RenderScale` uses the saved value, or the application default when none exists. Restart to apply a new profile.

## Monitors and windowed mode

To select display 2, or run in a window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Launch-Skate2.ps1 -FrameRate unlimited -RenderScale 2 -Monitor 2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Launch-Skate2.ps1 -FrameRate unlimited -RenderScale 2 -Windowed
```

Monitor `0` is automatic. Positive indices follow the runtime's display enumeration. Fullscreen normally uses borderless desktop mode. Multiple-monitor behavior is still being tested.

## Ultrawide

True **21:9 and 32:9 support is not available yet**. Keep the original 16:9 aspect with side bars. On a 3840×1080 display, that gives a centered 1920×1080 image.

Stretching to fill an ultrawide panel does not widen the camera view and distorts proportions. Proper support requires changes to the camera, HUD, menus, replay, cutscenes, and effects; this work is on the [roadmap](KNOWN_ISSUES.md#planned-work).

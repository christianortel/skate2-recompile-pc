# Installation and controls

## Availability

There is no public release download yet. The source export is for developers; see [BUILD.md](BUILD.md). A local staged package is a release candidate, not proof of installation on a clean PC.

## Intended player setup

1. Extract the eventual Windows x64 player package into a writable folder.
2. Double-click **Import Game Files.cmd**. Select your own extracted Xbox 360 Skate 2 folder containing `default.xex` and `data`. ISO/archive extraction is not implemented by the importer.
3. Wait for the copy and hash checks to finish. The source is preserved; an existing `game` folder is never overwritten. Ensure there is enough space for another full copy of the extracted game.
4. Connect your controller and open **Launch Skate 2.cmd**. A black startup delay can occur. If it fails, preserve the error and check `logs` beside the executable.

The CMD launchers use Windows PowerShell 5.1 with its native module defaults and an execution-policy setting limited to that child process. This also supports launching them from PowerShell 7. They do not change your parent shell, user, or machine settings. Organization-enforced script restrictions still apply; report a policy error rather than changing those settings.

The supported executable has Title ID `4541087F`, Media ID `6ADB5821`, version `0.0.0.2`, and SHA-256:

```text
116ba3ee37fcf0d8db60b7d47c971fdb6d3eb2a7a4d3cfc3611a06704a588ae5
```

Other revisions are refused because the port uses revision-specific addresses. The importer verifies this executable and verifies copied files against the selected source; it does not prove the authenticity or completeness of every asset. No game-file downloads are provided.

## Playing

The normal launcher and Unlocked FPS launcher use the latest confirmed profile: **2x quality, unlimited presentation, synchronous shader compilation, and GPU idle-clean synchronization**. The 1x Performance launcher restores original rendering quality with the same timing fix. The 60 FPS launcher is a paced alternative; actual performance may be lower. To select another target from PowerShell:

```powershell
.\scripts\Launch-Skate2.ps1 -FrameRate 120
```

Targets: `original`, `60`, `120`, `144`, `165`, `200`, `240`, `unlimited`. The root launchers explicitly choose their mode, which overrides a saved F4 frame-rate selection. Calling the PowerShell script without `-FrameRate` honors the saved mode or the application's original default. Keep guest VSync enabled for the optional frame modes.

F4 opens settings. Under Audio, select your speakers or preferred device, save, and restart if a controller has become Windows' default audio output. Do not copy another user's configuration file. A USB DualSense was tested directly with DS4Windows closed; complete mappings, reconnects, wireless input, and Xbox hardware still need broader testing.

Saves are stored in `userdata`; keep that entire folder when updating, including its headers. Configuration is in `skate2.toml`, and cache data is in `cache`. In a development checkout these live under `skate2`. The user confirmed the existing skater and progress survived a full exit/relaunch in the development build. New packages start with a separate `userdata` folder; an empty career there does not mean the development save was erased. Broader save coverage and interrupted-save recovery remain unverified.

For display selection and sharper rendering, see [DISPLAY.md](DISPLAY.md). If a higher quality mode fails, restart with `scripts/Launch-Skate2.ps1 -FrameRate unlimited -RenderScale 1`.

## Requirements and limits

The current target is Windows x64 with Direct3D 12. Minimum GPU, driver, RAM, Windows version, and performance requirements have not been established across machines. Linux/macOS and portable clean-PC installation are not validated. See [KNOWN_ISSUES.md](KNOWN_ISSUES.md).

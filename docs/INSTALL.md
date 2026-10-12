# Installation and controls

Download **Skate2-PC-v0.1.1-Windows-x64.zip** from [Releases](https://github.com/christianortel/skate2-recompile-pc/releases/latest). It contains the compiled game application, runtime, and native **Launch Skate 2.exe** entrypoint. The CMD launchers remain included. You do not need to compile anything to play. [Build from source](BUILD.md) is a separate guide for contributors.

## What you need

| Item | Requirement |
| --- | --- |
| Operating system | Windows 10/11 x64; Linux, macOS, and Windows on ARM are not supported by this build |
| Processor | Intel/AMD processor supporting x86-64-v2, the SDK's build target |
| Graphics | Direct3D 12 GPU and driver; minimum GPU/VRAM requirements have not been established |
| Input | A controller; USB DualSense has direct input support without DS4Windows |
| Game data | Your own extracted copy matching the executable below |
| Storage | Space for a second copy of the extracted game, about 6.8 GB for the supported file set, plus saves and cache |
| Launcher | Windows PowerShell 5.1, included with Windows 10/11; the native EXE delegates to the supplied startup script |

The launcher checks for **Microsoft Visual C++ x64 v14 Runtime 14.44.35211.0 or later**. If it is missing or outdated, open the included **Install Visual C++ Runtime.url** or use [Microsoft's x64 installer](https://aka.ms/vc14/vc_redist.x64.exe), complete installation, and launch again. This is a runtime prerequisite, not a compiler. [Microsoft's runtime information](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170) explains supported versions. See [compatibility limits](KNOWN_ISSUES.md) for hardware coverage.

## Supported game version

| Field | Value |
| --- | --- |
| Platform | Xbox 360 |
| Title ID | `4541087F` |
| Media ID | `6ADB5821` |
| Executable version | `0.0.0.2` |

The SHA-256 of `default.xex` must be:

```text
116ba3ee37fcf0d8db60b7d47c971fdb6d3eb2a7a4d3cfc3611a06704a588ae5
```

The importer checks this automatically. Other revisions are rejected because the compiled code uses revision-specific addresses. It also verifies each copied file against the selected source. Game downloads, disc dumping, and ISO/archive extraction are outside the importer.

## Set up a player package

1. **Extract the complete player package** into a writable folder. Keep the executable, DLLs, scripts, and launchers together; do not run them from inside the ZIP.
2. **Locate your extracted game folder.** Select the folder that directly contains both `default.xex` and `data`, as shown below.
3. **Run `Import Game Files.cmd`.** Choose that folder and wait for the copy and verification to finish. Import leaves the source intact and refuses to overwrite an existing `game` folder.
4. **Connect your controller.** For a USB DualSense, close DS4Windows before using direct input.
5. **Run `Launch Skate 2.exe`.** Allow the initial loading screen to finish, then follow the in-game prompts. Use the launcher each time so the graphics and frame-rate profile is applied. `Launch Skate 2.cmd` is also supported.

```text
Your extracted game folder/
├── default.xex
└── data/
    └── ...
```

After import, the package contains `game/default.xex` and `game/data`. The `userdata`, `cache`, and `logs` folders are created as needed.

## Armoury Crate and ROG Ally

1. In the Windows desktop, extract the complete player ZIP and run **Import Game Files.cmd** once.
2. In Armoury Crate, add a custom game and select **Launch Skate 2.exe** from that extracted folder.
3. Keep the EXE, `scripts` folder, game application, DLLs, and other package files together. A shortcut may point to the launcher; moving the EXE by itself will not work.

Select **Launch Skate 2.exe** when adding the game so the normal startup checks and 2× / unlimited profile are applied. Directly selecting `skate2.exe` skips the launcher profile. These instructions describe the Windows entrypoint; gameplay and controller behavior on ROG Ally hardware have not been validated.

If your game-library entry supports launch arguments, use `--render-scale 1` for lower GPU load. See [native launcher options](DISPLAY.md#advanced-launch-options).

## Settings and controls

- Use the controller for the original game controls. On a DualSense, Cross corresponds to Xbox A, Circle to B, Square to X, Triangle to Y, and Options to Start. Prompts remain Xbox-style.
- Press **F4** to open PC settings. Choose **Save to config** after changing settings, then restart when prompted.
- For sound, open **F4 → Audio → Output device**, choose the desired output, select **Save to config**, and restart. A connected controller can become Windows' default audio device.
- The default launcher selects **2× quality and unlimited FPS**. Use **Launch Skate 2 - 1x Performance.cmd** to reduce GPU load. Additional options are in [Display and performance](DISPLAY.md).
- Keep the runtime's **VSync** option enabled when using the supplied frame-rate profiles. It also controls guest timing.

## Saves and updates

Keep the entire `userdata` folder, including its metadata files. `skate2.toml` stores PC settings; `cache` contains generated cache data.

To upgrade from **v0.1.0 to v0.1.1**:

1. Close the game. Back up the entire `userdata` folder and `skate2.toml` if present.
2. Extract the new release into a temporary folder, then copy its contents into your existing installation. Replace the supplied program, launcher, script, and documentation files; merge folders rather than deleting the old installation.
3. Open **Launch Skate 2.exe** and choose **Continue Career** to check your existing skater and progress. A completed game import does not need to be repeated.

The release ZIP excludes `game`, `userdata`, `cache`, and `skate2.toml`, so copying its files into the existing installation leaves those local files in place. Keep your backup until the save check succeeds. v0.1.1 changes the launcher and packaging; its game executable and runtime DLLs are unchanged from v0.1.0. Migration between separate installations is still being tested.

In a source checkout, saves and settings live under `skate2/`. In a player package, they live beside `skate2.exe`. A separate package starts with separate saves.

## Troubleshooting

| Problem | Next step |
| --- | --- |
| No `skate2.exe` in the download | Download the named Windows player ZIP from [Releases](https://github.com/christianortel/skate2-recompile-pc/releases/latest), not a Source code archive. |
| No `Launch Skate 2.exe` | Use the v0.1.1 or later player ZIP and extract every file. v0.1.0 and an unbuilt source checkout can still use `Launch Skate 2.cmd`. |
| Native launcher cannot find its script or game | Keep the complete package together. Re-extract the release files into the installation folder rather than moving the launcher EXE alone. |
| Game data is missing | Run `Import Game Files.cmd` and select the folder containing `default.xex` and `data`. |
| Unsupported executable revision | Compare the SHA-256 above. Do not rename another executable or bypass the revision check. |
| Import says `game` already exists | If a previous import completed, skip import and launch. Check an incomplete installation before changing any files. |
| Black screen during startup | Initial loading can take time. If it never progresses or the process exits, keep the error and the latest log from `logs` beside the executable. |
| Low performance | On a laptop or handheld, connect power and check that an appropriate Performance/Turbo mode is selected rather than Silent/low-power mode. Then try **Launch Skate 2 - 1x Performance.cmd**. See [performance troubleshooting](DISPLAY.md#performance-troubleshooting). |
| Colored stripes or black surfaces | Use a supplied launcher so the graphics synchronization settings are applied. If corruption persists, include the location and launcher in an issue report. |
| No controller input | Check the cable/connection and try direct USB input with DS4Windows closed. Reconnect and wireless behavior are still under testing. |
| Sound goes to the controller | Select the intended output in **F4 → Audio → Output device**, choose **Save to config**, and restart. |
| Microsoft Visual C++ Runtime is missing/outdated, or `MSVCP140`/`VCRUNTIME140` is missing | Install or repair the [official Microsoft x64 runtime](https://aka.ms/vc14/vc_redist.x64.exe), then launch again. |
| Another DLL is missing | Re-extract the complete player package. Do not download individual DLLs from unrelated sites. |
| PowerShell policy error | Both the native EXE and CMD launchers use Windows PowerShell and apply their script setting only to the child process. Organization-enforced restrictions may still prevent launch. |

For unresolved problems, [open an issue](https://github.com/christianortel/skate2-recompile-pc/issues) using the [reporting checklist](../README.md#reporting-a-problem).

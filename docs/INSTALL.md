# Installation and controls

**A public player download is not available yet.** To play from the current repository, use [Build from source](BUILD.md). The package instructions below apply to a compiled Windows player package containing `skate2.exe`.

## What you need

| Item | Requirement |
| --- | --- |
| Operating system | Windows x64; Linux, macOS, and Windows on ARM are not supported by this build |
| Processor | Intel/AMD processor supporting x86-64-v2, the SDK's build target |
| Graphics | Direct3D 12 GPU and driver; minimum GPU/VRAM requirements have not been established |
| Input | A controller; USB DualSense has direct input support without DS4Windows |
| Game data | Your own extracted copy matching the executable below |
| Storage | Space for a second copy of the extracted game, about 6.8 GB for the supported file set, plus saves and cache |
| Launcher | Windows PowerShell 5.1, included with Windows 10/11 |

The player package includes its required Visual C++ runtime DLLs. Build tools are needed only when compiling from source. See [compatibility limits](KNOWN_ISSUES.md) for outstanding hardware testing.

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
5. **Run `Launch Skate 2.cmd`.** Allow the initial loading screen to finish, then follow the in-game prompts. Use the launcher each time so the graphics and frame-rate profile is applied.

```text
Your extracted game folder/
├── default.xex
└── data/
    └── ...
```

After import, the package contains `game/default.xex` and `game/data`. The `userdata`, `cache`, and `logs` folders are created as needed.

## Settings and controls

- Use the controller for the original game controls. On a DualSense, Cross corresponds to Xbox A, Circle to B, Square to X, Triangle to Y, and Options to Start. Prompts remain Xbox-style.
- Press **F4** to open PC settings. Choose **Save to config** after changing settings, then restart when prompted.
- For sound, open **F4 → Audio → Output device**, choose the desired output, select **Save to config**, and restart. A connected controller can become Windows' default audio device.
- The default launcher selects **2× quality and unlimited FPS**. Use **Launch Skate 2 - 1x Performance.cmd** to reduce GPU load. Additional options are in [Display and performance](DISPLAY.md).
- Keep the runtime's **VSync** option enabled when using the supplied frame-rate profiles. It also controls guest timing.

## Saves and updates

Keep the entire `userdata` folder, including its metadata files. `skate2.toml` stores PC settings; `cache` contains generated cache data.

For an update, close the game and back up `userdata` before replacing any files. Keep the previous installation until the new build loads your save successfully. Save migration between separate installations is still being tested.

In a source checkout, saves and settings live under `skate2/`. In a player package, they live beside `skate2.exe`. A separate package starts with separate saves.

## Troubleshooting

| Problem | Next step |
| --- | --- |
| No `skate2.exe` in the download | You have the source archive. Follow [BUILD.md](BUILD.md). |
| Game data is missing | Run `Import Game Files.cmd` and select the folder containing `default.xex` and `data`. |
| Unsupported executable revision | Compare the SHA-256 above. Do not rename another executable or bypass the revision check. |
| Import says `game` already exists | If a previous import completed, skip import and launch. Check an incomplete installation before changing any files. |
| Black screen during startup | Initial loading can take time. If it never progresses or the process exits, keep the error and the latest log from `logs` beside the executable. |
| Low performance or visual corruption | Restart with **Launch Skate 2 - 1x Performance.cmd**. If it persists, include the location and launcher in an issue report. |
| No controller input | Check the cable/connection and try direct USB input with DS4Windows closed. Reconnect and wireless behavior are still under testing. |
| Sound goes to the controller | Select the intended output in **F4 → Audio → Output device**, choose **Save to config**, and restart. |
| A DLL is missing | Re-extract the complete player package. Do not download individual DLLs from unrelated sites. |
| PowerShell policy error | Use the supplied CMD launcher. It applies its script setting only to the child process; organization-enforced restrictions may still prevent launch. |

For unresolved problems, [open an issue](https://github.com/christianortel/skate2-recompile-pc/issues) using the [reporting checklist](../README.md#reporting-a-problem).

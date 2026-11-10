# Installation and controls

Download **Skate2-PC-v0.1.1-Windows-x64.zip** from [Releases](https://github.com/christianortel/skate2-recompile-pc/releases/latest). It contains the compiled game application, runtime, and native **Launch Skate 2.exe** entrypoint. The CMD launchers remain included. You do not need to compile anything to play. [Build from source](BUILD.md) is a separate guide for contributors.

## What you need

| Item | Requirement |
| --- | --- |
| Operating system | Windows 10/11 x64; Linux, macOS, and Windows on ARM are not supported by this build |
| Processor | Intel/AMD processor supporting x86-64-v2, the SDK's build target |
| Graphics | Direct3D 12 GPU and driver; minimum GPU/VRAM requirements have not been established |
| Input | A controller; USB DualSense has direct input support without DS4Windows |
| Game data | Your own Xbox 360 disc image (`.iso`) or extracted copy matching the executable below |
| Storage | Space for the imported game, about 6.8 GB for the supported file set, plus saves and cache |
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

The importer checks this automatically, before copying anything. Other revisions are rejected because the compiled code uses revision-specific addresses. It also verifies each copied file against the selected source. It reads Xbox 360 ISO images directly; game downloads, disc dumping, and compressed-archive extraction are outside the importer.

## Set up a player package

1. **Extract the complete player package** into a writable folder. Keep the executable, DLLs, scripts, and launchers together; do not run them from inside the ZIP.
2. **Locate your game.** Either your Xbox 360 disc image (`.iso`), or an extracted folder that directly contains both `default.xex` and `data`, as shown below.
3. **Run `Import Game Files.cmd`.** Answer **Yes** to select an ISO or **No** to select an extracted folder, or drop either onto the file. Wait for the copy and verification to finish. From an ISO, only `default.xex` and `data` are imported; the disc's console system update is not needed. Import leaves the source intact and refuses to overwrite an existing `game` folder.
4. **Connect your controller.** For a USB DualSense, close DS4Windows before using direct input.
5. **Run `Launch Skate 2.exe`.** Allow the initial loading screen to finish, then follow the in-game prompts. Use the launcher each time: it checks the game files and runtime, applies the graphics synchronization settings, and starts with your saved settings, or the default 2x quality / unlimited FPS profile when none are saved. `Launch Skate 2.cmd` is also supported.

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

Select **Launch Skate 2.exe** when adding the game so the normal startup checks are applied. It starts with the settings saved from the in-game settings panel (F1) or F4, or the default 2x / unlimited profile when none are saved. Directly selecting `skate2.exe` uses the same settings but skips the launcher's checks for the game files and the Visual C++ runtime. These instructions describe the Windows entrypoint; gameplay and controller behavior on ROG Ally hardware have not been validated.

For lower GPU load, select 1x render scale in the settings panel and save, or, if your game-library entry supports launch arguments, use `--render-scale 1`. See [native launcher options](DISPLAY.md#advanced-launch-options).

## Steam Deck

The Windows build can run on a Steam Deck under Proton as a non-Steam game. This has not been tested on Steam Deck hardware. The launcher needs Windows PowerShell, which Proton does not provide, so Steam starts `skate2.exe` directly. It then uses the settings saved in `skate2.toml` beside it, or the default profile.

In a source checkout with a completed Release build and imported game files, create a self-contained folder for the Deck:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Skate2SteamDeck.ps1
```

This creates `steam-deck` in the repository root. It contains `skate2.exe`, `rexruntime.dll` and `rexgpu-xenos.dll`; the Microsoft Visual C++ x64 runtime DLLs, version 14.44.35211.0 or later, bundled because Proton may not provide a current runtime; the third-party notices; a copy of `game`; a `skate2.toml` with the Steam Deck settings; and `README-Steam-Deck.txt` with the steps on the Deck. The script first checks the `default.xex` SHA-256, the native build and the free space. It builds into a temporary folder beside the output, verifies the copied file sizes and the `default.xex` hash, and renames the folder into place at the end.

| Option | Effect |
| --- | --- |
| `-CheckOnly` | Checks the inputs and lists what would be created, without writing anything |
| `-OutputDirectory <folder>` | Creates the folder elsewhere; relative paths start at the repository root |
| `-NoGameData` | Leaves out the 6.75 GB of game files and creates an empty `game` folder. Copy `default.xex` and `data` into it before the first start |
| `-IncludeSaves` | Also copies the saves from `skate2/userdata`, so you can continue on the Deck. The source saves are only read |
| `-VerifyAllHashes` | Also compares the SHA-256 of every copied game file |
| `-Force` | Replaces an existing output folder, but only one this script created. It refuses a folder whose `userdata` holds saves the script did not copy |

An existing folder is never replaced without `-Force`.

`skate2.toml` holds the **Steam Deck** [preset](DISPLAY.md#presets) of the settings panel: 60 FPS mode, 1x render scale, RTV render path, GPU submit interval 1024 and the submission thread. It also enables GPU idle-clean synchronization and asynchronous shader compilation. The Windows default is synchronous shader compilation; `README-Steam-Deck.txt` describes how to switch. Saving in the settings panel or F4 rewrites the file.

On the Deck, copy the whole folder in Desktop Mode, add `skate2.exe` as a non-Steam game, and under **Properties → Compatibility** force **Proton Experimental**. Launch options are not needed. Steam Input presents the Deck controls as an Xbox controller; hold **View + Menu** for about a second to open the settings panel. Saves, settings and logs are written inside the folder, beside `skate2.exe`.

The folder contains your own game files, and with `-IncludeSaves` your saves. Do not upload or share it. `.gitignore` excludes `steam-deck`.

## Settings and controls

- Use the controller for the original game controls. On a DualSense, Cross corresponds to Xbox A, Circle to B, Square to X, Triangle to Y, and Options to Start. Prompts remain Xbox-style.
- Press **F1**, or hold **Back + Start** (View + Menu) on an Xbox-compatible controller for about a second, to open the **Skate 2 settings panel**. Press F1 or hold Back + Start again to close it. The panel covers the frame-rate, rendering, display, NVIDIA and world-detail settings, with presets; see [In-game settings panel](DISPLAY.md#in-game-settings-panel).
- In the panel, use the D-pad to move, **A** to select and **B** to go back or close; the left stick scrolls the list. On a keyboard, use the arrow keys, **Enter** to select and **Esc** to go back or close. The mouse also works.
- The game ignores input while the panel is open.
- Settings marked **Live** change immediately. Others apply at the next start and show **Restart needed** once changed.
- Choose **Save to skate2.toml** to keep your changes. **Launch Skate 2.exe** and **Launch Skate 2.cmd** start with the saved settings. Unsaved changes last until the game closes.
- **(L)** marks a setting that a launch profile or launch option sets at startup, such as the render scale of **Launch Skate 2 - 1x Performance.cmd**. That shortcut applies its own value again at its next start, in place of a saved change. Saving also saves **(L)** values, and the default launchers then use them.
- Settings saved earlier from F4, which the default launcher used to override, now take effect. If the game starts with different settings than before, check them in the panel.
- Press **F4** for the full list of runtime settings. Choose **Save to config** after changing settings, then restart when prompted.
- **Note on controllers:** the panel reads the controller through XInput. A controller that does not appear as an Xbox/XInput controller, for example a DualSense used directly without Steam Input, cannot open or navigate the panel. Use **F1** with a keyboard or mouse instead. Game controls are unaffected.
- For sound, open **F4 → Audio → Output device**, choose the desired output, select **Save to config**, and restart. A connected controller can become Windows' default audio device.
- Without saved settings, the default launcher starts with **2x quality and unlimited FPS**. To reduce GPU load, select 1x in the panel and save, or use **Launch Skate 2 - 1x Performance.cmd**. Additional options are in [Display and performance](DISPLAY.md).
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

# Skate 2 PC

A community Windows port of the Xbox 360 version of **Skate 2**, built with [ReXGlue](https://github.com/rexglue/rexglue-sdk).

**[Download Skate 2 PC for Windows](https://github.com/christianortel/skate2-recompile-pc/releases/latest)** — a compiled player package. No compiler or development tools are needed to play.

## Getting started

1. Download **Skate2-PC-v0.1.1-Windows-x64.zip** from [Releases](https://github.com/christianortel/skate2-recompile-pc/releases/latest) and extract the entire ZIP into a writable folder.
2. Run **Import Game Files.cmd** and select your extracted Xbox 360 game folder containing `default.xex` and `data`. This is a one-time copy and verification step.
3. Connect your controller and run **Launch Skate 2.exe**.

If the launcher requests the Microsoft Visual C++ x64 Runtime, open the included **Install Visual C++ Runtime.url**, run Microsoft's installer, then launch again. The [installation guide](docs/INSTALL.md) covers every step, the supported game revision, controls, and troubleshooting.

You will need:

- A Windows 10/11 x64 PC with a Direct3D 12 GPU.
- Windows PowerShell 5.1, included with Windows 10/11; the native launcher uses the existing startup script.
- Your own extracted files from the [supported Xbox 360 game revision](docs/INSTALL.md#supported-game-version).
- A controller. USB DualSense input works directly without DS4Windows; broader controller compatibility is still being tested.

Use the named Windows ZIP under **Releases**. GitHub's **Code → Download ZIP** and the automatically generated **Source code** archives are for developers; they do not contain the player executable.

Original game files are required and are not included or downloaded by this project. An ISO or compressed archive must be extracted before import.

## Features

- Native recompiled CPU code with Direct3D 12 graphics translation.
- Free Skate, campaign gameplay, and instant replay.
- Controller input, selectable audio output, and local saves.
- Unlimited and paced frame-rate options.
- 1× and 2× rendering profiles, with an experimental 4× option.

Use **Launch Skate 2.exe** for the default **2× quality / unlimited FPS** profile. **Launch Skate 2.cmd** remains supported with the same settings. For lower GPU load, use **Launch Skate 2 - 1x Performance.cmd**. Performance depends on hardware, power mode, and scene complexity.

For Armoury Crate, add **Launch Skate 2.exe** as a custom game after completing the desktop import. Keep all package files together. See [Armoury Crate and ROG Ally setup](docs/INSTALL.md#armoury-crate-and-rog-ally); ROG Ally hardware has not been tested. Existing v0.1.0 players can follow the [upgrade steps](docs/INSTALL.md#saves-and-updates) without importing their game again.

Testing includes Free Skate, campaign progression, instant replay, save/reload, Alt-Tab, direct USB DualSense input, and player-package relaunch. An approximately hour-long play session progressed further through the campaign without reported glitches. These results come from one Windows PC; full campaign completion and broader hardware compatibility have not been verified. See [release notes](docs/RELEASE_NOTES.md) and [known issues](docs/KNOWN_ISSUES.md).

## Guides

| Guide | Contents |
| --- | --- |
| [Installation and controls](docs/INSTALL.md) | Game revision, package setup, controller, audio, saves, and troubleshooting |
| [Build from source](docs/BUILD.md) | Tool downloads and numbered build instructions |
| [Display and performance](docs/DISPLAY.md) | Rendering quality, FPS options, monitors, 4K, and ultrawide status |
| [Known issues and roadmap](docs/KNOWN_ISSUES.md) | Current limitations and planned work |
| [How it works](docs/HOW_IT_WORKS.md) | Recompilation approach and project credits |

## Reporting a problem

Found a glitch, crash, or installation problem? **[Submit a bug report](https://github.com/christianortel/skate2-recompile-pc/issues/new/choose)** so we can investigate. The form asks for the version, hardware, launcher, location, and steps to reproduce. Screenshots and short clips help. Remove personal paths from logs before sharing; do not upload game files or saves.

## License and credits

Newly authored port code and documentation are [MIT licensed](LICENSE). Dependencies and derived patches retain their respective licenses; see [third-party notices](THIRD_PARTY_NOTICES.md) and [credits](docs/HOW_IT_WORKS.md#credits).

This is an independent fan project, unaffiliated with EA or its licensors. Skate 2 and its original game content belong to their respective rights holders. The project license does not cover the original game, its assets, or generated game-derived code.

# Skate 2 PC

A community Windows port of the Xbox 360 version of **Skate 2**, built with [ReXGlue](https://github.com/rexglue/rexglue-sdk).

**Release status:** in development. Source code is available; a downloadable Windows player build has not been released. GitHub's **Code → Download ZIP** contains source code, not an installed game.

## Getting started

To play the current version, follow the [step-by-step build guide](docs/BUILD.md). It covers the required tools, importing game files, compiling, and launching.

You will need:

- A Windows x64 PC with a Direct3D 12 GPU.
- Your own extracted files from the [supported Xbox 360 game revision](docs/INSTALL.md#supported-game-version).
- A controller. USB DualSense input works directly without DS4Windows; broader controller compatibility is still being tested.
- The development tools listed in the build guide until a player download is available.

Original game files are required and are not included or downloaded by this project. An ISO or compressed archive must be extracted before import.

## Features

- Native recompiled CPU code with Direct3D 12 graphics translation.
- Free Skate, campaign gameplay, and instant replay.
- Controller input, selectable audio output, and local saves.
- Unlimited and paced frame-rate options.
- 1× and 2× rendering profiles, with an experimental 4× option.

Use **Launch Skate 2.cmd** for the default **2× quality / unlimited FPS** profile. For lower GPU load, use **Launch Skate 2 - 1x Performance.cmd**. Performance depends on hardware and scene complexity.

Gameplay coverage currently includes Free Skate, the opening campaign, replay, save/reload, and USB DualSense on one Windows PC. Full campaign completion and broader hardware compatibility remain in progress. See [known issues and roadmap](docs/KNOWN_ISSUES.md) before playing.

## Guides

| Guide | Contents |
| --- | --- |
| [Installation and controls](docs/INSTALL.md) | Game revision, package setup, controller, audio, saves, and troubleshooting |
| [Build from source](docs/BUILD.md) | Tool downloads and numbered build instructions |
| [Display and performance](docs/DISPLAY.md) | Rendering quality, FPS options, monitors, 4K, and ultrawide status |
| [Known issues and roadmap](docs/KNOWN_ISSUES.md) | Current limitations and planned work |
| [How it works](docs/HOW_IT_WORKS.md) | Recompilation approach and project credits |

## Reporting a problem

Open an [issue](https://github.com/christianortel/skate2-recompile-pc/issues) with the build or commit, Windows version, GPU and driver, controller, launcher used, game mode/location, and steps to reproduce. Include the error message when available. Remove personal paths from logs before sharing; do not upload game files or saves.

## License and credits

Newly authored port code and documentation are [MIT licensed](LICENSE). Dependencies and derived patches retain their respective licenses; see [third-party notices](THIRD_PARTY_NOTICES.md) and [credits](docs/HOW_IT_WORKS.md#credits).

This is an independent fan project, unaffiliated with EA or its licensors. Skate 2 and its original game content belong to their respective rights holders. The project license does not cover the original game, its assets, or generated game-derived code.

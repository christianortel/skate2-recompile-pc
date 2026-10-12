# Skate 2 PC recompilation

A community Windows PC recompilation project built with [ReXGlue](https://github.com/rexglue/rexglue-sdk). Bring your own supported Xbox 360 game files. This repository contains the port's source, configuration, and runtime patches; it does not contain the original game or generated game code.

**Status: playable development build.** Free Skate, initial campaign gameplay, instant replay, USB DualSense input, and Alt-Tab have been user-tested on one Windows PC. The latest unlimited-FPS test was reported much smoother and visually clean after a GPU synchronization change. The user also confirmed the existing skater and progress returned after fully closing and reopening the game. Full-game completion, broader save coverage, long sessions, and clean-PC installation remain unverified.

## Start here

- Players: [Installation and controls](docs/INSTALL.md).
- Developers: [Build from source](docs/BUILD.md).
- [Display and quality options](docs/DISPLAY.md).
- [Known issues and planned work](docs/KNOWN_ISSUES.md).
- [How the port works](docs/HOW_IT_WORKS.md).

A downloadable release has not been published yet. GitHub's **Download ZIP** contains source code and cannot be played without building it. A future player package is intended to use three steps: extract it, run **Import Game Files.cmd**, then open **Launch Skate 2.cmd**.

## Current features

- Native recompiled CPU code with ReXGlue's Xbox 360 runtime and Direct3D 12 graphics translation.
- Controller input through SDL; a USB PS5 controller was tested without DS4Windows. Xbox controllers require separate verification.
- Unlimited and paced frame-rate options, selectable audio output, and local saves/cache folders.
- Optional 2x rendering quality, reported sharper, smooth, and visually clean in a short user test. The 4x option remains unvalidated. Proper 32:9 ultrawide is planned, not implemented.

**Launch Skate 2.cmd** uses the latest user-confirmed profile: 2x quality, unlimited FPS, synchronous shader compilation, and GPU idle-clean synchronization. A 1x Performance launcher keeps the same timing fix at original render quality. Directly opening the executable bypasses the launcher's profile. Frame-rate labels are targets, not guaranteed performance.

## Contributing and release preparation

Reports should include game revision, GPU/driver, launcher, game mode/location, reproduction steps, and whether it happens at the default quality. Review logs for personal paths before sharing them. Do not submit game files, generated recompiled game code, or save data.

See [release checklist](docs/RELEASE_CHECKLIST.md) and [third-party notices](THIRD_PARTY_NOTICES.md). Newly authored port code and documentation use the [MIT license](LICENSE). Third-party code and derived patches retain their applicable upstream terms. This license does not cover the original game, its assets, or generated game-derived code.

This is an independent fan project. This project is not endorsed by or affiliated with EA or its licensors. Skate 2 and its original game content belong to their respective rights holders; this project takes no credit for the original game. This statement does not grant permission to redistribute game files. No claim is made that this is the first Skate 2 recompilation project.

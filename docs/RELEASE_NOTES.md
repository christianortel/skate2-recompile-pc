# Skate 2 PC v0.1.1

A Windows launcher and packaging update. Extract the player ZIP, import your supported Xbox 360 game files once, and open **Launch Skate 2.exe**. No compiler or development tools are required to play.

## Changed in v0.1.1

- Adds a native **Launch Skate 2.exe** entrypoint for desktop shortcuts and custom game entries in Armoury Crate.
- Retains the CMD launchers and the same PowerShell startup checks, **2× quality / unlimited FPS** default, and graphics synchronization fixes.
- Adds Armoury Crate/ROG Ally setup instructions, an in-place upgrade guide, and laptop power-mode troubleshooting.

The game executable and runtime DLLs are unchanged from v0.1.0. The native launcher still uses Windows PowerShell 5.1, which is included with Windows 10/11. Keep the complete package together; the launcher EXE is not a standalone game installation. ROG Ally hardware and integrated controller behavior have not been tested.

Existing v0.1.0 players should close the game, back up `userdata` and their settings, then copy the new release files into the existing installation. The release excludes local game data, saves, cache, and settings. See the [upgrade steps](INSTALL.md#saves-and-updates).

## Included

- Recompiled game application and patched ReXGlue runtime.
- Game-file importer with executable-revision validation and copy verification.
- The established **2× quality / unlimited FPS** launch profile, including synchronous shader compilation and the GPU synchronization fix for colored stripes and black surfaces.
- 1× performance, 2× quality, experimental 4× quality, and 60 FPS launchers.
- Direct USB DualSense input, selectable audio output, PC settings, and local saves.
- Installation instructions, dependency notices, and a shortcut to the bug-report form.

The player package starts without game files, saves, personal settings, logs, or shader caches. Windows and the separately installed Microsoft Visual C++ x64 runtime provide system dependencies.

## Gameplay coverage

Free Skate, campaign progression, instant replay, save/reload, Alt-Tab, direct USB DualSense input, and player-package quit/relaunch have been exercised on the development PC. The 2× profile was reported sharper, smooth, and free of the earlier graphics corruption. A subsequent approximately hour-long session progressed further through the campaign without reported glitches.

This is the gameplay coverage of the established v0.1.0 application/runtime binaries, retained in v0.1.1. A separate build from the pinned SDK sources also compiled successfully; its new binaries are not substituted into this release. Native-launcher and package checks are tracked separately in the [release checklist](RELEASE_CHECKLIST.md).

Full campaign completion, installation on additional clean PCs, Xbox and wireless controller hardware, and broader GPU compatibility remain unverified. True ultrawide camera/HUD support is not implemented. See [known issues](KNOWN_ISSUES.md).

## Downloads

- **Skate2-PC-v0.1.1-Windows-x64.zip** — the player package.
- **Runtime-Source ZIP** on the release page — corresponding source and rebuild/relink instructions for the unchanged runtime.
- **SHA256SUMS.txt** — download checksums.

Use the Windows player ZIP to play. GitHub's automatically generated source archives are for developers.

## Feedback

If anything glitches, crashes, fails to install, or behaves incorrectly, [submit a bug report](https://github.com/christianortel/skate2-recompile-pc/issues/new/choose). Include the release version, hardware, launcher, and steps or location needed to reproduce it. Screenshots or short clips are welcome; do not attach original game files or saves.

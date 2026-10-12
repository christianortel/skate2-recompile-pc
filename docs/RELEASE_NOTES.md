# Skate 2 PC v0.1.0

The first downloadable Windows x64 player release. Extract the player ZIP, import your supported Xbox 360 game files once, and launch. No compiler or development tools are required.

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

This release preserves the established application/runtime binaries used for package testing. A separate build from the pinned SDK sources also compiled successfully; its new binaries are not substituted into this release.

Full campaign completion, installation on additional clean PCs, Xbox and wireless controller hardware, and broader GPU compatibility remain unverified. True ultrawide camera/HUD support is not implemented. See [known issues](KNOWN_ISSUES.md).

## Downloads

- **Skate2-PC-v0.1.0-Windows-x64.zip** — the player package.
- **Skate2-PC-v0.1.0-Runtime-Source.zip** — corresponding runtime source and rebuild/relink instructions for developers.
- **SHA256SUMS.txt** — download checksums.

Use the Windows player ZIP to play. GitHub's automatically generated source archives are for developers.

## Feedback

If anything glitches, crashes, fails to install, or behaves incorrectly, [submit a bug report](https://github.com/christianortel/skate2-recompile-pc/issues/new/choose). Include the release version, hardware, launcher, and steps or location needed to reproduce it. Screenshots or short clips are welcome; do not attach original game files or saves.

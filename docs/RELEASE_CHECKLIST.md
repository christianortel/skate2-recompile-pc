# Release verification

This page separates release-specific checks from compatibility testing that continues after release.

## v0.1.1 native launcher and package

- [x] Update player instructions for `Launch Skate 2.exe`, CMD alternatives, the PowerShell requirement, Armoury Crate setup, and an in-place v0.1.0 upgrade.
- [x] Build the native x64 launcher and verify its native imports and failure handling.
- [x] Verify launch from a different working directory and paths containing spaces and Unicode characters.
- [x] Verify the packaged native launcher invokes the existing startup logic with the default 2× quality / unlimited FPS settings and graphics fixes.
- [x] Confirm the player executable and runtime DLL hashes match the established v0.1.0 release.
- [x] Verify the versioned package includes the native launcher and excludes imported game files, saves, cache, and personal configuration.
- [x] Verify an in-place update retains local game data, saves, cache, and settings using synthetic files; actual save/reload coverage remains separate.

The native launcher passed 54 fixture assertions. An isolated real-game startup check verified the visible game window, launch settings, graphics submission, process lifetime, and normal shutdown. An upgrade fixture retained synthetic game, save, cache, and settings files. These are launcher and packaging checks; the gameplay coverage below applies to the unchanged v0.1.0 game/runtime binaries.

At publication, compare the uploaded player and corresponding runtime-source asset digests against `SHA256SUMS.txt`. The runtime-source archive is unchanged from v0.1.0.

## v0.1.0 player package

- [x] Preserve the established application/runtime binaries and 2× quality / unlimited FPS launch profile.
- [x] Verify native x64 imports and document the separate Microsoft Visual C++ runtime prerequisite.
- [x] Provide an importer with executable-revision and per-file copy verification.
- [x] Check startup flags, native DLL loading, intro rendering, and direct USB DualSense detection in an isolated package.
- [x] Check Free Skate performance, clean graphics, and quit/relaunch in the isolated player package.
- [x] Exercise campaign progression, instant replay, Alt-Tab, and existing career save/reload on the development PC.
- [x] Complete an approximately hour-long campaign session without reported glitches.
- [x] Provide player installation instructions, requirements, known issues, and a structured bug-report form.
- [x] Keep game data, existing saves, personal settings, logs, and caches out of the distribution staging policy.
- [x] Verify player-package contents, dependency notices, and the runtime-source rebuild/relink procedure. The unmodified rebuild preserves the runtime exports and satisfies the player's runtime imports.

The versioned player and runtime-source archives and their checksums are provided on the [release page](https://github.com/christianortel/skate2-recompile-pc/releases/tag/v0.1.0). Archive entry hashes and published asset digests are checked during release preparation.

## Build and source checks

- [x] Build the pinned, patched SDK in an isolated directory, generate game code, and compile the application on the development PC.
- [x] Apply MIT to newly authored code and documentation while preserving dependency terms.
- [x] Credit ReXGlue, Xenia, patch research, and the earlier community recompilation.
- [x] Review the source export allowlist and scan exported text for game content, generated inputs, personal runtime files, local paths, and common credential patterns.
- [x] Publish and verify the reviewed source export.

## Continuing compatibility coverage

- [ ] Install and play on additional clean Windows PCs without build tools.
- [ ] Reproduce the complete game-source build workflow on another PC.
- [ ] Test gameplay with freshly rebuilt SDK binaries before replacing the established release runtime.
- [ ] Complete the campaign and validate every mission and photo challenge.
- [ ] Test additional save cases, package save migration, and interrupted-save recovery.
- [ ] Test controller disconnect/reconnect, Xbox hardware, wireless input, and multiple controllers.
- [ ] Test Armoury Crate launch/quit/relaunch and integrated controls on ROG Ally hardware.
- [ ] Check audio, settings persistence, and display selection across additional PCs.
- [ ] Measure performance across GPU families, rendering scales, and monitor configurations.
- [ ] Implement and validate true ultrawide camera, HUD, and menu support.

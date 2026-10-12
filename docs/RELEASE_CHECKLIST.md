# Release checklist

This checklist tracks the first downloadable Windows player release. Source publication is complete; package validation and release preparation are still in progress.

## Build and packaging

- [x] Preserve the established 2× quality / unlimited FPS launch profile.
- [x] Provide a game importer with executable-revision and per-file copy checks.
- [x] Build the pinned, patched SDK in an isolated directory, generate game code, and compile the application on the development PC.
- [x] Stage the executable, required runtime DLLs, launchers, guides, and notices without game data or existing saves.
- [x] Verify packaged startup flags, native DLL loading, intro rendering, and direct USB DualSense detection.
- [ ] Test gameplay with the freshly rebuilt SDK binaries; package startup checks used the established runtime binaries.
- [ ] Complete Free Skate, quit/relaunch, and save checks in the isolated player package.
- [ ] Validate installation and launch on a clean Windows PC without build tools.
- [ ] Reproduce the source-build workflow on another PC.

## Gameplay and compatibility

- [x] Check Free Skate, opening campaign gameplay, instant replay, and Alt-Tab on the development PC.
- [x] Check 2× rendering and unlimited FPS with the graphics synchronization profile.
- [x] Exit and reopen the development build, then reload the existing skater and career progress.
- [ ] Test longer sessions, campaign progression, and photo challenges.
- [ ] Check additional save cases, settings persistence, and migration between installations.
- [ ] Test controller disconnect/reconnect, Xbox controllers, and wireless input.
- [ ] Verify controller, audio output, and display behavior across additional PCs.
- [ ] Measure performance and image quality across GPU families, rendering scales, and monitor configurations.

## Distribution

- [x] Apply MIT to newly authored port code and documentation, preserving third-party terms.
- [x] Credit ReXGlue, Xenia, game-patch research, and the earlier community recompilation.
- [x] Collect 36 upstream notice files with source references and exact hashes.
- [ ] Resolve the remaining dependency-source, relink, provenance, and redistributable items in [NOTICE-INDEX.json](../licenses/NOTICE-INDEX.json).
- [x] Review the source export allowlist and scan exported text for game content, generated inputs, personal runtime files, local paths, and common credential patterns.
- [x] Publish and verify the reviewed source export.
- [ ] Review the final player package separately for game data, personal files, notices, and binary/source correspondence.
- [ ] Assign a version and publish checksums, release notes, requirements, and working download links.
- [ ] Verify the installation guide against the downloadable artifact before announcing a player release.

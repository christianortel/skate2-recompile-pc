# Known issues and roadmap

## Current limitations

| Area | Status |
| --- | --- |
| Distribution | Source is public. A downloadable Windows player release is still in preparation. |
| Game revision | Only the executable listed in [INSTALL.md](INSTALL.md#supported-game-version) is accepted. |
| Platforms | Windows x64 / Direct3D 12 only. |
| Campaign | Opening campaign gameplay works; full progression, all missions, and photo challenges have not been validated. |
| Saves | Existing career save/reload works in the development build. Migration, additional save cases, and interrupted-save recovery need testing. |
| Controllers | USB DualSense direct input has been tested. Xbox hardware, wireless connections, reconnects, and multiple controllers need broader coverage. |
| Startup | A black loading screen can precede the title screen. |
| Performance | Shader preparation can cause pauses. FPS settings are targets, not guaranteed frame rates. |
| Graphics | Use the supplied launchers. Unlimited FPS without their synchronization settings can produce colored stripes and black surfaces. |
| Display | 2× rendering is the default. 3×/4× quality, 4K output, and monitor selection need further validation. |
| Ultrawide | True 21:9 and 32:9 support is not implemented. Use the original aspect ratio with side bars. |
| Hardware coverage | Minimum performance specifications and installation on a clean Windows PC are not yet established. |

A graphics synchronization timeout stops the game instead of continuing with incomplete GPU work. Include the latest log if this occurs.

## Planned work

- Complete portable-package installation, controller, audio, and relaunch checks on additional PCs.
- Expand campaign, save, replay, and long-session testing.
- Measure performance across GPU families and rendering profiles.
- Add ultrawide camera support with correct HUD, menus, replay, cutscenes, and effects.
- Complete runtime source materials, dependency notices, release notes, and checksums for a player download.

Progress toward the first player release is tracked in the [maintainer checklist](RELEASE_CHECKLIST.md).

## Report a problem

Use the [issue tracker](https://github.com/christianortel/skate2-recompile-pc/issues). Include the build/commit, Windows version, GPU/driver, controller, launcher, game location, and reproduction steps. State whether the issue also occurs with **Launch Skate 2 - 1x Performance.cmd**. Remove personal paths from logs and keep game files and saves out of reports.

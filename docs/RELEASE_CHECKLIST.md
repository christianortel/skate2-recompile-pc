# Release checklist

## Prepared locally

- [x] Preserve the user-tested unlimited-FPS binary and launch settings.
- [x] Make the launchers apply the successful GPU synchronization profile.
- [x] Prepare separate player, developer, display, and known-issues guides.
- [x] Provide an importer that checks the supported executable and refuses overwrites.
- [x] Prepare an explicit source export that excludes local game content and personal runtime files.
- [x] Run an actual game-file import with per-file copy verification and a short 2x gameplay check on the development PC.

## Before the first public release

- [ ] Choose the project's license.
- [x] Identify and credit the earlier Skate-2-Team/sk82-recomp reference.
- [ ] Audit all bundled runtime/dependency notices and include applicable license text/source notices. The SDK license alone is not a complete binary notice inventory.
- [x] Generate game code and compile/link the application from exported source in an isolated directory on the development PC, using a copied prebuilt SDK install.
- [ ] Validate the complete exported-source workflow including a fresh SDK build and another PC.
- [ ] Run the player package on a clean Windows PC without build tools.
- [ ] Test normal launch, controller disconnect/reconnect, speakers, Alt-Tab, quit, and relaunch.
- [x] Exit fully, reopen, and verify the existing skater and career progress on the development PC (user confirmed).
- [ ] Validate additional save cases, settings persistence, and migration into the portable package.
- [ ] Test longer campaign sessions and known progression/photo-challenge cases.
- [ ] Test higher quality modes and another GPU/controller family; document measured limits.
- [x] Review the explicit source allowlist and scan exported text for game/generated inputs, personal runtime files, local paths, and common credential signatures. This is a bounded check, not a guarantee that arbitrary secrets can be detected.
- [ ] Give the build a version, attach checksums and accurate release notes, and verify all installation links.
- [ ] Push only the reviewed source export to the user-provided repository, then publish a separately reviewed game-data-free player package when ready.

Source publication and player releases are separate steps. A clean source export and a local package are distinct artifacts; neither alone proves completion of this checklist.

# Known issues and planned work

## Current evidence

On one Windows PC, the user tested Free Skate, initial campaign gameplay, instant replay, USB DualSense without DS4Windows, and Alt-Tab. The latest unlimited-FPS session was reported much smoother and visually correct after native GPU completion was synchronized at eligible guest idle-clean requests. This is a promising development build, not full-game certification.

## Open issues

- Full campaign progression, all missions/photo challenges, and long-session stability are unverified.
- A full exit/relaunch restored the user's existing skater and progress on the development PC. Save migration, additional slots/content, and interrupted-save recovery still need testing.
- Complete Xbox/PlayStation button and trigger coverage, reconnects, wireless input, and multiple controllers need testing.
- Startup can remain black while loading. Shader preparation can still cause pauses.
- Frame-rate labels are targets. Earlier paced 60/120 tests measured roughly 29/49 guest swaps per second in selected windows on the test machine. These are not monitor FPS measurements or matched performance benchmarks.
- Unlimited presentation without the launcher's synchronization profile previously produced colored stripes and black surfaces. The successful fix has only brief single-machine gameplay coverage. It handles eligible idle-clean requests between closed frames, not every Xbox 360 GPU wait operation. A failed five-second fence wait stops the game rather than continuing with unverified completion.
- 2x quality was reported sharper, smooth, and visually clean in a short test on one PC. 3x/4x and longer high-quality sessions remain unverified. Proper 32:9/21:9 camera, HUD, menus, replay, cutscenes, and postprocessing are not implemented or validated.
- Clean-machine installation, GPU/driver compatibility, and minimum system requirements remain unverified.
- No public binary release is ready yet. Project license selection and binary dependency notices still need completion.

## Work order

1. Preserve the clean unlimited baseline and complete repeat gameplay/save/reload testing.
2. Expand 2x coverage, validate 4x quality and monitor selection separately from frame timing.
3. Add proper ultrawide projection with an explicit 16:9 fallback, then correct HUD/menu placement and test culling, replay, and effects.
4. Validate a portable package on a clean Windows PC and more than one GPU/controller family.
5. Finish notices, source/build reproducibility, release notes, hashes, and installation instructions before publishing.

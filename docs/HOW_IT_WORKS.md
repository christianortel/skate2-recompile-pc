# How this port works

ReXGlue translates the supported game's PowerPC executable into C++ during development. A native Windows compiler builds that generated code with this project's entry point and hooks. The ReXGlue runtime provides Xbox 360 operating-system services and translates the game's graphics workload to Direct3D 12. This is a native CPU recompilation with a compatibility runtime; it is not a rewrite of Skate 2's engine.

The older community recompilation snapshot was used as an analysis reference. Its addresses differed from this executable revision, and its runtime stubs were not carried into this project. The project manifest and configuration add verified function bounds and indirect-call targets, including a callback needed to enter Free Skate.

Local SDK patches address Windows builds, FLOAT16 conversion, concurrent input access, audio-device selection, configuration saving, timing diagnostics, and frame-rate validation. A vertex-buffer coherency fix has a focused regression test, but did not itself remove the user's colored/black graphics corruption.

The decisive graphics comparison kept the same area and settings while changing presentation pacing: paced modes removed corruption but felt slower. The latest build then waited for actual native GPU completion at eligible idle-clean requests in the original game's command stream. Unlimited mode with this change was reported smooth and clean. This supports a synchronization problem; the exact corrupted resource has not been traced and broader compatibility remains unproven.

The frame-rate hook changes the game's presentation interval selection without replacing its simulation clock. Unlimited retains 60 Hz guest vblank; numeric modes use paced presentation with the chosen guest refresh. These choices still require physics, camera, replay, and audio validation across content.

## Credits

- [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk), pinned to v0.10.0, and its contributors.
- [Xenia](https://github.com/xenia-project/xenia) and its contributors, whose runtime/graphics work underlies portions of ReXGlue.
- [Xenia game patches](https://github.com/xenia-canary/game-patches), including the Skate 2 presentation-interval research credited to illusion.
- [Skate-2-Team/sk82-recomp](https://github.com/Skate-2-Team/sk82-recomp), the earlier community recompilation reference, and the original game's creators. The reference used XenonRecomp; this project uses ReXGlue and revision-specific analysis.

Third-party notices remain with their respective code. Game files and generated game code are not included in the source repository.

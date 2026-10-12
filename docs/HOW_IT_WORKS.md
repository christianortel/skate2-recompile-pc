# How the port works

## Recompilation

[ReXGlue](https://github.com/rexglue/rexglue-sdk) translates the supported Xbox 360 PowerPC executable into C++. A Windows compiler builds that code with the port's application entry point and game-specific hooks. The runtime supplies Xbox 360 operating-system services, audio, input, and Direct3D 12 graphics translation.

Original game data is loaded locally at runtime. Generated game code stays local and is excluded from the public source repository.

## Game-specific work

The project manifest supplies function boundaries, indirect-call targets, and switch tables for the supported executable revision. These resolve code-discovery gaps, including callbacks used while entering Free Skate. An earlier community recompilation was an analysis reference; its runtime stubs were not carried into this project.

The SDK patches cover Windows builds, FLOAT16 conversion, concurrent input access, controller diagnostics, audio output selection, configuration persistence, vertex-buffer coherency, and frame timing.

## Graphics and frame timing

The default launch profile combines synchronous shader compilation with a graphics synchronization patch. At eligible idle-clean requests between closed frames, the runtime waits for native GPU completion before command processing continues. The patch covers this specific command pattern; it is not a complete implementation of every Xbox 360 GPU wait operation.

The frame-rate hook changes the game's presentation-interval selection while retaining its clock implementation. Unlimited mode keeps a 60 Hz guest refresh. Numeric modes use paced presentation with the selected guest refresh. The supplied profiles require guest VSync to remain enabled and apply the synchronization settings together.

## Reproducing a build

The repository pins ReXGlue v0.10.0 and includes the build patches, game configuration, importer, and packaging scripts. Follow [BUILD.md](BUILD.md) to build from your own supported game files. The source exporter excludes game data, generated game code, build outputs, saves, and local settings.

## Credits

- [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk) and its contributors.
- [Xenia](https://github.com/xenia-project/xenia) and its contributors, whose runtime and graphics work underlies portions of ReXGlue.
- [Xenia game patches](https://github.com/xenia-canary/game-patches), including Skate 2 presentation-interval research by illusion.
- [Skate-2-Team/sk82-recomp](https://github.com/Skate-2-Team/sk82-recomp), the earlier community recompilation reference.
- Skate 2's original developers and creators.

See [LICENSE](../LICENSE) for newly authored port code and [third-party notices](../THIRD_PARTY_NOTICES.md) for dependency attribution and terms.

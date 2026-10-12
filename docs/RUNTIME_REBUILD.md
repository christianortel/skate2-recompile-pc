# Rebuild the Windows runtime

Download the matching **Runtime-Source ZIP** from the project's GitHub Releases and extract it. Run these instructions inside that archive; the player ZIP and ordinary source-repository checkout do not contain the bundled runtime dependencies.

This companion contains the corresponding source for the Windows x64 D3D12 runtime shipped with Skate 2 PC. `SOURCE-MANIFEST.json` records the exact released DLL hashes, SDK commit, dependency commits, local modifications, and source-file hashes. The source already includes the port's fixes. The patches are supplied for review; do not apply them again.

FFmpeg (`libavcodec` and `libavutil`) and libmspack's LZX decompressor are statically linked into `rexruntime.dll`. You can modify those libraries and rebuild the containing DLL without game data or generated Skate 2 code. The game executable calls the runtime through its DLL interface. `rexgpu-xenos.dll` is rebuilt alongside it so both use the same headers and configuration.

## Build

Use Windows x64, Visual Studio 2022 with Desktop development with C++ and a Windows SDK, LLVM Clang 20.1.8, CMake 3.25 or later, Ninja, and Git on PATH. The release used Clang 20.1.8, CMake 4.4.4, Release configuration, and `-march=x86-64-v2`. LLVM must include `clang`, `clang++`, and `lld-link`. No dependency download or game import is needed.

Extract the companion ZIP to a short local folder named `Skate2Runtime`. In a 64-bit PowerShell window there, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Rebuild-Skate2Runtime.ps1 -Jobs 4 -VerifyOriginal
```

The script makes a fresh `rebuild-...` directory, copies the included sources, configures CMake, and builds only `rexruntime` and `rexgpu-xenos`. It leaves the original archive sources and game installation untouched. Successful outputs are in the new directory's `runtime-output` folder. `rebuild-result.json`, `configure.log`, and `build.log` record the result. Compiler logs may contain your own local paths; they are local diagnostics, not release files.

Optional parameters: `-LLVMDirectory`, `-CMakeDirectory`, and `-NinjaDirectory` name tool directories containing their executables; `-VisualStudioPath` names a VS 2022 installation; `-OutputDirectory` names a fresh directory with an existing parent. Four parallel jobs is the tested default.

To change a library, edit its source under `sdk-source/` and rerun without `-VerifyOriginal`. The default rebuild accepts modified contents of the manifest's source files. To add a new file, add its relative path under `sdk-source/` to the `Files` array in `SOURCE-MANIFEST.json` (and update CMake if required); use the same `Path`, `Bytes`, `SHA256`, and `GitMode` fields as neighboring entries. Hashes are enforced only with `-VerifyOriginal`. All inputs must remain ordinary files inside the companion directory.

## Replace the runtime

Close the game. Make a separate copy of your installed game folder and back up its two runtime DLLs. Copy the newly built `runtime-output/rexruntime.dll` and `runtime-output/rexgpu-xenos.dll` beside `skate2.exe` in that copy. Keep the other runtime files supplied with the player package. Launch that copy normally. No executable signature check is added by this project to prevent replacement.

Before replacement, compare the original DLLs with the rebuilt DLLs (LLVM's `llvm-readobj` must be on PATH):

```powershell
.\scripts\Test-Skate2RuntimeABI.ps1 -ReferenceDirectory '..\Skate2PC' -RebuiltDirectory '.\rebuild-...\runtime-output' -ApplicationPath '..\Skate2PC\skate2.exe' -ReportPath '.\runtime-interface-check.json'
```

Changes to the public C++ ABI can require rebuilding the application too. Keep the public API and exported names compatible when rebuilding only these DLLs. The companion validation compares the unmodified rebuild's exports against the released DLLs; that does not validate arbitrary changes or promise that every modified library will preserve gameplay behavior.

## Exact build scope

The recipe enables D3D12 and release performance counters. Vulkan, FidelityFX, Tracy, and the upstream test suite are disabled, matching this Windows runtime. It preserves the SDK's shader-library dependency and embedded shader/font sources. Full selected FFmpeg and libmspack source trees, their license files, FFmpeg platform configuration, and the SDK's codec-list overlays are included. FFmpeg's selected configuration has GPL, nonfree, and version-3-only options disabled.

Two archive-only CMake preparations are made in the temporary copy: the Git-submodule `.git` check is gated off after the manifest's source files have been copied, and the version resolver is given the shipped `0.10.0` version because the archive has no Git history. The original archived CMake files remain unchanged. These adaptations do not change runtime behavior. Build timestamps, toolchain versions, and debug paths can change binary hashes, so byte-for-byte reproducibility is not claimed.

Upstream development tools, prebuilt GLFW example libraries, disabled backend dependencies, and SIMDe's nested unit-test harness are omitted and listed in the manifest. Windows Git's ordinary-text representations of upstream symbolic links are preserved and identified by `GitMode`; the tested Windows build uses real source locations.

## Licenses and attribution

Individual source files retain their original licenses. The root MIT license applies to newly authored port scripts/documentation, not to ReXGlue, Xenia, FFmpeg, libmspack, or other dependencies. Their notices appear in `licenses/` and in the source trees. This software is based in part on the work of the Independent JPEG Group. The DXBC checksum implementation is derived from the RSA Data Security, Inc. MD5 Message Digest Algorithm.

This companion supplies source and a DLL relink path; it does not include game content, generated game functions, personal saves, or the prebuilt Microsoft toolchain. Use the matching player download for the tested playable build.

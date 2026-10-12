# Build from source

These instructions build the Windows x64 version, including its patched ReXGlue runtime. A fresh SDK build, game-code generation, and application compilation have completed in an isolated directory on the development PC. Running the resulting build on a clean Windows installation remains a separate validation step.

**Only looking to play?** Use the compiled Windows ZIP and [installation guide](INSTALL.md). This build guide is for contributors.

## 1. Install the build tools

Install the following before cloning the project:

| Tool | Required setup | Version used for build verification |
| --- | --- | --- |
| [Git for Windows](https://git-scm.com/install/windows) | Enable Git on PATH | Git for Windows |
| [Visual Studio 2022 or Build Tools 2022](https://learn.microsoft.com/en-us/visualstudio/releases/2022/release-history) | **Desktop development with C++**, MSVC x64/x86 build tools, and a Windows SDK | Visual Studio 2022 toolchain; Windows SDK 10.0.26100.0 |
| [LLVM](https://github.com/llvm/llvm-project/releases/tag/llvmorg-20.1.8) | Windows x64 tools, including `clang` and `clang++`; LLVM 20 or later | 20.1.8 |
| [CMake](https://github.com/Kitware/CMake/releases/tag/v4.4.4) | Windows x64; version 3.25 or later | 4.4.4 |
| [Ninja](https://github.com/ninja-build/ninja/releases/tag/v1.13.2) | Windows x64 executable | 1.13.2 |

Add the LLVM and CMake `bin` directories and the folder containing `ninja.exe` to PATH. The scripts discover Visual Studio 2022 automatically through `vswhere`. Visual Studio Code alone does not provide the required toolchain.

Open a new **64-bit Windows PowerShell** window after installing the tools. Verify that these commands print version information:

```powershell
git --version
clang --version
clang++ --version
cmake --version
ninja --version
```

Internet access is needed to fetch the SDK and dependencies. Allow space for the imported game, SDK sources, generated code, and build outputs. Peak build memory and storage requirements have not been benchmarked; the default build uses four parallel jobs.

## 2. Get the source

In Windows PowerShell, change to the folder where you keep projects, then run:

```powershell
git clone https://github.com/christianortel/skate2-recompile-pc.git
cd skate2-recompile-pc
```

Run the remaining commands from this repository root, where `README.md` and the CMD launchers are located.

## 3. Download the pinned SDK

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Bootstrap-Skate2Sdk.ps1
```

This fetches ReXGlue v0.10.0 at commit `f5337cdc947ff6d4c4196737e2c807a48f2a1fc2` and the pinned dependencies needed for the Windows build.

The commands use an execution-policy setting limited to each child process. They do not change user or machine policy. Organization-enforced restrictions can still prevent script execution.

## 4. Import the game files

Double-click **Import Game Files.cmd** in the repository root. Select your extracted folder containing `default.xex` and `data`. See the [supported revision and folder layout](INSTALL.md#supported-game-version).

Wait for **Game files imported and verified** before continuing. If `game` already contains a completed import, skip this step. The importer does not overwrite it or extract an ISO/archive.

## 5. Compile

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Skate2.ps1 -Stage All -Jobs 4
```

This applies the SDK patches, builds and installs the runtime, translates the supported executable into C++, and builds `skate2.exe`. Stop if a step returns an error; logs are written under `reports`.

To match the timing-enabled development build, add `-PerformanceCounters`. This enables frame-capture counters in Release; it does not change the launcher's graphics profile. Builds without it omit those counters.

## 6. Launch

Open **Launch Skate 2.cmd** from the repository root. It selects 2× quality and unlimited FPS with the graphics synchronization settings. Use **Launch Skate 2 - 1x Performance.cmd** for lower GPU load.

The executable and runtime DLLs are built under `skate2/out/build/win-amd64-release`. Saves, cache, and settings are stored under `skate2/`. See [Installation and controls](INSTALL.md#settings-and-controls).

## Rebuilding

For application-only changes, rerun with `-Stage Build`. After manifest or generator changes, run `-Stage Generate`, then `-Stage Build`. After SDK changes, run `-Stage SDK`, followed by generation and application build. Preserve the same `-PerformanceCounters` choice when rebuilding the SDK.

Use a lower `-Jobs` value if compilation exhausts available memory. For nonstandard tool locations, `tools/Enter-BuildEnvironment.ps1` accepts explicit Visual Studio, LLVM, CMake, and Ninja directories.

## Maintainer tools

Run these from the repository root in Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Collect-Skate2Notices.ps1 -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Package-Skate2.ps1 -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Package-Skate2.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Export-Skate2Source.ps1 -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Export-Skate2Source.ps1
```

Packaging writes a new folder under `packages`, verifies native dependencies and collected notices, and excludes game files and existing personal data by default. Add `-ReleaseVersion 0.1.0` to stage a versioned player package. Release packages exclude Microsoft CRT DLLs and require the official x64 runtime to be installed separately. `-CrtDirectory` is for local development packages only. `-BuildDirectory` can select an isolated application build whose runtime DLLs match this checkout's installed SDK.

Source export writes an explicit allowlist to a new folder under `source-exports`. Original game files, generated game code, binaries, tools, logs, saves, and caches are excluded. `-IncludeGameData` on the packager is for local testing only; packages created with it must not be uploaded.

Complete the [release checklist](RELEASE_CHECKLIST.md) before publishing a player package.

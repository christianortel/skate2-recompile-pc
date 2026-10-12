# Build from source

This guide describes the Windows workflow. Fresh game-code generation and application compilation/linking have passed in an isolated export directory on the development PC using a copied, prebuilt SDK install. Separately, bootstrap and a fresh patched SDK build/install passed in another isolated directory on the same PC. Building the application against that fresh SDK is still being checked; installation on another PC remains unverified.

## Prerequisites

Install Git for Windows, Visual Studio 2022 Build Tools with Desktop development with C++ and a Windows SDK, LLVM 20, CMake, and Ninja. Put LLVM/CMake/Ninja on PATH. The working development versions were LLVM 20.1.8, CMake 4.4.4, Ninja 1.13.2, and Windows SDK 10.0.26100.0. Use a 64-bit PowerShell session.

The build environment discovers Visual Studio using `vswhere`. `tools/Enter-BuildEnvironment.ps1` also accepts explicit tool directories for nonstandard installations. Dependencies require network access during initial setup/build; disk and memory requirements are not yet characterized. Four parallel jobs are the default.

## Commands

Run these from the source repository root:

```powershell
.\scripts\Bootstrap-Skate2Sdk.ps1
.\scripts\Import-Skate2Data.ps1 -SourceDirectory '<your extracted Skate 2 folder>'
.\scripts\Build-Skate2.ps1 -Stage All -Jobs 4
```

Use your actual extracted game directory. Import refuses an existing `game` folder. If it is already correctly imported, skip that step. Bootstrap fetches official SDK source and pinned submodules, not a prebuilt SDK binary. The SDK revision is `f5337cdc947ff6d4c4196737e2c807a48f2a1fc2` (v0.10.0).

The build verifies `default.xex`, applies the checked-in SDK patches, builds and installs the SDK, generates C++ from the local game executable, then builds the native application. The authored manifest and configuration supply revision-specific indirect-call/function information. Generated C++ stays local and is excluded from source exports.

Stages can be run separately in order: `SDK`, `Generate`, `Build`. SDK builds with `-PerformanceCounters` retain timing counters in Release; rebuild the application afterward. Ordinary builds disable those release counters. Build logs go in `reports`.

Open **Launch Skate 2.cmd** after a successful build. Runtime files are in `skate2/out/build/win-amd64-release`.

## Local packaging and source export

```powershell
.\scripts\Package-Skate2.ps1 -CheckOnly
.\scripts\Package-Skate2.ps1
.\scripts\Export-Skate2Source.ps1 -CheckOnly
.\scripts\Export-Skate2Source.ps1
```

Packaging creates a fresh folder under `packages`, checks x64 native dependencies, and excludes game files by default. It can require `-CrtDirectory` pointing at the installed official x64 CRT redistributable directory. It does not create a public release or establish that third-party binary notices are complete. `-IncludeGameData` is for local use only; never upload such a package.

To package an isolated application build, pass `-BuildDirectory '<application build directory>'`. Its runtime DLLs must match this checkout's installed SDK. Packaging verifies the collected notice files against `licenses/NOTICE-INDEX.json`; `scripts/Collect-Skate2Notices.ps1 -CheckOnly` checks those notices against the local pinned SDK source. The inventory records the remaining source, relinking, and notice review work.

The exporter uses an explicit source allowlist and writes a new folder under `source-exports`. It excludes game inputs, generated code, SDK/tool downloads, logs, recordings, saves, caches, and local configuration. Export checks are an additional review aid, not a reason to upload the development workspace wholesale. See [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) before publication.

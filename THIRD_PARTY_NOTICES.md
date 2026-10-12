# Third-party notices

This project uses [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk) at revision `f5337cdc947ff6d4c4196737e2c807a48f2a1fc2`. Portions derive from [Xenia](https://github.com/xenia-project/xenia). Their notice is included as [ReXGlue-LICENSE.txt](licenses/ReXGlue-LICENSE.txt).

## Dependency notices

The `licenses` directory contains 45 upstream notice files, including selected source-file attributions and embedded font licenses. [NOTICE-INDEX.json](licenses/NOTICE-INDEX.json) records their sources, hashes, and distribution requirements. `scripts/Collect-Skate2Notices.ps1` verifies the collection against local SDK sources and recorded provenance.

This software is based in part on the work of the Independent JPEG Group. The DXBC checksum implementation is derived from the RSA Data Security, Inc. MD5 Message Digest Algorithm.

FFmpeg and libmspack are statically linked into `rexruntime.dll`. The matching **Runtime-Source** ZIP on [Releases](https://github.com/christianortel/skate2-recompile-pc/releases/latest) supplies their source, the containing runtime's source, build configuration, local modifications, and a DLL rebuild/relink procedure. See [Runtime rebuild instructions](docs/RUNTIME_REBUILD.md). Runtime replacement does not require rebuilding the game executable when its public interfaces remain compatible.

The Microsoft Visual C++ runtime is a separately installed prerequisite. The player release does not redistribute Microsoft CRT DLLs or the compiler toolchain.

## License scope

Newly authored port code and documentation use the [MIT license](LICENSE). Dependencies and derived SDK patches retain their applicable upstream terms.

The repository does not include or license the original game, its assets, or generated game-derived code. Players supply their own supported extracted game files. Project attribution and the fan-project notice do not grant redistribution rights to the original game content.

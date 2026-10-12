# Third-party notices

This project uses [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk) at revision `f5337cdc947ff6d4c4196737e2c807a48f2a1fc2`. Portions derive from [Xenia](https://github.com/xenia-project/xenia). Their notice is included as [ReXGlue-LICENSE.txt](licenses/ReXGlue-LICENSE.txt).

## Dependency notices

The `licenses` directory contains 36 collected upstream notice files. [NOTICE-INDEX.json](licenses/NOTICE-INDEX.json) records their sources, hashes, and remaining review items. `scripts/Collect-Skate2Notices.ps1` verifies the collection against local SDK sources and recorded provenance.

This software is based in part on the work of the Independent JPEG Group. The DXBC checksum implementation is derived from the RSA Data Security, Inc. MD5 Message Digest Algorithm.

FFmpeg and libmspack are statically linked into the runtime. Their corresponding source and rebuild/relink materials still need preparation and verification for a binary release. The inventory also tracks outstanding provenance, nested notices, and Microsoft redistributable terms. These items are part of the [release checklist](docs/RELEASE_CHECKLIST.md).

## License scope

Newly authored port code and documentation use the [MIT license](LICENSE). Dependencies and derived SDK patches retain their applicable upstream terms.

The repository does not include or license the original game, its assets, or generated game-derived code. Players supply their own supported extracted game files. Project attribution and the fan-project notice do not grant redistribution rights to the original game content.

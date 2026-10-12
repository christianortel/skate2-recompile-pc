# Third-party notices

This project uses [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk), revision `f5337cdc947ff6d4c4196737e2c807a48f2a1fc2`. Portions derive from Xenia. The source exporter and local packager include the SDK's existing notice as `licenses/ReXGlue-LICENSE.txt`; preserve that notice with the derived patches.

The SDK includes or builds additional dependencies. Their original copyright and license notices remain applicable. The `licenses` directory includes 34 collected upstream notice files, with provenance and exact hashes in [NOTICE-INDEX.json](licenses/NOTICE-INDEX.json). `scripts/Collect-Skate2Notices.ps1` reproduces this collection from the pinned SDK sources. This software is based in part on the work of the Independent JPEG Group. The DXBC checksum implementation is derived from the RSA Data Security, Inc. MD5 Message Digest Algorithm.

The inventory is not a completed binary-release review. FFmpeg and libmspack are statically linked into the inspected runtime; their corresponding source and rebuild/relink materials still need preparation and verification. The index lists remaining provenance, nested-notice, and Microsoft redistributable checks. Do not publish a binary release until these are resolved.

Newly authored port code and documentation use the MIT license in `LICENSE`. Third-party code and derived SDK patches retain their applicable upstream terms. No license for the original game or generated game-derived code is granted by these files. The source export excludes the original game, assets, and generated recompiled game code. Users provide their own supported extracted game files.

This is an independent fan project. This project is not endorsed by or affiliated with EA or its licensors. Skate 2 and its original game content belong to their respective rights holders; this project takes no credit for the original game. This statement does not grant permission to redistribute game files.

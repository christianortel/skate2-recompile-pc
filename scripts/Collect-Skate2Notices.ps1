[CmdletBinding()]
param(
    [string]$SdkSource,
    [switch]$CheckOnly
)

# Collect only reviewed notice files/comment blocks. This is an inventory aid,
# not a declaration that a binary distribution meets every license obligation.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$workspace = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (-not $SdkSource) { $SdkSource = Join-Path $workspace 'tools/rexglue-sdk-source' }
$sdk = [IO.Path]::GetFullPath($SdkSource)
$licenseRoot = Join-Path $workspace 'licenses'
$reportPath = Join-Path $workspace 'reports/runtime-notice-audit.json'
$byteEncoding = [Text.Encoding]::GetEncoding(28591)
$utf8 = New-Object Text.UTF8Encoding($false)

function Assert-OrdinaryPath([string]$Path, [string]$Root, [switch]$File) {
    $absolute = [IO.Path]::GetFullPath($Path)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($absolute -ne $base -and -not $absolute.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes its permitted root: $Path"
    }
    $cursor = $absolute
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point is not permitted: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    if ($File -and -not (Test-Path -LiteralPath $absolute -PathType Leaf)) { throw "Missing ordinary source file: $absolute" }
    return $absolute
}

function Get-BytesHash([byte[]]$Bytes) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash($Bytes))).Replace('-', '') }
    finally { $hasher.Dispose() }
}

$firstComment = '\A/\*[\s\S]*?\*/'
$commentPrefix = '\A(?:(?://[^\r\n]*(?:\r\n|\n|\r|$))|(?:/\*[\s\S]*?\*/)|\s)+'
$stbLicense = '/\*\s*-+\s*This software is available under 2 licenses[\s\S]*?\*/'
$specs = New-Object 'System.Collections.Generic.List[object]'
function Add-Notice($Component, $Source, $Output, $Terms, $Integration, $Pattern = '') {
    $specs.Add([pscustomobject]@{ Component=$Component; Source=$Source; Output=$Output; Terms=$Terms; Integration=$Integration; Pattern=$Pattern })
}

Add-Notice 'ReXGlue and Xenia' 'LICENSE' 'ReXGlue-LICENSE.txt' 'BSD-3-Clause' 'Runtime DLL and GPU plugin'
Add-Notice 'SDL3' 'thirdparty/sdl3/LICENSE.txt' 'SDL3-LICENSE.txt' 'Zlib' 'Static library linked into rexruntime and the application'
Add-Notice 'SDL3 yuv2rgb' 'thirdparty/sdl3/src/video/yuv2rgb/LICENSE' 'SDL3-yuv2rgb-LICENSE.txt' 'BSD-3-Clause; Copyright (c) 2016 Adrien Descamps' 'Selected SDL generic/SSE video conversion inputs in the static library'
Add-Notice 'HIDAPI' 'thirdparty/sdl3/src/hidapi/LICENSE.txt' 'HIDAPI-license-options.txt' 'Upstream alternative-license explanation' 'SDL3 HID controller support'
Add-Notice 'HIDAPI' 'thirdparty/sdl3/src/hidapi/LICENSE-bsd.txt' 'HIDAPI-BSD-LICENSE.txt' 'BSD-style option retained' 'SDL3 HID controller support'
Add-Notice 'HIDAPI Windows' 'thirdparty/sdl3/src/hidapi/windows/hid.c' 'HIDAPI-Windows-NOTICE.txt' 'Copyright and alternative-license notice' 'SDL3 HID controller support' $firstComment
Add-Notice 'fmt' 'thirdparty/fmt/LICENSE' 'fmt-LICENSE.txt' 'MIT' 'Static formatting library'
Add-Notice 'spdlog' 'thirdparty/spdlog/LICENSE' 'spdlog-LICENSE.txt' 'MIT and included third-party notices' 'Static logging library'
Add-Notice 'xxHash' 'thirdparty/xxHash/LICENSE' 'xxHash-LICENSE.txt' 'BSD-2-Clause' 'Static hash library'
Add-Notice 'aes_128' 'thirdparty/aes_128/LICENSE' 'aes128-LICENSE.txt' 'MIT' 'Static library for kernel crypto routines'
Add-Notice 'aes_128 source attribution' 'thirdparty/aes_128/aes.c' 'aes128-NOTICE.txt' 'Chinese Academy of Sciences source copyright; MIT terms in aes128-LICENSE.txt' 'Static library for kernel crypto routines' $firstComment
Add-Notice 'o1heap' 'thirdparty/o1heap/LICENSE' 'o1heap-LICENSE.txt' 'MIT' 'Static kernel heap allocator'
Add-Notice 'SIMDe' 'thirdparty/simde/COPYING' 'SIMDe-COPYING.txt' 'MIT and included notices' 'SIMD headers used by runtime and generated application'
Add-Notice 'toml++' 'thirdparty/tomlplusplus/LICENSE' 'tomlplusplus-LICENSE.txt' 'MIT' 'Configuration parsing headers'
Add-Notice 'CLI11' 'thirdparty/cli11/LICENSE' 'CLI11-LICENSE.txt' 'BSD-3-Clause' 'Runtime cvar argument parsing headers'
Add-Notice 'UTF8-CPP' 'thirdparty/utfcpp/LICENSE' 'UTF8CPP-LICENSE.txt' 'Boost-1.0' 'Runtime text conversion headers'
Add-Notice 'Dear ImGui' 'thirdparty/imgui/LICENSE.txt' 'ImGui-LICENSE.txt' 'MIT' 'UI object files linked into rexruntime'
Add-Notice 'ImGui stb_rectpack' 'thirdparty/imgui/imstb_rectpack.h' 'ImGui-stb_rectpack-LICENSE.txt' 'MIT or public-domain alternatives' 'ImGui internal font packing' $stbLicense
Add-Notice 'ImGui stb_truetype' 'thirdparty/imgui/imstb_truetype.h' 'ImGui-stb_truetype-LICENSE.txt' 'MIT or public-domain alternatives' 'ImGui font rasterization' $stbLicense
Add-Notice 'ImGui stb_textedit' 'thirdparty/imgui/imstb_textedit.h' 'ImGui-stb_textedit-LICENSE.txt' 'MIT or public-domain alternatives' 'ImGui text editing' $stbLicense
Add-Notice 'stb_image' 'thirdparty/stb/stb_image.h' 'stb_image-LICENSE.txt' 'MIT or public-domain alternatives' 'Runtime image_decode.cpp' $stbLicense
Add-Notice 'RenderDoc API' 'thirdparty/renderdoc/renderdoc_app.h' 'RenderDoc-API-LICENSE.txt' 'MIT' 'API header; RenderDoc DLL is not bundled' $firstComment
Add-Notice 'DXC API headers' 'thirdparty/dxc/include/dxcapi.h' 'DXC-dxcapi-NOTICE.txt' 'Header notice; full pinned upstream terms in DXC-LICENSE.txt' 'D3D12 runtime API declarations' $commentPrefix
Add-Notice 'DXC converter header' 'thirdparty/dxc/include/DxbcConverter.h' 'DXC-DxbcConverter-NOTICE.txt' 'Header notice; full pinned upstream terms in DXC-LICENSE.txt' 'D3D12 runtime API declarations' $commentPrefix
Add-Notice 'libmspack' 'thirdparty/libmspack/libmspack/COPYING.LIB' 'libmspack-COPYING.LIB.txt' 'LGPL-2.1' 'lzxd.c static library linked into rexruntime'
Add-Notice 'libmspack LZX' 'thirdparty/libmspack/libmspack/mspack/lzxd.c' 'libmspack-LZX-NOTICE.txt' 'LGPL-2.1 copyright notice' 'lzxd.c static library linked into rexruntime' $firstComment
Add-Notice 'FFmpeg' 'thirdparty/FFmpeg/COPYING.LGPLv2.1' 'FFmpeg-COPYING.LGPLv2.1.txt' 'LGPL-2.1-or-later under inspected configuration' 'libavcodec and libavutil static libraries'
Add-Notice 'FFmpeg' 'thirdparty/FFmpeg/LICENSE.md' 'FFmpeg-LICENSE.md' 'Upstream licensing overview; optional licenses are not all enabled' 'libavcodec and libavutil static libraries'
Add-Notice 'FFmpeg IJG fast DCT' 'thirdparty/FFmpeg/libavcodec/jfdctfst.c' 'FFmpeg-IJG-jfdctfst-NOTICE.txt' 'Independent JPEG Group terms' 'Selected FFmpeg codec source' $firstComment
Add-Notice 'FFmpeg IJG integer DCT' 'thirdparty/FFmpeg/libavcodec/jfdctint_template.c' 'FFmpeg-IJG-jfdctint-NOTICE.txt' 'Independent JPEG Group terms' 'Included by selected jfdctint.c source' $firstComment
Add-Notice 'FFmpeg IJG inverse DCT' 'thirdparty/FFmpeg/libavcodec/jrevdct.c' 'FFmpeg-IJG-jrevdct-NOTICE.txt' 'Independent JPEG Group terms' 'Selected FFmpeg codec source' $firstComment
Add-Notice 'FFmpeg avsscanf' 'thirdparty/FFmpeg/libavutil/avsscanf.c' 'FFmpeg-avsscanf-LICENSE.txt' 'MIT; Copyright (c) 2005-2014 Rich Felker, et al.' 'Selected libavutil source statically linked into rexruntime' $firstComment
Add-Notice 'Crypto DES' 'thirdparty/crypto/des/LICENSE' 'Crypto-DES-LICENSE.txt' 'MIT' 'Included directly by xboxkrnl_crypt.cpp'
Add-Notice 'TinySHA1' 'thirdparty/crypto/TinySHA1.hpp' 'TinySHA1-LICENSE.txt' 'ISC-style notice' 'Included by kernel crypto and XEX loader' $firstComment
Add-Notice 'Rijndael AES' 'thirdparty/crypto/rijndael-alg-fst.c' 'Rijndael-NOTICE.txt' 'Public-domain dedication and warranty disclaimer' 'Included directly by xex_module.cpp' $firstComment
Add-Notice 'Crypto SHA256' 'thirdparty/crypto/sha256.cpp' 'SHA256-NOTICE.txt' 'Zlib attribution and Xenia modification notice; full author terms in SHA256-LICENSE.txt' 'Included directly by xboxkrnl_crypt.cpp' $commentPrefix
Add-Notice 'DXBC checksum' 'thirdparty/dxbc/DXBCChecksum.cpp' 'DXBC-Checksum-NOTICE.txt' 'AMD attribution and RSA-MD5 derivative notice' 'Compiled into GPU plugin' $commentPrefix
Add-Notice 'PE format declarations' 'thirdparty/pe/pe_image.h' 'PE-format-NOTICE.txt' 'Microsoft copyright attribution and Xenia modification notice from vendored declarations' 'Included by the XEX module loader; structure and constant declarations' $commentPrefix

# These complete upstream notices are absent from the vendored SDK directories.
# Their exact bytes are checked into this source tree. Collection and CheckOnly
# validate the pinned copies and corresponding SDK headers entirely offline.
$pinnedNotices = @(
    [pscustomobject]@{
        Component='Crypto SHA256'; Output='SHA256-LICENSE.txt'; Terms='Zlib; Copyright (c) 2014,2015 Stephan Brumme'
        Integration='Full author license paired with the identical original SHA256 source blobs; retain SHA256-NOTICE.txt for the Xenia alteration notice'
        Uri='https://raw.githubusercontent.com/stbrumme/hash-library/a8a88f8acbdd97b854b6ac61e53177dc7870f32f/LICENSE'
        Revision='a8a88f8acbdd97b854b6ac61e53177dc7870f32f'
        Bytes=861; SHA256='FDB325DF119BF7F4F5718F56C60B05590D82C1A335661A3C9E77CC8C4BAC38D4'
        Provenance='Full author Zlib license published in 2018 alongside original sha256.cpp blob 0c6138cd862f81b5b4cd22237aee87afff3c139f and sha256.h blob aeaf314fbf662412a0ae2f005fbe10ea57ce3095, unchanged from matching releases v6/v7. Xenia imported this implementation at fb87b7a3c3eacf5edf2aac4e74a473fc55a6ffaf with namespace/accessor changes; ReXGlue additionally has Apple endian compatibility and formatting changes. This records a verified 2018 source/license pairing, not a recovered 2016 website disclaimer.'
        SourceFiles=[ordered]@{
            'thirdparty/crypto/sha256.cpp'='16065F6AD1228F7D35A4023DA2AB3E59DC7B2A677401C87A00A1333BCC4A462F'
            'thirdparty/crypto/sha256.h'='1D1C6A178AD51B929AC83D6C5637FEB9A5F8CC19C79CA7C5C5EC19D4460D7FEC'
        }
    },
    [pscustomobject]@{
        Component='DXC API headers'; Output='DXC-LICENSE.txt'; Terms='University of Illinois/NCSA Open Source License'
        Integration='Full top-level upstream license for the two vendored DXC API headers; retain their separate Microsoft notices'
        Uri='https://raw.githubusercontent.com/microsoft/DirectXShaderCompiler/6b6f40200bea5ed99367513f53f6a28e52fd3d0e/LICENSE.TXT'
        Revision='6b6f40200bea5ed99367513f53f6a28e52fd3d0e'
        Bytes=3281; SHA256='721CB11DE618FCF9BBB7D25A389207BF2227357E6694BC326AB32A6699F9B951'
        Provenance='Both vendored headers match byte-for-byte at the exact revision recorded by the SDK README.'
        SourceFiles=[ordered]@{
            'thirdparty/dxc/include/dxcapi.h'='7B4E2D7BBF0FC3DB84EAC717846F9BF6686B7E231CB4F7BCDE077390CCA7FD78'
            'thirdparty/dxc/include/DxbcConverter.h'='40D1A4F604CFA0E12AB17D234980ECFCF79F6232B85D5B6643C0D1DEB5B2F4BE'
        }
    },
    [pscustomobject]@{
        Component='disruptorplus'; Output='disruptorplus-LICENSE.txt'; Terms='MIT; Copyright (c) 2013 Lewis Baker'
        Integration='Header-only queue linked through rexcore into the runtime'
        Uri='https://raw.githubusercontent.com/xenia-project/disruptorplus/5787e9cb7551c8c79cf9ce14f7be860dc907e9a4/LICENSE.txt'
        Revision='5787e9cb7551c8c79cf9ce14f7be860dc907e9a4'
        Bytes=1077; SHA256='A56F05C0DBD9489E928FD3CA22712F90B310FE749CEEF47059E895F6A235100C'
        Provenance='Content match to the Xenia fork of lewissbaker/disruptorplus: ten headers are byte-identical; multi_threaded_claim_strategy.hpp differs only by the existing SDK cast from sequence_t to size_t in reducedCount = std::min(count, ...). The complete license also matches the original upstream. This identifies a reproducible source base, not a historical acquisition date.'
        SourceFiles=[ordered]@{
            'thirdparty/disruptorplus/include/disruptorplus/blocking_wait_strategy.hpp'='B371BC0BD95DCC4ACB8849DF43D4A516C219BFDCA6D86218360FCB98AE83AAA7'
            'thirdparty/disruptorplus/include/disruptorplus/config.hpp'='558177EDC0F0F341AAF871464A9C4E1FDD3929F8612E51CEFE074CC8640F06A5'
            'thirdparty/disruptorplus/include/disruptorplus/multi_threaded_claim_strategy.hpp'='37C30D89939D9B2871C3090C64832324E42A01335F625EDBE16D65A193BF2079'
            'thirdparty/disruptorplus/include/disruptorplus/ring_buffer.hpp'='F80C4F206A45691131E77D36BFBDCDCCCBCD5F8194338CFFFA83A4F2BA3B0AAB'
            'thirdparty/disruptorplus/include/disruptorplus/sequence_barrier_group.hpp'='424CA9697BF28B9EA5DEA9F349F53DE805FC9319AEA5E8889E38ED653087B7B3'
            'thirdparty/disruptorplus/include/disruptorplus/sequence_barrier.hpp'='CB52DEBA21AFE52CD523140A7FAB2622847EF79098BC0909D9C6EF4E07AC9989'
            'thirdparty/disruptorplus/include/disruptorplus/sequence_range.hpp'='1F8172B146B4AC84E1827FE59EF6AD0325735788C554FAB60BFE419225538D74'
            'thirdparty/disruptorplus/include/disruptorplus/sequence.hpp'='A777CB4E8253F2C1437E1D3AD892948D2ED79A2B33A47482452BE0DAAD90C556'
            'thirdparty/disruptorplus/include/disruptorplus/single_threaded_claim_strategy.hpp'='B9C255C06438966F9154C492BA5199A960616E6B34DFC6914F9EBFBC7BCD8162'
            'thirdparty/disruptorplus/include/disruptorplus/spin_wait_strategy.hpp'='41D2AF942DAE50D7E21CD206D90DC2D210CE598B749A742A905B26961EA5D873'
            'thirdparty/disruptorplus/include/disruptorplus/spin_wait.hpp'='4C20E01D88E9999B71F1BE5DEC75A77F766A4F5A7EF9949C7E1FA7DF80C94D42'
        }
    }
)

# Exact reviewed notice aggregates; source inputs are pinned and validated offline.
$pinnedNotices += @(
    [pscustomobject]@{
        Component='FFmpeg selected source notices'; Output='FFmpeg-Selected-Source-NOTICES.txt'; Terms='MIPS BSD-style terms, Zlib, LGPL and a preserved Boost source-header notice'
        Integration='Selected FFmpeg libavcodec/libavutil source and header inputs; linked statically into rexruntime'
        Uri='SDK source excerpts listed in VerifiedSdkSources'
        Revision='f5337cdc947ff6d4c4196737e2c807a48f2a1fc2'
        Bytes=22976; SHA256='47185F1254FEF574E14E53BBD9D2B971D60DD78216A44EE26C9A7B04847611C4'
        Provenance='11 exact embedded notices identified from 161 valid Windows Release compiler dependency records covering 394 FFmpeg inputs. Source offsets appear in the notice file. The Boost erf fallback in libm.h is guarded out by HAVE_ERF=1 and is retained as source-header notice evidence. SHA source blocks preserve the upstream LGPL terms and historical attribution references without reconstructing earlier terms. Compiler inclusion does not establish final function retention.'
        Extraction='Exact source notice bytes with source/offset labels; checked-in aggregation verified offline'
        SourceFiles=[ordered]@{
            'thirdparty/FFmpeg/libavcodec/fft_fixed_32.c'='CC2ADF3556414C517EBE9B216C55ABBFC23B4AB93C19A7270EBA77FCA0DFD5D6'
            'thirdparty/FFmpeg/libavcodec/fft_init_table.c'='FA57CCC24309733B8D2F5CC2A7F196A2E3FB72046496E5A97485987459AFA8D0'
            'thirdparty/FFmpeg/libavcodec/fft_table.h'='57A452AA8F8C31AAD9D5C2B778E6C1E21EC2F5B9E6FBF15136002D6A738FA6A2'
            'thirdparty/FFmpeg/libavcodec/mdct_fixed_32.c'='72E59C30981EDD416E4F0E4FEC211B4702988D4D44D2A922D598DE7C07200FF9'
            'thirdparty/FFmpeg/libavutil/fixed_dsp.c'='083F2BDDAA0216570BD0AD92D137D7FC679D61749FACDB495A809228D28AEAE2'
            'thirdparty/FFmpeg/libavutil/fixed_dsp.h'='AE85FEBB76566FFB259D1FDF9EFF410AEACB66251744436D8324F2493F322E2A'
            'thirdparty/FFmpeg/libavutil/softfloat_tables.h'='FDB03BBDBBB62FA2DD909CFB02B64E9D16F48D0BE68E2642C9B9944E21BF55F6'
            'thirdparty/FFmpeg/libavutil/adler32.c'='BFBC567FD3D4C0D8DCB1337B15676E97D0622AC98672373ECB8AC4C1CB54E64A'
            'thirdparty/FFmpeg/libavutil/sha.c'='861ADD6AB222306AF486BAFF7F75DF597E4176E82FB1E80FD2C8D845A27DE0EB'
            'thirdparty/FFmpeg/libavutil/sha512.c'='371B0818E39B18C2835BAEFAE67B1188E2BFB59832F6A47A5345ADDEF80D15E9'
            'thirdparty/FFmpeg/libavutil/libm.h'='6430C571289D7F261853FDD0D97AB2944A751B013A61BFD10DD0E2AFD8BE2A46'
        }
    },
    [pscustomobject]@{
        Component='SIMDe selected headers'; Output='SIMDe-Selected-Header-NOTICES.txt'; Terms='MIT and CC0/public-domain notices with individual source attributions'
        Integration='Selected Windows Release source/header inputs; compiler inclusion does not imply every function survives final linking'
        Uri='SDK source excerpts listed in VerifiedSdkSources'
        Revision='f5337cdc947ff6d4c4196737e2c807a48f2a1fc2'
        Bytes=26733; SHA256='7AA83B8891D467917493A887F1A9D0AE15349BA25466E6AE0F2CDB6EC69DE333'
        Provenance='22 exact notice excerpts from 21 headers in the actual Windows Release application PCH dependencies, with source-byte offsets in the notice file. The runtime PCH includes a subset of these headers. Individual source hashes are validated offline; this preserves source attributions without claiming every helper survives final linking.'
        Extraction='Exact source notice bytes with source/offset labels; checked-in aggregation verified offline'
        SourceFiles=[ordered]@{
            'thirdparty/simde/simde/check.h'='4B70C63067FBF7578F39F551CE5ADA78D2F758FC7981942BE55336F17FADD888'
            'thirdparty/simde/simde/debug-trap.h'='938B56921A20042D65F965A4D5C9ABC359611C7BA5338C2EBA915747F7BCB86C'
            'thirdparty/simde/simde/hedley.h'='D9DC9E52C6AA8E68877657B61EFD75F034868AE3D41B8C24EB6E41634ED4A4AB'
            'thirdparty/simde/simde/simde-align.h'='1BC7AB9D25CE395DF5572698945BD72BF697F5BD8CDC92844A5A3ACC0D4F3358'
            'thirdparty/simde/simde/simde-arch.h'='37889CF9F468B99C8291F3FD35CF6E2EAE17B6F58EACE2CDA3DEA1D17A8BAED0'
            'thirdparty/simde/simde/simde-common.h'='40CFF500556187164672FDE92AA4B21F3CCC886713A224B8B6E66931C76C511F'
            'thirdparty/simde/simde/simde-constify.h'='277A699C785C78679D78946BAD5C3E0629A1BD9CCC18A28E6DDA2E7243BBD511'
            'thirdparty/simde/simde/simde-detect-clang.h'='910723EADC7D6723BAD32D1EE63B0A5A3B97AEE0C02E67064B99F695A0B59509'
            'thirdparty/simde/simde/simde-diagnostic.h'='44D15BD2E8072B259480EFF53C1ED21D699EFC495915ED5B3E30F4F00DF9D797'
            'thirdparty/simde/simde/simde-f16.h'='29BB566F93ADB2EA85C84C0E6C39E133BE168358D90E4F80187C18B9F7D14F96'
            'thirdparty/simde/simde/simde-features.h'='B27899C1614C79115B7F6442535528A1718E62D971C6BF54E8B79DF3D85302B0'
            'thirdparty/simde/simde/simde-math.h'='EAA4F97FB91C073421947E1FE4C92DE45EC0AB9C6A42C0206473FF99FDAD5265'
            'thirdparty/simde/simde/x86/avx.h'='4E3ACCE1FC5393CE275D0247A43399F02AC85A9809AA9842F10828EF49FD3E65'
            'thirdparty/simde/simde/x86/avx2.h'='CEF4099FC9EE24E45B0D8DB04F99E2CE02EBA7BB9D1A0C9FFDCB2EBEDE5B89B9'
            'thirdparty/simde/simde/x86/mmx.h'='822371F2457B4DFCD925EBF212973774C109DD5A61DCDF62B5C41B1458B1B870'
            'thirdparty/simde/simde/x86/sse.h'='FAE6D38BE37319192E28B8846B8D46C99B00F1C1985B86A96048D9BC4C7BB1C1'
            'thirdparty/simde/simde/x86/sse2.h'='E7D37AECC2C4A958590B815C5213B75C4C848B293C19FD2DE7903B4A49B44BFD'
            'thirdparty/simde/simde/x86/sse3.h'='281EE5DD36F396C70894263A2FA27226BEFDB6A354196DD6CAE68B49928B78C4'
            'thirdparty/simde/simde/x86/sse4.1.h'='042EAB1C508917ACD57442AC8E52733FACE2D5F43A0E39BF06653B927BFE40A3'
            'thirdparty/simde/simde/x86/sse4.2.h'='BF338DF68A001F3CCA74B32146F7254FEBABE819DAAA41BCEBFD8510AF4C2EE4'
            'thirdparty/simde/simde/x86/ssse3.h'='8E62D0ADE6065A0DE6DE14FF4A8075DC8A90DB6D73B3CCA2FEF78A6597D46B5D'
        }
    },
    [pscustomobject]@{
        Component='SDL3 selected source notices'; Output='SDL3-Selected-Source-NOTICES.txt'; Terms='Zlib, SunPro permissive, and public-domain notices with individual source attributions'
        Integration='Selected Windows Release source/header inputs; compiler inclusion does not imply every function survives final linking'
        Uri='SDK source excerpts listed in VerifiedSdkSources'
        Revision='f5337cdc947ff6d4c4196737e2c807a48f2a1fc2'
        Bytes=13103; SHA256='E2E1A9A49EE6E27CBFB1EF4129974C64F17825E58D2E6D35BE482E8A2843D48D'
        Provenance='15 exact notice excerpts from reviewed Windows Release inputs, with source-byte offsets in the notice file. Individual source hashes are validated offline. Compiled SDL libm fallback inputs are included conservatively; their final function-level retention was not established.'
        Extraction='Exact source notice bytes with source/offset labels; checked-in aggregation verified offline'
        SourceFiles=[ordered]@{
            'thirdparty/sdl3/src/libm/e_atan2.c'='E1F2A4CC236611105D201F8B609EB9FECE1EE4271845E9D8E1644DE5FAB15635'
            'thirdparty/sdl3/src/libm/s_isnanf.c'='CCCB8E2D09A992ADCDE4F98EB52CD2A521EAB5AE2624C3CEF31099F9FECD896D'
            'thirdparty/sdl3/src/libm/s_isinf.c'='5525B9FFF8EC00249831EBB840BEEBAFE73FE40DEC0D28AA855269E25CC20B7C'
            'thirdparty/sdl3/src/libm/s_isinff.c'='1E88FB7C4E85AE124482951B9E71EC0941CE9D69336223619904A5A46C9B1C9C'
            'thirdparty/sdl3/src/stdlib/SDL_qsort.c'='E1B0DD9821DABCBE55C4FF2EED921AB1B93B7CFF3F7E14EE8FC1908C5827C2FC'
            'thirdparty/sdl3/src/joystick/controller_type.c'='5C6F5932D922F309B9A083C69DF5AAED4F519ADB4FD7FAE379E225D7C1EE6DAA'
            'thirdparty/sdl3/src/video/SDL_rotate.c'='B464978996F966A1A5BE2C5776A96FEC05AE9AC2734424E1FC3A45AFB5344501'
            'thirdparty/sdl3/src/joystick/hidapi/SDL_hidapi_lg4ff.c'='C6D25452127B3EA71FF5DDD07ABDF0E47224C39B00FF7DD29120380ACB3D6EB5'
            'thirdparty/sdl3/src/joystick/hidapi/SDL_hidapi_sinput.c'='04E41F024E00F6F70955E624E51C8562E8EFB83FEF99AAFDFA2BE6ADD295D53D'
            'thirdparty/sdl3/src/joystick/hidapi/SDL_hidapi_steam_triton.c'='E281967F2B06E17607440181764AD2672C595226F118B7DE4DD483331023F1EA'
            'thirdparty/sdl3/src/joystick/hidapi/SDL_hidapi_steamdeck.c'='D78AFF61B9D6033C394B846D7A73411B90F61F18DD9EE6AEDE2E3189E8CE902F'
            'thirdparty/sdl3/src/joystick/hidapi/SDL_hidapi_zuiki.c'='50F7232DB87BA6DC7D9B0863D95BE454A8C3C50654E30297352B6245B1BC2988'
            'thirdparty/sdl3/src/haptic/hidapi/SDL_hidapihaptic.c'='097B4DC61FEE0B2AB1C242FBFABBBDBF1C0B7A34DC2860141FCD0A815E934CF3'
            'thirdparty/sdl3/src/haptic/hidapi/SDL_hidapihaptic_lg4ff.c'='F4C5DD022E7E04F62CCA326249898D085441A18B6F30A968BC441C92C02E14C7'
            'thirdparty/sdl3/src/stdlib/SDL_strtokr.c'='EFCE17F5A209E9D6794690FA6DE79ECFC06521ED46B5B85F9B3D263793259428'
        }
    },
    [pscustomobject]@{
        Component='ProggyTiny and ProggyClean fonts'; Output='ProggyFonts-LICENSE.txt'; Terms='MIT; Copyright (c) 2004, 2005 Tristan Grimmer'
        Integration='ProggyTiny embedded in the ReXGlue UI; ProggyClean embedded by Dear ImGui'
        Uri='https://raw.githubusercontent.com/bluescan/proggyfonts/139ec08a38096161291792313ef5803fc4f0e37b/LICENSE'
        Revision='139ec08a38096161291792313ef5803fc4f0e37b'
        Bytes=1078; SHA256='FE61D069DF303C697E04200F5F8232C2CB09DD3572F4357B323469F7D592D142'
        Provenance='The embedded font arrays decompress with valid checksums to the byte-identical author TTF files at this revision: ProggyTiny git blob 1c4312c3dbaa81babf38bac992e3722e15eedb73; ProggyClean git blob 0270cdfe3caa811e1b252cdcc5b179989c1b8ad6. This notice covers these original Proggy fonts, not other font families.'
        SourceFiles=[ordered]@{
            'thirdparty/imgui/misc/fonts/ProggyTiny.ttf'='79BF8D3896BA83AE2F9C4FA214DCE8FC689EAE47950474947A4CC5C6E14A9BFC'
            'thirdparty/imgui/misc/fonts/ProggyClean.ttf'='527D2A443CE051F93F7E77B855609722B8CB220A9F104B4AA037BE5C90B71324'
        }
    }
)

[void](Assert-OrdinaryPath $sdk $sdk)
[void](Assert-OrdinaryPath $licenseRoot $workspace)
[void](Assert-OrdinaryPath $reportPath $workspace)
$prepared = New-Object 'System.Collections.Generic.List[object]'
$seen = @{}
foreach ($spec in $specs) {
    if ($spec.Output -notmatch '\A[A-Za-z0-9_.-]+\z' -or $seen.ContainsKey($spec.Output)) { throw "Invalid or duplicate notice output: $($spec.Output)" }
    $seen[$spec.Output] = $true
    $source = Assert-OrdinaryPath (Join-Path $sdk $spec.Source) $sdk -File
    $destination = Assert-OrdinaryPath (Join-Path $licenseRoot $spec.Output) $licenseRoot
    [byte[]]$original = [IO.File]::ReadAllBytes($source)
    if ($original.Length -gt 2MB -or $original -contains 0) { throw "Notice input is unexpectedly large or binary: $($spec.Source)" }
    [byte[]]$selected = $original
    $start = 0
    if ($spec.Pattern) {
        # Latin-1 has a one-to-one byte mapping: extraction retains CRLF, spaces,
        # and original encoding bytes without reformatting or appending a newline.
        $matches = [regex]::Matches($byteEncoding.GetString($original), $spec.Pattern)
        if ($matches.Count -ne 1 -or $matches[0].Length -eq 0) { throw "Expected one reviewed notice block: $($spec.Source)" }
        $start = $matches[0].Index
        $selected = $byteEncoding.GetBytes($matches[0].Value)
        if ($byteEncoding.GetString($selected) -notmatch '(?i)copyright|license|public domain') { throw "Selected block lacks license markers: $($spec.Source)" }
    }
    $hash = Get-BytesHash $selected
    if (Test-Path -LiteralPath $destination) {
        [void](Assert-OrdinaryPath $destination $licenseRoot -File)
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $hash) {
            throw "Existing notice differs; review it before replacing: $destination"
        }
    }
    $record = [pscustomobject][ordered]@{
        Component=$spec.Component; Path=('licenses/' + $spec.Output); Terms=$spec.Terms
        Integration=$spec.Integration; Source=$spec.Source
        SourceSHA256=(Get-BytesHash $original); SourceByteOffset=$start
        Extraction=$(if ($spec.Pattern) { 'Exact comment block bytes' } else { 'Entire upstream notice file bytes' })
        Bytes=$selected.Length; SHA256=$hash
    }
    $prepared.Add([pscustomobject]@{ Record=$record; Bytes=$selected; Destination=$destination })
}

foreach ($spec in $pinnedNotices) {
    if ($seen.ContainsKey($spec.Output)) { throw "Duplicate pinned notice output: $($spec.Output)" }
    $seen[$spec.Output] = $true
    $destination = Assert-OrdinaryPath (Join-Path $licenseRoot $spec.Output) $licenseRoot -File
    [byte[]]$bytes = [IO.File]::ReadAllBytes($destination)
    if ($bytes.Length -ne $spec.Bytes -or (Get-BytesHash $bytes) -ne $spec.SHA256) {
        throw "Pinned upstream notice differs: $($spec.Output). Restore the reviewed checked-in bytes."
    }
    $sourceRecords = @(
        foreach ($sourceFile in $spec.SourceFiles.GetEnumerator()) {
            $source = Assert-OrdinaryPath (Join-Path $sdk $sourceFile.Key) $sdk -File
            if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $sourceFile.Value) {
                throw "SDK source differs from pinned notice provenance: $($sourceFile.Key)"
            }
            [pscustomobject]@{ Source=$sourceFile.Key; SHA256=$sourceFile.Value }
        }
    )
    $record = [pscustomobject][ordered]@{
        Component=$spec.Component; Path=('licenses/' + $spec.Output); Terms=$spec.Terms
        Integration=$spec.Integration; Source=$spec.Uri; SourceRevision=$spec.Revision
        SourceSHA256=$(if ($spec.PSObject.Properties['Extraction']) { $null } else { $spec.SHA256 }); SourceByteOffset=0
        Extraction=$(if ($spec.PSObject.Properties['Extraction']) { $spec.Extraction } else { 'Entire immutable upstream notice file; checked-in bytes verified offline' })
        Bytes=$bytes.Length; SHA256=$spec.SHA256; Provenance=$spec.Provenance
        VerifiedSdkSources=$sourceRecords
    }
    $prepared.Add([pscustomobject]@{ Record=$record; Bytes=$bytes; Destination=$destination })
}

# Record current build evidence separately from distributed notice text.
$evidence = New-Object 'System.Collections.Generic.List[object]'
function Read-Evidence([string]$Relative) {
    $path = Assert-OrdinaryPath (Join-Path $sdk $Relative) $sdk -File
    $bytes = [IO.File]::ReadAllBytes($path)
    $evidence.Add([pscustomobject]@{ Source=$Relative; SHA256=(Get-BytesHash $bytes) })
    return $byteEncoding.GetString($bytes)
}
$config = Read-Evidence 'thirdparty/FFmpeg/config_windows_x86_64.h'
$ffmpegFlags = [ordered]@{}
foreach ($flag in @('CONFIG_GPL','CONFIG_NONFREE','CONFIG_VERSION3','CONFIG_GPLV3')) {
    $match = [regex]::Match($config, '(?m)^#define ' + $flag + ' ([01])\r?$')
    if (-not $match.Success) { throw "Cannot verify FFmpeg flag $flag" }
    $ffmpegFlags[$flag] = [int]$match.Groups[1].Value
    if ($ffmpegFlags[$flag] -ne 0) { throw "The curated notices need review for enabled FFmpeg flag $flag" }
}
foreach ($path in @('thirdparty/CMakeLists.txt','src/core/CMakeLists.txt','src/system/CMakeLists.txt','src/kernel/CMakeLists.txt','src/kernel/xboxkrnl/xboxkrnl_crypt.cpp','src/system/xex_module.cpp','src/audio/CMakeLists.txt','src/ui/CMakeLists.txt','src/graphics/CMakeLists.txt','thirdparty/dxc/README.md')) { [void](Read-Evidence $path) }
$links = New-Object 'System.Collections.Generic.List[object]'
$ninjaRelative = 'out/build/win-amd64/CMakeFiles/impl-Release.ninja'
if (Test-Path -LiteralPath (Join-Path $sdk $ninjaRelative)) {
    $ninja = Read-Evidence $ninjaRelative
    foreach ($target in @('rexruntime','rexgpu-xenos')) {
        $block = [regex]::Match($ninja, '(?ms)^build [^\r\n]*?/Release/' + [regex]::Escape($target) + '\.dll [^\r\n]*: CXX_SHARED_LIBRARY_LINKER_[^\r\n]*\r?\n(?:(?!^build ).)*')
        if (-not $block.Success) { throw "Release link evidence not found for $target" }
        $libs = [regex]::Match($block.Value, '(?m)^  LINK_LIBRARIES = ([^\r\n]*)').Groups[1].Value
        $names = @([regex]::Matches($libs, '(?:[^/\\ \x22]+)\.lib') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $links.Add([pscustomobject]@{ Target=$target; Libraries=$names })
    }
}
$buildFlags = [ordered]@{}
$cacheRelative = 'out/build/win-amd64/CMakeCache.txt'
if (Test-Path -LiteralPath (Join-Path $sdk $cacheRelative)) {
    $cache = Read-Evidence $cacheRelative
    foreach ($flag in @('REXGLUE_USE_D3D12','REXGLUE_USE_VULKAN','REXGLUE_ENABLE_FIDELITYFX','REXGLUE_ENABLE_TRACY')) {
        $match = [regex]::Match($cache, '(?m)^' + $flag + ':BOOL=(ON|OFF)\r?$')
        if (-not $match.Success) { throw "Cannot establish SDK build setting: $flag" }
        $buildFlags[$flag] = $match.Groups[1].Value
        $expected = if ($flag -eq 'REXGLUE_USE_D3D12') { 'ON' } else { 'OFF' }
        if ($buildFlags[$flag] -ne $expected) { throw "Notice allowlist needs review for $flag=$($buildFlags[$flag])" }
    }
}
$binaryEvidence = @(
    foreach ($name in @('rexruntime.dll','rexgpu-xenos.dll')) {
        $relative = 'out/win-amd64/Release/' + $name
        $path = Join-Path $sdk $relative
        if (Test-Path -LiteralPath $path) {
            [void](Assert-OrdinaryPath $path $sdk -File)
            [pscustomobject]@{ Source=$relative; Bytes=(Get-Item -LiteralPath $path).Length; SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
        }
    }
)
$distributionRequirements = @(
    [ordered]@{ Component='FFmpeg and libmspack'; Item='Corresponding source and runtime replacement'; Detail='The matching Runtime-Source release asset supplies the containing runtime source, selected library source trees, modifications, and rebuild/relink instructions. See docs/RUNTIME_REBUILD.md. Distributors must retain the applicable source/relink materials and notices for the binaries they ship; license text alone is insufficient.' },
    [ordered]@{ Component='Skate 2 player'; Item='License scope'; Detail='The newly authored project license is separate from third-party and game-derived code. This notice inventory grants no rights to the original game, assets, or generated game-derived code.' }
)
$records = @($prepared | ForEach-Object { $_.Record })
$index = [ordered]@{
    SchemaVersion=1; Scope='Available notices for the inspected Windows x64 D3D12 runtime dependency set'
    CompleteComplianceReview=$false; NoticeCount=$records.Count
    NoticeReviewScope='Reviewed Windows x64 D3D12 build inputs, selected embedded fonts, SDL helpers, actual SIMDe PCH dependencies and FFmpeg compiler dependencies. Exact notice bytes and source provenance are retained. This is a notice inventory for this dependency set, not a legal determination or a claim about other build configurations.'
    Acknowledgments=@('This software is based in part on the work of the Independent JPEG Group.', 'The DXBC checksum implementation is derived from the RSA Data Security, Inc. MD5 Message Digest Algorithm.')
    ExternalPrerequisites=@(
        [ordered]@{ Component='Microsoft Visual C++ x64 runtime'; Deployment='Installed separately from Microsoft; the player release does not bundle Microsoft CRT DLLs or the installer.'; TestedVersion='14.44.35211.0'; LicenseTerms='https://visualstudio.microsoft.com/license-terms/vs2022-cruntime/'; OfficialDownload='https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170'; Scope='The project license does not cover this prerequisite. Installed runtime terms apply separately.' },
        [ordered]@{ Component='Windows system libraries and MS Gothic'; Deployment='Provided by Windows, not bundled. The UI optionally loads MS Gothic from the installed Windows Fonts directory.'; Scope='Windows and its installed components retain their separate terms.' }
    )
    ModificationScope='The collector does not modify SDK sources. Review exact source changes and provenance with the final release source bundle.'
    Files=$records; DistributionRequirements=$distributionRequirements
}
$indexPath = Assert-OrdinaryPath (Join-Path $licenseRoot 'NOTICE-INDEX.json') $licenseRoot
$audit = [ordered]@{
    SchemaVersion=1; GeneratedUtc=[DateTime]::UtcNow.ToString('o'); Mode=$(if ($CheckOnly) {'CheckOnly'} else {'Collect'})
    CompleteComplianceReview=$false; NoticeCount=$records.Count; NoticeBytes=($records | Measure-Object Bytes -Sum).Sum
    CheckedOrdinaryPaths=$true; ExactBytesPreserved=$true; ExistingDifferentNoticeFilesOverwritten=$false
    FFmpegWindowsX64Flags=$ffmpegFlags; SdkBuildFlags=$buildFlags; ReleaseLinks=$links.ToArray()
    Evidence=$evidence.ToArray(); InspectedSdkBinaries=$binaryEvidence
    BinaryEvidenceLimit='Link instructions and current SDK output hashes are recorded; final player package closure and exact correspondence still require release validation.'
    Files=$records; DistributionRequirements=$distributionRequirements
}
if (-not $CheckOnly) {
    [void][IO.Directory]::CreateDirectory($licenseRoot)
    foreach ($entry in $prepared) {
        [void](Assert-OrdinaryPath $entry.Destination $licenseRoot)
        if (-not (Test-Path -LiteralPath $entry.Destination)) {
            $stream = [IO.File]::Open($entry.Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($entry.Bytes, 0, $entry.Bytes.Length) } finally { $stream.Dispose() }
        }
        if ((Get-FileHash -LiteralPath $entry.Destination -Algorithm SHA256).Hash -ne $entry.Record.SHA256) { throw 'Written notice failed SHA256 verification.' }
    }
    [IO.File]::WriteAllText($indexPath, ($index | ConvertTo-Json -Depth 9) + "`n", $utf8)
    [void][IO.Directory]::CreateDirectory((Split-Path $reportPath -Parent))
    [IO.File]::WriteAllText($reportPath, ($audit | ConvertTo-Json -Depth 9) + "`n", $utf8)
}
[pscustomobject]@{ Mode=$audit.Mode; NoticeCount=$audit.NoticeCount; NoticeBytes=$audit.NoticeBytes; CompleteComplianceReview=$false; DistributionRequirementCount=$distributionRequirements.Count }

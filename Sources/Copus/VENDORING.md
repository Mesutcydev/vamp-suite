Vendored from the official Xiph Opus 1.6.1 release:
https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz
SHA256 verified against https://opus-codec.org/downloads/:
6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1

Portable float build. Compilation units are the upstream OPUS_SOURCES,
OPUS_SOURCES_FLOAT, CELT_SOURCES, SILK_SOURCES and SILK_SOURCES_FLOAT lists.
SIMD, fixed-point, neural enhancement, DRED and demo/test compilation units are
not enabled. Upstream headers are preserved; copus_helpers.c and its public
header are project-owned wrappers. License: see COPYING (BSD-3-Clause).

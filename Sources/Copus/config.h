/* Build config for the vendored opus 1.6.1 (Xiph) sources.
 * Float build, no runtime CPU detection and no SIMD/asm (the SIMD source dirs are
 * excluded in Package.swift and their includes are #if-guarded behind macros we never
 * define). This keeps the codec pure portable C so it builds identically across the
 * iOS device/simulator and Apple-Silicon/Intel macOS slices of all three apps.
 */
#ifndef COPUS_CONFIG_H
#define COPUS_CONFIG_H

#define OPUS_BUILD 1
#define PACKAGE_VERSION "1.6.1"
#define VAR_ARRAYS 1
#define HAVE_LRINTF 1
#define HAVE_LRINT 1

#endif /* COPUS_CONFIG_H */

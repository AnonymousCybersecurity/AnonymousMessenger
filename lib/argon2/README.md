# Argon2 native library

This replaces the precompiled `im.molly:argon2:13.1-1` AAR, whose 64-bit
libraries use 4 KB ELF alignment. The app now builds the same implementation
with the NDK version pinned in `gradle/libs.versions.toml` and explicit 16 KB
linker alignment.

Source provenance:

- Java API and JNI bridge: [mollyim/argon2, tag 13.1-1](https://github.com/mollyim/argon2/tree/b0f538525a2a6a55f0aeaf75fba33bb75d9170c7).
- Reference implementation: the exact upstream submodule revision,
  [P-H-C/phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2/tree/62358ba2123abd17fccf2a108a301d4b52c01a7c).

The Java API, JNI bridge and reference implementation are copied unchanged.
Only Android build configuration and source paths have changed. The original
published wrapper declares GPLv3; the reference implementation includes its
CC0 / Apache 2.0 license at `src/main/cpp/argon2/LICENSE`.

Build with `./gradlew :lib:argon2:assembleRelease`. Run the instrumentation
tests on both a regular Android device and a 16 KB emulator with
`./gradlew :lib:argon2:connectedDebugAndroidTest`.

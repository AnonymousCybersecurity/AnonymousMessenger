# Native utilities

This replaces the precompiled `im.molly:native-utils:1.0.0` AAR, whose 64-bit
libraries use 4 KB ELF alignment. The app now builds these utilities with the
NDK version pinned in `gradle/libs.versions.toml` and explicit 16 KB linker
alignment.

The C/C++ sources are copied from [mollyim/ndkutil, tag v1.0.0](https://github.com/mollyim/ndkutil/tree/c45343a0bc36b9427d0e1b997b87c058bea1397d).
The original published library declares GPLv3. Its JNI entry points and
runtime page-size lookup are preserved.

Build with `./gradlew :lib:native-utils:assembleRelease`. Run the instrumentation
tests on both a regular Android device and a 16 KB emulator with
`./gradlew :lib:native-utils:connectedDebugAndroidTest`.

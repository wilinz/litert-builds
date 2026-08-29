# litert-builds

The TensorFlow Lite C library — LiteRT's runtime, under the name its C API
still carries — built for every platform an application runs on, from one
TensorFlow version, published under one tag.

Nothing here is patched. The sources are cloned at the tag `tflite.toml` names
and compiled with upstream's own CMake build, so what comes out is a plain
TFLite C library — the only thing this repository adds is that someone built
it, on CI, from a version you can read, with a checksum you can pin.

## Why

Google publishes TensorFlow Lite for Android and iOS and nothing else. Every
desktop project that wants the C library either builds TensorFlow itself, which
means Bazel and the better part of an hour, or takes it from whoever built it
last. The library that has been serving that purpose was built by hand and its
repository has not been touched since 2024 — which is fine until the version
you need is the one that never appears.

The phones are here too, though Google does publish those, because what it
publishes moves on version lines of its own: the Android AAR was LiteRT 2.2.0
and the iOS framework TensorFlow 2.17.0 while the desktops were on 2.17.1 —
three runtimes, one set of weights, and nothing anywhere saying they had come
apart. A version that means the same thing everywhere is worth more than a
build somebody else ran.

So this builds them: nine targets, one script, in CI, from a pinned version.

## What is built

| Target | Library | Runner |
|---|---|---|
| `darwin_universal` | `libtensorflowlite_c.dylib`, arm64 and x86_64 in one file | macos-15 |
| `linux_amd64` | `libtensorflowlite_c.so` | ubuntu-latest |
| `linux_arm64` | `libtensorflowlite_c.so` | ubuntu-24.04-arm |
| `windows_amd64` | `tensorflowlite_c.dll` | windows-latest |
| `android_arm64` | `libtensorflowlite_c.so`, arm64-v8a | ubuntu-latest |
| `android_arm` | `libtensorflowlite_c.so`, armeabi-v7a | ubuntu-latest |
| `android_x64` | `libtensorflowlite_c.so`, x86_64 | ubuntu-latest |
| `ios_device` | `libtensorflowlite_c.a`, arm64 | macos-15 |
| `ios_simulator` | `libtensorflowlite_c.a`, arm64 and x86_64 | macos-15 |

Android is built against API 24 and iOS against 13.0, which are floors rather
than choices: a library built for a newer one will not load on an older phone.
Its libraries are stripped afterwards, which nothing else here needs: the NDK's
toolchain compiles with `-g` even in a release build, on the assumption that
the Android Gradle plugin will strip whatever it packages, and a library
published on its own has nobody to do that for it — 73 MB against 5.

The iOS libraries are static — an application has no rpath to load a `.dylib`
from — and each is every archive the build produced joined into one, because
CMake leaves a static target's dependencies beside it rather than in it, and
those dependencies are the kernels.

The XNNPACK delegate is on, which is most of why the library is worth having:
about five times on a small CNN.

macOS is one library holding both architectures, joined with `lipo`, because a
macOS release build is universal unless it is told otherwise — an arm64-only
library means every release build of every application fails at the link step,
with a warning rather than an error and a long way from the reason.

Each build is a single architecture even so: CMake configures its dependencies
by compiling test programs, and some of them cannot be configured for two
architectures at once.

## Using one

Take the archive for your platform from a release, or build it yourself:

```sh
./build.sh darwin_universal        # needs cmake and a C++ toolchain
```

The archive holds the library and a `.build` file naming the TensorFlow
version, the commit and runner that produced it, and the checksum. The
Windows one also holds `tensorflowlite_c.lib`, the import library MSVC links
against; the DLL alone is not something a link can use.
`SHA256SUMS` on the release covers all four, which is what a lock file
downstream wants.

## Versions

`tflite.toml` holds both halves of what a release is:

```toml
[tensorflow]
version = "v2.17.1"
revision = 3
```

`version` is TensorFlow's. `revision` is this repository's, and it moves when
`build.sh` changes while the version stays put — the same sources built with
different flags are a different library, and a checksum in a lock file
downstream would otherwise be the only thing that noticed.

Together they name a release, `v2.17.1-b5`, and the tag has to match: the
workflow reads `tflite.toml` and stops if the tag says something else. Changing
that file is the whole of a version bump.

## Licence

The build script and the workflow are Apache-2.0. What they produce is
TensorFlow Lite, which is Apache-2.0 and belongs to the TensorFlow authors; see
[LICENSE.md](LICENSE.md).

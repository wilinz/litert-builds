#!/usr/bin/env bash
# Build the TensorFlow Lite C shared library.
#
#   ./build.sh <target> [output directory]
#
#   darwin_universal   arm64 and x86_64 in one dylib, from any Mac
#   linux_amd64        x86_64
#   linux_arm64        aarch64
#   windows_amd64      x64, MSVC
#   android_arm64      arm64-v8a, needs an NDK
#   android_arm        armeabi-v7a, needs an NDK
#   android_x64        x86_64, needs an NDK
#   ios_device         arm64, a static library
#   ios_simulator      arm64 and x86_64, a static library
#
# The phones are here rather than taken from Google's own distributions —
# LiteRT's Android AAR and the iOS framework CocoaPods pulls — because those
# move on their own version lines: at the time of writing the AAR was LiteRT
# 2.2.0 and the framework TensorFlow 2.17.0 while the desktops were on 2.17.1,
# so the same weights ran against three different runtimes. One version for
# every platform is the whole point of this repository.
#
# The version comes from tflite.toml beside this script; TENSORFLOW_VERSION
# overrides it for trying one without committing to it.
#
# Nothing here patches TensorFlow. The sources are cloned at the tag and
# compiled as they are, with CMake, which is upstream's own build for this
# library — so what comes out is a plain TFLite C library and the only thing
# this repository adds is that someone built it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

tflite_version() {
  sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' \
    "$HERE/tflite.toml" | head -1
}

TENSORFLOW_VERSION="${TENSORFLOW_VERSION:-$(tflite_version)}"
[ -n "$TENSORFLOW_VERSION" ] || {
  echo "no [tensorflow] version in tflite.toml, and TENSORFLOW_VERSION is not set" >&2
  exit 1
}

TARGET="${1:-}"
OUT="${2:-$HERE/out}"
WORK="${TFLITE_WORKDIR:-$HERE/.work}"

# What comes out, and what the phones need that the desktops do not.
#
# ANDROID_API and IOS_MIN are floors rather than choices: a library built for a
# newer one will not load on an older phone, and wxscan's own minimums are
# API 24 and iOS 13.
ANDROID_API=24
IOS_MIN=13.0

case "$TARGET" in
  darwin_universal) LIB=libtensorflowlite_c.dylib ;;
  linux_amd64|linux_arm64) LIB=libtensorflowlite_c.so ;;
  windows_amd64) LIB=tensorflowlite_c.dll; IMPORT_LIB=tensorflowlite_c.lib ;;
  android_arm64) LIB=libtensorflowlite_c.so; ABI=arm64-v8a ;;
  android_arm) LIB=libtensorflowlite_c.so; ABI=armeabi-v7a ;;
  android_x64) LIB=libtensorflowlite_c.so; ABI=x86_64 ;;
  # Static, because that is how an iOS application takes a C library: there is
  # no rpath to load a .dylib from, and the framework Google publishes is a
  # static object too.
  ios_device) LIB=libtensorflowlite_c.a; SDK=iphoneos ;;
  ios_simulator) LIB=libtensorflowlite_c.a; SDK=iphonesimulator ;;
  *)
    echo "usage: $0 <target> [out]" >&2
    echo "  darwin_universal linux_amd64 linux_arm64 windows_amd64" >&2
    echo "  android_arm64 android_arm android_x64 ios_device ios_simulator" >&2
    exit 2
    ;;
esac

case "$TARGET" in
  android_*)
    NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_ROOT:-}}}"
    [ -n "$NDK" ] && [ -d "$NDK" ] || {
      echo "no NDK: set ANDROID_NDK_HOME to one" >&2
      exit 1
    }
    # llvm-strip is a symlink to llvm-strip.real in the NDK, so -type f would
    # walk straight past it.
    STRIP=$(find "$NDK/toolchains/llvm/prebuilt" -name 'llvm-strip' \( -type f -o -type l \) -print -quit)
    [ -n "$STRIP" ] || { echo "no llvm-strip in $NDK" >&2; exit 1; }
    ;;
esac

# CMake 4 removed compatibility with projects declaring a minimum below 3.5,
# and FP16, FXdiv and psimd — dependencies TensorFlow Lite fetches, not code
# anyone here controls — still declare 2.8.12. Without this the configure stops
# there on a runner that has CMake 4, which by now is most of them.
#
# In the environment rather than on the command line because FP16 fetches its
# own dependencies by starting a second cmake, which inherits an environment
# but not a -D. Older CMake does not know the variable and ignores it.
#
# It is a floor for those projects rather than a change to them: nothing here
# is patched, and the sources are still compiled as they are.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

mkdir -p "$WORK" "$OUT"

# ---- sources ---------------------------------------------------------------
if [ ! -d "$WORK/tensorflow" ]; then
  echo "== cloning tensorflow $TENSORFLOW_VERSION"
  git clone -q --depth 1 --branch "$TENSORFLOW_VERSION" \
    https://github.com/tensorflow/tensorflow.git "$WORK/tensorflow"
fi

# ---- build -----------------------------------------------------------------
# Where the build happened must not end up in what it produced: TFLite's
# logging macros put __FILE__ in the binary, so without this the library
# carries the absolute path of whoever built it and the same sources give
# different bytes from a different directory. MSVC has no equivalent flag, and
# the .build file beside the artifact says which machine produced it.
PREFIX_MAP="-ffile-prefix-map=$WORK=/tflite -ffile-prefix-map=$HERE=/tflite"

# One architecture at a time, always. A macOS universal library is two of these
# joined by lipo rather than one build with two architectures: CMake configures
# its dependencies by compiling test programs, and some of them — eigen's
# FindStandardMathLibrary is the first — cannot be configured for two
# architectures at once.
# The path of what was built is left in $BUILT rather than written to stdout
# for the caller to read: `found=$(build_one)` puts the whole function in a
# command substitution, where `set -e` no longer stops anything — a failing
# cmake would be swallowed and the caller would report the library missing
# instead of the compiler error that explains why. Which is exactly what a
# Windows build did, for one whole run.
# TensorFlow 2.17 uses designated initializers, which MSVC takes only under
# C++20 where clang and gcc allow them as an extension — so it is the one
# toolchain that stops, on `operator.cc` and on the XNNPACK weight cache.
#
# The standard cannot be raised from outside: TFLite sets CMAKE_CXX_STANDARD to
# 17 in its own CMakeLists, which overrules the cache, and MSBuild puts the
# property that comes from it after the flags, so /std:c++20 in CMAKE_CXX_FLAGS
# loses too. What is left is the project files CMake just generated — this
# build's own output, not TensorFlow's source. Every configure writes them
# again, so every configure is followed by this.
raise_cxx_standard() {
  echo "== raising the C++ standard in the generated projects"
  find "$1" -name '*.vcxproj' -exec \
    sed -i 's|<LanguageStandard>stdcpp17</LanguageStandard>|<LanguageStandard>stdcpp20</LanguageStandard>|g' {} +
}

# dumpbin reads what the compiler produced, and ships beside it rather than on
# PATH. Not `vswhere -find cl.exe`, which is how the workflow finds the
# compiler: it answered with a side-by-side 14.29 toolset that carries a cl.exe
# and no dumpbin.exe, while the build itself used 14.51. So every toolset in
# every installation is searched and the newest wins — any recent dumpbin reads
# these objects the same way.
find_dumpbin() {
  echo "== looking for dumpbin"
  DUMPBIN=$(find "/c/Program Files/Microsoft Visual Studio" \
                 "/c/Program Files (x86)/Microsoft Visual Studio" \
                 -name dumpbin.exe -path '*Hostx64/x64*' 2>/dev/null | sort -V | tail -1)
  echo "   dumpbin: ${DUMPBIN:-<nothing found>}"
  [ -n "$DUMPBIN" ] || { echo "no dumpbin.exe in any Visual Studio installation"; return 1; }
}

# `find ... -print -quit` and never `find ... | head -1`, throughout: this
# script runs under `set -o pipefail`, head closes the pipe after the first
# line, and a find still walking a large tree is then killed by SIGPIPE — so
# the pipeline reports 141, `set -e` stops the script, and nothing is printed
# to say why. That is what two Windows runs looked like: an echo, then exit 1.
# It depends on how much of the tree is left to walk, which is why the same
# line worked for years elsewhere.
BUILT=
build_one() {
  local arch="$1"
  # Two statements, not one: a `local a=$1 b=$a` expands every word before it
  # assigns any of them, so `b` would be built from the *previous* `a`. Both
  # slices then configure and build in one directory, the second inherits the
  # first's cache, and lipo is handed the same architecture twice.
  local dir="$WORK/build-$TARGET${arch:+-$arch}"
  local args=(
    -S "$WORK/tensorflow/tensorflow/lite/c" -B "$dir"
    -DCMAKE_BUILD_TYPE=Release
    # The delegate is most of why this library is worth having: about five
    # times on a CNN, measured on the same kernels wxscan's detector uses.
    -DTFLITE_ENABLE_XNNPACK=ON
  )
  case "$TARGET" in
    windows_amd64) args+=(-A x64) ;;
    android_*)
      args+=(
        -DCMAKE_C_FLAGS="$PREFIX_MAP" -DCMAKE_CXX_FLAGS="$PREFIX_MAP"
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
        -DANDROID_ABI="$ABI"
        -DANDROID_PLATFORM="android-$ANDROID_API"
      )
      ;;
    ios_*)
      # One architecture at a time here too, and for the same reason as macOS;
      # the simulator's two are joined at the end.
      args+=(
        -DCMAKE_C_FLAGS="$PREFIX_MAP" -DCMAKE_CXX_FLAGS="$PREFIX_MAP"
        -DCMAKE_SYSTEM_NAME=iOS
        -DCMAKE_OSX_SYSROOT="$SDK"
        -DCMAKE_OSX_ARCHITECTURES="$arch"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"
        # A shared library has nowhere to be loaded from on iOS, so the C API
        # is built into an archive, and the archives its dependencies build
        # are joined onto it below — CMake links none of them into a static
        # target, and an application would otherwise be handed a library
        # missing every kernel it needs.
        -DTFLITE_C_BUILD_SHARED_LIBS=OFF
        # flatbuffers builds flatc and installs it, and for iOS CMake makes
        # every executable an app bundle, which install() then refuses without
        # a bundle destination. TFLite builds the flatc it actually uses as a
        # host tool through ExternalProject, so the one in the tree is dead
        # weight anywhere and a configure error here. MACOSX_BUNDLE off is the
        # same argument for whatever else declares an executable.
        -DFLATBUFFERS_BUILD_FLATC=OFF
        -DFLATBUFFERS_INSTALL=OFF
        -DCMAKE_MACOSX_BUNDLE=OFF
      )
      ;;
    *)
      args+=(-DCMAKE_C_FLAGS="$PREFIX_MAP" -DCMAKE_CXX_FLAGS="$PREFIX_MAP")
      # CMAKE_OSX_ARCHITECTURES alone tells the compiler which architecture to
      # emit but leaves CMAKE_SYSTEM_PROCESSOR at the host's, and TFLite picks
      # its SIMD dependency off that variable: building the x86_64 slice on an
      # Apple Silicon Mac it skips neon2sse, then compiles SSE code that wants
      # the header neon2sse would have provided. CMake only honours a given
      # processor when a system name is given with it, so both are set, and set
      # for either slice, so that what comes out does not depend on which kind
      # of Mac ran the build.
      [ -n "$arch" ] && args+=(
        -DCMAKE_OSX_ARCHITECTURES="$arch"
        -DCMAKE_SYSTEM_NAME=Darwin
        -DCMAKE_SYSTEM_PROCESSOR="$arch"
      )
      ;;
  esac

  echo "== configuring $TARGET${arch:+ ($arch)}"
  cmake "${args[@]}"

  if [ "$TARGET" = windows_amd64 ]; then
    raise_cxx_standard "$dir"
  fi
  echo "== building tensorflowlite_c${arch:+ for $arch} (this takes a while)"
  cmake --build "$dir" -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)" \
    --config Release --target tensorflowlite_c

  # Windows links again, against a list of what to export.
  #
  # Nothing about the first link says anything is wrong: MSVC exports only
  # what a symbol asks to export, TFLite's C API asks through TFL_CAPI_EXPORT,
  # and that macro is empty whenever TFL_STATIC_LIBRARY_BUILD is defined —
  # which tensorflow-lite, built static, adds PUBLIC to everything linking it,
  # the C API's own shared library included. So the DLL came out with an empty
  # export table, and a DLL that exports nothing gets no import library
  # either. It linked, it was the right size, and nothing could call into it.
  # Every release up to v2.17.1-b5 shipped that DLL.
  #
  # The other two platforms are unaffected: their scripts (exported_symbols.lds
  # on Apple, version_script.lds elsewhere) name `TfLite*` and decide exports
  # on their own. This is the same list, in the form MSVC takes, gathered from
  # the objects rather than written down — the XNNPACK delegate's entry points
  # are in the static library rather than in this target's own objects, and
  # the Linux .so exports them too.
  if [ "$TARGET" = windows_amd64 ]; then
    def="$dir/tensorflowlite_c.def"
    echo "== collecting the exports for $LIB"
    find_dumpbin
    static_lib=$(find "$dir" -name tensorflow-lite.lib -type f -print -quit)
    [ -n "$static_lib" ] || { echo "no tensorflow-lite.lib under $dir" >&2; exit 1; }
    echo "   static library: $static_lib"

    # Every step writes a file and says how big it is. Under `set -o pipefail`
    # a grep that matches nothing, or a dumpbin handed no arguments, ends the
    # script with no output at all, and this ran three times before it said
    # anything about where it stopped.
    objs="$dir/exports-objects.txt"
    syms="$dir/exports-symbols.txt"
    names="$dir/exports.txt"

    find "$dir" -name '*.obj' -path '*tensorflowlite_c*' > "$objs" || true
    echo "   objects: $(wc -l < "$objs" | tr -d ' ')"
    [ -s "$objs" ] || {
      echo "no objects for tensorflowlite_c under $dir; what is there:"
      find "$dir" -maxdepth 2 -type d | head -40
      exit 1
    }

    # The C API's own entry points, from this target's objects. UNDEF lines are
    # what an object calls rather than what it defines, and the name is the
    # last field of the line — as it is for /LINKERMEMBER below, and for the
    # same reason: matching an anchored name keeps C++ mangled symbols that
    # merely mention a TfLite type out of a list the linker will then insist
    # on resolving. Matching `External | TfLite...` instead, which is what
    # this did, quietly found nothing at all: v2.17.1-b6's 300 exports came
    # from the static library alone, and this half contributed none of them.
    : > "$syms"
    while IFS= read -r obj; do
      "$DUMPBIN" /SYMBOLS "$obj" \
        | grep -v UNDEF \
        | awk '{ print $NF }' \
        | grep -E '^TfLite[A-Za-z0-9_]+$' >> "$syms" || true
    done < "$objs"
    echo "   from the objects: $(sort -u "$syms" | wc -l | tr -d ' ')"

    # The XNNPACK delegate's, from the static library: they are not in this
    # target's objects, and the Linux .so exports them. /LINKERMEMBER lists the
    # public symbols an archive defines, which /SYMBOLS on a library this size
    # would take minutes to say. The name is the last field; anchoring the
    # match keeps C++ mangled names that merely mention a TfLite type out of a
    # list the linker will then insist on resolving.
    "$DUMPBIN" /LINKERMEMBER:1 "$static_lib" \
      | awk '{ print $NF }' \
      | grep -E '^TfLite[A-Za-z0-9_]+$' >> "$syms" || true

    sort -u "$syms" -o "$names"
    count=$(wc -l < "$names" | tr -d ' ')
    # The C API is a couple of hundred entry points; a handful means they were
    # looked for in the wrong place, and shipping that would be the same silent
    # failure in a new shape.
    [ "$count" -ge 100 ] || {
      echo "only $count exports found, which cannot be the whole C API" >&2
      exit 1
    }
    echo "   first few: $(head -5 "$names" | tr '\n' ' ')"
    { echo EXPORTS; cat "$names"; } > "$def"
    echo "== relinking with $count exports"
    cmake "${args[@]}" -DCMAKE_SHARED_LINKER_FLAGS="/DEF:$(cygpath -w "$def")"
    raise_cxx_standard "$dir"
    cmake --build "$dir" --config Release --target tensorflowlite_c
  fi
  case "$TARGET" in
    ios_*) join_archives "$dir" "$WORK/$TARGET${arch:+-$arch}.a" ;;
    *) BUILT=$(find "$dir" -name "$LIB" -type f -print -quit) ;;
  esac

  # The NDK's toolchain file compiles with -g even in a release build, on the
  # assumption that the Android Gradle plugin will strip what it packages. A
  # library published on its own has nobody to do that for it, and the
  # difference is not small: 73 MB against 5.
  #
  # --strip-unneeded and not --strip-all: the dynamic symbols are the library's
  # entire interface.
  if [ -n "${STRIP:-}" ] && [ -n "$BUILT" ]; then
    echo "== stripping $(basename "$BUILT")"
    "$STRIP" --strip-unneeded "$BUILT"
  fi
}

# Puts every archive a build produced into one, which is what an application
# linking the C API on iOS needs: CMake leaves a static target's dependencies
# beside it rather than in it, and TFLite's are XNNPACK, ruy, pthreadpool,
# cpuinfo, farmhash, fft2d and flatbuffers — the kernels, in other words.
#
# The result goes into $BUILT for the same reason build_one's does: a function
# read through a command substitution is a function whose failures nobody sees.
join_archives() {
  local dir="$1" out="$2"
  local parts=()
  while IFS= read -r a; do parts+=("$a"); done < <(find "$dir" -name '*.a' -type f)
  [ "${#parts[@]}" -gt 0 ] || { echo "no archives under $dir" >&2; exit 1; }
  rm -f "$out"
  # Archives built from different projects hold objects of the same name, which
  # libtool says so about, once per pair, in the hundreds. It is not a problem
  # — they keep their own offsets — so the noise goes, and only it.
  libtool -static -o "$out" "${parts[@]}" 2>&1 | grep -v "same member name" || true
  [ -f "$out" ] || { echo "libtool produced no $out" >&2; exit 1; }
  BUILT="$out"
}

if [ "$TARGET" = ios_simulator ]; then
  # Both architectures, so one library serves a simulator on either kind of
  # Mac; the device has only the one.
  build_one arm64; sim_arm=$BUILT
  build_one x86_64; sim_intel=$BUILT
  lipo -create "$sim_arm" "$sim_intel" -output "$OUT/$LIB"
elif [ "$TARGET" = ios_device ]; then
  build_one arm64
  cp "$BUILT" "$OUT/$LIB"
elif [ "$TARGET" = darwin_universal ]; then
  build_one arm64; arm=$BUILT
  build_one x86_64; intel=$BUILT
  [ -n "$arm" ] && [ -n "$intel" ] || { echo "one of the two slices is missing" >&2; exit 1; }
  lipo -create "$arm" "$intel" -output "$OUT/$LIB"
  # The loader looks for the library by the name it is linked against, and the
  # build leaves an absolute path there. Rewritten here so nothing downstream
  # has to.
  install_name_tool -id "@rpath/$LIB" "$OUT/$LIB"
  echo "== architectures: $(lipo -archs "$OUT/$LIB")"
else
  build_one ""
  [ -n "$BUILT" ] || { echo "built, but no $LIB was produced" >&2; exit 1; }
  cp "$BUILT" "$OUT/$LIB"

  # MSVC does not link against a DLL; it links against the import library the
  # DLL was built with, and without it the link stops at LNK1181 having never
  # looked at the DLL at all. So the .lib travels in the archive too - it is
  # 100 kB of stubs, and the alternative is every Windows caller generating
  # one from the exports.
  if [ "$TARGET" = windows_amd64 ]; then
    IMPLIB=$(find "$WORK" -name "$IMPORT_LIB" -type f -print -quit)
    [ -n "$IMPLIB" ] || { echo "built, but no $IMPORT_LIB anywhere in $WORK" >&2; exit 1; }
    cp "$IMPLIB" "$OUT/$IMPORT_LIB"
    ls -l "$OUT/$IMPORT_LIB"
  fi
fi

ls -l "$OUT/$LIB"

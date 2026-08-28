#!/usr/bin/env bash
# Build the TensorFlow Lite C shared library.
#
#   ./build.sh <target> [output directory]
#
#   darwin_universal   arm64 and x86_64 in one dylib, from any Mac
#   linux_amd64        x86_64
#   linux_arm64        aarch64
#   windows_amd64      x64, MSVC
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

case "$TARGET" in
  darwin_universal) LIB=libtensorflowlite_c.dylib ;;
  linux_amd64|linux_arm64) LIB=libtensorflowlite_c.so ;;
  windows_amd64) LIB=tensorflowlite_c.dll ;;
  *)
    echo "usage: $0 <darwin_universal|linux_amd64|linux_arm64|windows_amd64> [out]" >&2
    exit 2
    ;;
esac

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

  # Progress goes to stderr, because stdout is this function's return value:
  # the caller reads the path of what was built out of it.
  echo "== configuring $TARGET${arch:+ ($arch)}" >&2
  cmake "${args[@]}" >&2
  echo "== building tensorflowlite_c${arch:+ for $arch} (this takes a while)" >&2
  cmake --build "$dir" -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)" \
    --config Release --target tensorflowlite_c >&2
  find "$dir" -name "$LIB" -type f | head -1
}

if [ "$TARGET" = darwin_universal ]; then
  arm=$(build_one arm64)
  intel=$(build_one x86_64)
  [ -n "$arm" ] && [ -n "$intel" ] || { echo "one of the two slices is missing" >&2; exit 1; }
  lipo -create "$arm" "$intel" -output "$OUT/$LIB"
  # The loader looks for the library by the name it is linked against, and the
  # build leaves an absolute path there. Rewritten here so nothing downstream
  # has to.
  install_name_tool -id "@rpath/$LIB" "$OUT/$LIB"
  echo "== architectures: $(lipo -archs "$OUT/$LIB")"
else
  found=$(build_one "")
  [ -n "$found" ] || { echo "built, but no $LIB was produced" >&2; exit 1; }
  cp "$found" "$OUT/$LIB"
fi

ls -l "$OUT/$LIB"

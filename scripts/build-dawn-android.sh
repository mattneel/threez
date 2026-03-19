#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <arch> <android_ndk_home> <out_dir>" >&2
  exit 2
fi

ARCH="$1"
ANDROID_NDK_HOME="$2"
OUT_DIR="$3"

case "$ARCH" in
  aarch64) ANDROID_ABI="arm64-v8a" ;;
  x86_64) ANDROID_ABI="x86_64" ;;
  *)
    echo "unsupported Android Dawn arch: $ARCH" >&2
    exit 2
    ;;
esac

for tool in git cmake ninja python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    exit 1
  fi
done

AR="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
STRIP="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
if [ ! -x "$AR" ] || [ ! -x "$STRIP" ]; then
  echo "missing NDK llvm tools under $ANDROID_NDK_HOME" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_ROOT="$REPO_ROOT/.zig-cache/dawn"
DAWN_COMMIT="${DAWN_COMMIT:-03e999815027}"
SRC_DIR="$CACHE_ROOT/src-$DAWN_COMMIT"
BUILD_DIR="$CACHE_ROOT/build-${DAWN_COMMIT}-${ARCH}-android"
STAMP_DIR="$CACHE_ROOT/stamps"
FETCH_STAMP="$STAMP_DIR/fetched-$DAWN_COMMIT"
MERGE_DIR="$CACHE_ROOT/merge-${DAWN_COMMIT}-${ARCH}-android"

mkdir -p "$CACHE_ROOT" "$STAMP_DIR" "$OUT_DIR"

if [ ! -d "$SRC_DIR/.git" ]; then
  rm -rf "$SRC_DIR"
  git clone --shallow-since="2023-06-28" https://dawn.googlesource.com/dawn "$SRC_DIR"
fi

CURRENT_COMMIT="$(git -C "$SRC_DIR" rev-parse --short=12 HEAD 2>/dev/null || true)"
if [ "$CURRENT_COMMIT" != "$DAWN_COMMIT" ]; then
  git -C "$SRC_DIR" fetch --shallow-since="2023-06-28" origin
  git -C "$SRC_DIR" checkout --force "$DAWN_COMMIT" >/dev/null
fi

if [ ! -f "$FETCH_STAMP" ]; then
  (cd "$SRC_DIR" && python3 tools/fetch_dawn_dependencies.py --shallow)
  : > "$FETCH_STAMP"
fi

cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ANDROID_ABI" \
  -DANDROID_PLATFORM=android-26 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS="-Wno-switch-default -Wno-unsafe-buffer-usage" \
  -DDAWN_SUPPORTS_GLFW_FOR_WINDOWING=OFF \
  -DDAWN_ENABLE_VULKAN=ON \
  -DDAWN_ENABLE_NULL=OFF \
  -DDAWN_ENABLE_METAL=OFF \
  -DDAWN_ENABLE_D3D11=OFF \
  -DDAWN_ENABLE_D3D12=OFF \
  -DDAWN_ENABLE_DESKTOP_GL=OFF \
  -DDAWN_ENABLE_OPENGLES=OFF \
  -DDAWN_USE_GLFW=OFF \
  -DDAWN_USE_X11=OFF \
  -DDAWN_USE_WAYLAND=OFF \
  -DDAWN_BUILD_SAMPLES=OFF \
  -DDAWN_BUILD_TESTS=OFF \
  -DTINT_BUILD_TESTS=OFF \
  -DTINT_BUILD_GLSL_WRITER=OFF \
  -DTINT_BUILD_HLSL_WRITER=OFF \
  -DTINT_BUILD_MSL_WRITER=OFF \
  -DTINT_BUILD_BENCHMARKS=OFF \
  -DDAWN_BUILD_BENCHMARKS=OFF \
  -G Ninja

ninja -C "$BUILD_DIR" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)" \
  dawn_native dawn_proc dawn_platform dawn_wire webgpu_dawn

rm -rf "$MERGE_DIR"
mkdir -p "$MERGE_DIR"
MRI_SCRIPT="$MERGE_DIR/merge.mri"
{
  printf 'create %s\n' "$OUT_DIR/libdawn.a"
  find "$BUILD_DIR" -name '*.a' -print | LC_ALL=C sort | while IFS= read -r lib; do
    printf 'addlib %s\n' "$lib"
  done
  printf 'save\n'
  printf 'end\n'
} > "$MRI_SCRIPT"
"$AR" -M < "$MRI_SCRIPT"
"$AR" s "$OUT_DIR/libdawn.a"
"$STRIP" --strip-debug "$OUT_DIR/libdawn.a"

#!/usr/bin/env bash
# Configure and build upstream's engine for visionOS as static libraries (target `main` and its
# dependencies), for the SwiftUI app shell to link.
#
#   ./scripts/build-engine-visionos.sh <working-tree> [simulator|device]
#
# Prerequisites: patches applied (bootstrap.sh), ./scripts/fetch-moltenvk.sh, and
# ./scripts/build-ffmpeg-visionos.sh for the same platform. Needs cmake, ninja and pkgconf
# (brew install cmake ninja pkgconf).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="${1:?usage: $0 <working-tree> [simulator|device]}"
PLATFORM="${2:-simulator}"
case "$PLATFORM" in
  simulator) SYSROOT=xrsimulator; MVK_SLICE=xros-arm64_x86_64-simulator ;;
  device)    SYSROOT=xros;        MVK_SLICE=xros-arm64 ;;
  *) echo "platform must be simulator or device" >&2; exit 2 ;;
esac

TREE="$(cd "$TREE" && pwd)"
BUILD="$TREE/build/visionos-$PLATFORM"
DEPS="$TREE/build/visionos-deps/$PLATFORM/prefix"
MVK="$HERE/visionos/ThirdParty/MoltenVK"

[ -f "$MVK/MoltenVK.xcframework/$MVK_SLICE/libMoltenVK.a" ] || { echo "Run scripts/fetch-moltenvk.sh first" >&2; exit 1; }
[ -d "$DEPS/lib/pkgconfig" ] || { echo "Run scripts/build-ffmpeg-visionos.sh $TREE $PLATFORM first" >&2; exit 1; }

# Only the visionOS FFmpeg, never the host's .pc files.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"

cmake -S "$TREE" -B "$BUILD" -G Ninja \
  -DCMAKE_SYSTEM_NAME=visionOS \
  -DCMAKE_OSX_SYSROOT="$SYSROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DSRR2_BUILD_TESTS=OFF \
  -DVulkan_INCLUDE_DIR="$MVK/include" \
  -DVulkan_LIBRARY="$MVK/MoltenVK.xcframework/$MVK_SLICE/libMoltenVK.a"

cmake --build "$BUILD" --target main -- -k 0

# One archive for the app to link: every engine library plus SDL3, OpenAL, libpng, FFmpeg and
# MoltenVK. The app force-loads it, because the engine registers things from static
# constructors in objects nothing else references, which a plain static link would drop.
ARCHIVES=()
while IFS= read -r archive; do ARCHIVES+=("$archive"); done < <(find "$BUILD" -name '*.a' ! -name 'libshar_engine.a' | sort)
ARCHIVES+=("$DEPS"/lib/libav*.a "$DEPS"/lib/libsw*.a "$MVK/MoltenVK.xcframework/$MVK_SLICE/libMoltenVK.a")
libtool -static -no_warning_for_no_symbols -o "$BUILD/libshar_engine.a" "${ARCHIVES[@]}" 2> >(grep -v "same member name" >&2)
echo "==> $BUILD/libshar_engine.a ($(du -h "$BUILD/libshar_engine.a" | cut -f1), ${#ARCHIVES[@]} archives)"

#!/usr/bin/env bash
# Build a minimal static FFmpeg for visionOS from upstream's vendored source (libs/ffmpeg).
# Only Bink is enabled: every SHAR movie is a .rmv Bink file, opened by path from
# libs/radmovie/src/common/ffmpegmovieplayer.cpp.
#
#   ./scripts/build-ffmpeg-visionos.sh <working-tree> [simulator|device]
#
# Builds out of tree into <working-tree>/build/visionos-deps/<platform>/, which upstream's
# .gitignore already ignores, and installs pkg-config files there for the engine's
# pkg_check_modules(FFmpeg ...) to find.
set -euo pipefail

TREE="${1:?usage: $0 <working-tree> [simulator|device]}"
PLATFORM="${2:-simulator}"
case "$PLATFORM" in
  simulator) SDK=xrsimulator; TARGET=arm64-apple-xros26.0-simulator ;;
  device)    SDK=xros;        TARGET=arm64-apple-xros26.0 ;;
  *) echo "platform must be simulator or device" >&2; exit 2 ;;
esac

TREE="$(cd "$TREE" && pwd)"
# FFmpeg's configure word-splits its own source path, and pkg-config's flags would split too.
[[ "$TREE" != *[[:space:]]* ]] || { echo "FFmpeg can't build in a path with a space in it: $TREE" >&2; exit 1; }
OUT="$TREE/build/visionos-deps/$PLATFORM"
# Via xcrun rather than absolute paths: configure word-splits --cc/--sysroot, which breaks when
# Xcode lives under a path with spaces. `xcrun --sdk` also supplies the SDK, so no --sysroot.
CC="xcrun --sdk $SDK clang"

# Upstream committed libs/ffmpeg with no executable bits, but configure and its Makefile run
# shell scripts directly. Build from a copy under the ignored build/ dir so fixing the modes
# can't leak into `git diff` (and so into our exported patches).
SRC="$TREE/build/visionos-deps/src/ffmpeg"
if [ ! -d "$SRC" ]; then
  mkdir -p "$(dirname "$SRC")"
  rsync -a --exclude .git "$TREE/libs/ffmpeg/" "$SRC/"
  chmod +x "$SRC/configure" "$SRC"/ffbuild/*.sh
fi

mkdir -p "$OUT/ffmpeg-build"
cd "$OUT/ffmpeg-build"

"$SRC/configure" --prefix="$OUT/prefix" \
  --enable-cross-compile --target-os=darwin --arch=arm64 \
  --cc="$CC" \
  --extra-cflags="-target $TARGET" --extra-ldflags="-target $TARGET" \
  --enable-static --disable-shared --enable-pic \
  --disable-programs --disable-doc --disable-network --disable-autodetect \
  --disable-avdevice --disable-avfilter \
  --disable-everything \
  --enable-protocol=file \
  --enable-demuxer=bink \
  --enable-decoder=bink,binkaudio_rdft,binkaudio_dct

make -j"$(sysctl -n hw.ncpu)"
make install

echo "==> FFmpeg for visionOS $PLATFORM installed to $OUT/prefix"
echo "    PKG_CONFIG_PATH=$OUT/prefix/lib/pkgconfig"

#!/usr/bin/env bash
# Download the prebuilt MoltenVK XCFramework (Apache-2.0) and stage the pieces the engine needs:
# Vulkan/MoltenVK headers and the static xros (device + simulator) libraries.
#
#   ./scripts/fetch-moltenvk.sh            download the version below
#   ./scripts/fetch-moltenvk.sh --check    exit 0 if that version is already staged
#
# Output goes to visionos/ThirdParty/MoltenVK, which git ignores: a downloaded build artifact, not
# something this repository carries. Its VERSION file says which version is there.
set -euo pipefail

VERSION="v1.4.2"
# The release asset's SHA-256, as GitHub records it for MoltenVK-all.tar: a release can be
# re-uploaded, so the download is checked against this before anything in it is used. To check it
# yourself: gh api repos/KhronosGroup/MoltenVK/releases/tags/v1.4.2 \
#   --jq '.assets[] | select(.name == "MoltenVK-all.tar") | .digest'
SHA256="562a15a29bc358446a56a4091c5f7e08f604184187c1d34f712148b61ef17276"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HERE/visionos/ThirdParty/MoltenVK"
URL="https://github.com/KhronosGroup/MoltenVK/releases/download/${VERSION}/MoltenVK-all.tar"

if [ "${1:-}" = "--check" ]; then
  [ "$(cat "$DEST/VERSION" 2>/dev/null)" = "$VERSION" ] &&
    [ -f "$DEST/MoltenVK.xcframework/xros-arm64/libMoltenVK.a" ] &&
    [ -f "$DEST/MoltenVK.xcframework/xros-arm64_x86_64-simulator/libMoltenVK.a" ]
  exit
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading MoltenVK ${VERSION} (this is a ~180MB tar; only headers + xros static libs are kept)"
curl -L --fail --progress-bar -o "$WORK/MoltenVK-all.tar" "$URL"
echo "$SHA256  $WORK/MoltenVK-all.tar" | shasum -a 256 -c --quiet - ||
  { echo "ERROR: the MoltenVK download doesn't match its expected SHA-256; nothing was installed." >&2; exit 1; }

echo "==> Extracting headers + xros (visionOS) static libraries"
tar -xf "$WORK/MoltenVK-all.tar" -C "$WORK" \
  "MoltenVK/MoltenVK/include" \
  "MoltenVK/MoltenVK/static/MoltenVK.xcframework/Info.plist" \
  "MoltenVK/MoltenVK/static/MoltenVK.xcframework/xros-arm64" \
  "MoltenVK/MoltenVK/static/MoltenVK.xcframework/xros-arm64_x86_64-simulator" \
  "MoltenVK/LICENSE"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$WORK/MoltenVK/MoltenVK/include" "$DEST/include"
mkdir -p "$DEST/MoltenVK.xcframework"
cp "$WORK/MoltenVK/MoltenVK/static/MoltenVK.xcframework/Info.plist" "$DEST/MoltenVK.xcframework/"
cp -R "$WORK/MoltenVK/MoltenVK/static/MoltenVK.xcframework/xros-arm64" "$DEST/MoltenVK.xcframework/"
cp -R "$WORK/MoltenVK/MoltenVK/static/MoltenVK.xcframework/xros-arm64_x86_64-simulator" "$DEST/MoltenVK.xcframework/"
cp "$WORK/MoltenVK/LICENSE" "$DEST/LICENSE"
echo "$VERSION" > "$DEST/VERSION"

echo "==> Staged at $DEST"
echo "    include/                                    Vulkan + MoltenVK headers"
echo "    MoltenVK.xcframework/xros-arm64/             static lib for Vision Pro device"
echo "    MoltenVK.xcframework/xros-arm64_x86_64-simulator/   static lib for visionOS Simulator"

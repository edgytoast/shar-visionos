#!/usr/bin/env bash
# Writes the upstream clone's changes into patches/0002-visionos-engine-build.patch. Every engine
# change this project makes goes there (0001 is only upstream's own vcpkg.json, for its PC build).
#
#   ./scripts/export-patch.sh
#
# The clone is the one build.sh uses (SHAR_WORKING_TREE picks another). New files you add to
# upstream need `git add -N <file>` in the clone first, or git leaves them out.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/scripts/common.sh"
TREE="$(sharvr_tree)"
[ -d "$TREE/.git" ] || { echo "ERROR: no upstream clone at $TREE (run scripts/build.sh first)" >&2; exit 1; }
sharvr_engine_diff "$TREE" > "$HERE/patches/0002-visionos-engine-build.patch"
echo "==> patches/0002-visionos-engine-build.patch now holds $TREE's changes"

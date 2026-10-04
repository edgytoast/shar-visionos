#!/usr/bin/env bash
# Sets up the upstream clone the engine is built from. scripts/build.sh runs it for you.
#
#   ./scripts/bootstrap.sh <target-dir> [--head]   clone upstream into <target-dir>
#   ./scripts/bootstrap.sh --update <clone>         move a clone nobody has edited to this
#                                                    checkout's base commit and patches
#
# A new clone checks out the pinned commit in patches/UPSTREAM_BASE, which the patches are written
# against; --head checks out upstream's default branch instead, where the patches may not apply
# (if they don't, rebase them by hand and bump UPSTREAM_BASE). Then it applies patches/*.patch and
# links this repository's visionOS runtime in.
#
# Upstream's code stays in the clone: this repository only carries our patches to it, and the clone
# can't push back to upstream.
set -euo pipefail

UPSTREAM_URL="https://github.com/kote2345/The-Simpsons-Hit-and-Run-VR.git"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/scripts/common.sh"
BASE="$(tr -d ' \t\r\n' < "$HERE/patches/UPSTREAM_BASE")"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Applies every patch, then records the base and the result, which is how build.sh tells a clone
# nobody has edited (it can update itself) from one somebody has.
apply_patches() {
  echo "==> Applying patches"
  local patch applied=0
  for patch in "$HERE"/patches/*.patch; do
    [ -e "$patch" ] || continue
    git apply --check "$patch" 2>/dev/null ||
      fail "$(basename "$patch") doesn't apply (rebase it by hand, then bump patches/UPSTREAM_BASE)"
    git apply "$patch"
    echo "    applied  $(basename "$patch")"
    applied=$((applied + 1))
  done
  mkdir -p .git/sharvr
  git rev-parse HEAD > .git/sharvr/base
  sharvr_engine_diff . > .git/sharvr/applied.patch
}

if [ "${1:-}" = "--update" ]; then
  TREE="${2:?usage: $0 --update <clone>}"
  # Only a clone this checkout set up: --update resets and cleans it.
  [ -f "$TREE/.git/sharvr/base" ] && [ "$(readlink "$TREE/code/vr/visionos")" = "$HERE/visionos/engine/code/vr/visionos" ] ||
    fail "$TREE isn't an upstream clone set up by this checkout, so it's left alone"
  cd "$TREE"
  echo "==> Moving $TREE to $BASE with this checkout's patches"
  # Ignored files (the builds under build/, the linked runtime) stay put, so only what changed
  # is rebuilt.
  git reset -q --hard
  git clean -q -fd
  git cat-file -e "$BASE^{commit}" 2>/dev/null || git fetch -q upstream
  git checkout -q "$BASE"
  apply_patches
  exit 0
fi

TARGET="${1:-}"
USE_HEAD="${2:-}"
[ -n "$TARGET" ] || fail "usage: $0 <target-dir> [--head]  |  $0 --update <clone>"
if [ -e "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
  fail "$TARGET exists and is not empty"
fi

echo "==> Cloning upstream (read-only) into $TARGET"
git clone -q "$UPSTREAM_URL" "$TARGET"
cd "$TARGET"

# Guardrail: make it impossible to push to the upstream repository from this clone.
git remote rename origin upstream
git remote set-url --push upstream "DISABLED--never-push-to-upstream"
cat > .git/hooks/pre-push <<'HOOK'
#!/usr/bin/env bash
# This clone is for building and patching; nothing is pushed from it.
echo "BLOCKED: nothing is pushed from this clone." >&2
exit 1
HOOK
chmod +x .git/hooks/pre-push

if [ "$USE_HEAD" = "--head" ]; then
  echo "==> Staying on upstream's default branch ($(git rev-parse --abbrev-ref HEAD)); the patches are written against $BASE"
else
  git checkout -q "$BASE"
fi
apply_patches

# The visionOS runtime is entirely this repository's: linked in, so edits land here, and excluded
# so it never shows up as a change to upstream.
ln -s "$HERE/visionos/engine/code/vr/visionos" code/vr/visionos
echo "code/vr/visionos" >> .git/info/exclude
echo "==> Upstream is ready in $TARGET ($(git rev-parse --short=8 HEAD), push disabled)"

#!/usr/bin/env bash
# Builds everything SHAR VR needs, then generates its Xcode project.
#
#   ./scripts/build.sh             the engine for Apple Vision Pro
#   ./scripts/build.sh simulator   the engine for the visionOS Simulator
#   ./scripts/build.sh both
#
# The first run clones the upstream VR mod at the commit this repository's patches are written
# against and applies them, downloads MoltenVK and builds a Bink-only FFmpeg. Later runs bring the
# clone up to date with this checkout (after a git pull) and rebuild only what changed. The clone and
# its builds go in build/ (git ignores it), or wherever SHAR_WORKING_TREE points; FFmpeg can't build
# in a path with a space in it, so if this folder's path has one, they go in ~/Library/Developer/SHARVR.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/scripts/common.sh"
case "${1:-device}" in
  device) PLATFORMS=(device) ;;
  simulator) PLATFORMS=(simulator) ;;
  both) PLATFORMS=(device simulator) ;;
  *) echo "usage: $0 [device|simulator|both]" >&2; exit 2 ;;
esac
TREE="$(sharvr_tree)"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
# Runs a long build quietly: everything goes to the log, and the screen gets ninja's progress
# ([done/total]) if there is any. On failure, the log's end and where to find the rest.
logged() {
  local log="$1"; shift
  mkdir -p "$(dirname "$log")"
  if "$@" 2>&1 | tee "$log" | awk '/^\[[0-9]+\/[0-9]+\]/ { printf "\r    %s ", $1; fflush() }'; then
    printf '\r    done (log: %s)\n' "$log"
  else
    printf '\n'
    tail -n 40 "$log" >&2
    fail "That step failed. The whole log is $log"
  fi
}

step "Checking what this Mac has"
[ "$(uname -m)" = arm64 ] || fail "SHAR VR builds on a Mac with Apple silicon."
xcrun --sdk xros --show-sdk-path >/dev/null 2>&1 ||
  fail "Xcode's visionOS SDK isn't there. Install Xcode, open it once (to finish installing and accept its license), add the visionOS platform (Xcode > Settings > Components), then: sudo xcode-select -s /Applications/Xcode.app"
missing=()
for tool in cmake ninja pkgconf xcodegen; do command -v "$tool" >/dev/null || missing+=("$tool"); done
[ ${#missing[@]} -eq 0 ] || fail "Missing: ${missing[*]}. Install with Homebrew: brew install ${missing[*]}"
echo "    $(xcodebuild -version | head -1), visionOS SDK $(xcrun --sdk xros --show-sdk-version)"
[[ "$TREE" != *[[:space:]]* ]] ||
  fail "FFmpeg's build can't work in a path with a space in it: $TREE. Point SHAR_WORKING_TREE somewhere without one."

base="$(tr -d ' \t\r\n' < "$HERE/patches/UPSTREAM_BASE")"
if [ ! -d "$TREE/.git" ]; then
  step "Cloning upstream into $TREE"
  mkdir -p "$(dirname "$TREE")"
  "$HERE/scripts/bootstrap.sh" "$TREE"
else
  # It links this checkout's runtime in; one set up by another checkout (or before this folder
  # moved) would build that one's.
  [ "$(readlink "$TREE/code/vr/visionos")" = "$HERE/visionos/engine/code/vr/visionos" ] ||
    fail "$TREE was set up for a checkout at another path ($(readlink "$TREE/code/vr/visionos")): this folder moved, or another copy of it made the clone. Move the clone aside and run this again:
    mv \"$TREE\" \"$TREE.old\""
  if [ "$(git -C "$TREE" rev-parse HEAD)" = "$base" ] &&
     cmp -s <(sharvr_engine_diff "$TREE") "$HERE/patches/0002-visionos-engine-build.patch"; then
    echo "    upstream: $TREE"
  elif [ -f "$TREE/.git/sharvr/applied.patch" ] &&
       [ "$(git -C "$TREE" rev-parse HEAD)" = "$(cat "$TREE/.git/sharvr/base")" ] &&
       cmp -s <(sharvr_engine_diff "$TREE") "$TREE/.git/sharvr/applied.patch"; then
    # Nobody has edited it since it was set up, so it can follow this checkout's patches.
    step "Updating upstream to this checkout's patches"
    "$HERE/scripts/bootstrap.sh" --update "$TREE"
  elif [ -n "${SHAR_KEEP_TREE:-}" ]; then
    echo "    upstream: $TREE (edited; building it as it is)"
  else
    fail "$TREE has changes that aren't in this checkout's patches. If they're yours, keep them with scripts/export-patch.sh (or build anyway with SHAR_KEEP_TREE=1). Otherwise move the clone aside and run this again:
    mv \"$TREE\" \"$TREE.old\""
  fi
fi

if ! "$HERE/scripts/fetch-moltenvk.sh" --check; then
  step "Downloading MoltenVK"
  "$HERE/scripts/fetch-moltenvk.sh"
fi

for platform in "${PLATFORMS[@]}"; do
  # Rebuilt whenever its build script changes (new flags, a new FFmpeg).
  stamp="$TREE/build/visionos-deps/$platform/built-by"
  wanted="$(shasum "$HERE/scripts/build-ffmpeg-visionos.sh" | cut -d' ' -f1)"
  if [ "$(cat "$stamp" 2>/dev/null)" != "$wanted" ]; then
    step "Building FFmpeg for the $platform (a minute or two)"
    logged "$TREE/build/logs/ffmpeg-$platform.log" "$HERE/scripts/build-ffmpeg-visionos.sh" "$TREE" "$platform"
    echo "$wanted" > "$stamp"
  fi
  step "Building the engine for the $platform (the first time takes a while)"
  logged "$TREE/build/logs/engine-$platform.log" "$HERE/scripts/build-engine-visionos.sh" "$TREE" "$platform"
done

# Tells Xcode where the engine it links was built.
printf '// Written by scripts/build.sh; git ignores it.\nSHAR_WORKING_TREE = %s\n' "$TREE" > "$HERE/visionos/App/Engine.xcconfig"

step "Generating the Xcode project"
(cd "$HERE/visionos/App" && xcodegen generate --quiet)

# The team that signs the app: Local.xcconfig's, or, the first time, the one Xcode is signed in
# with, if there's exactly one. It's read from Xcode's own preferences (only each team's ID and
# name), so it can't guess wrong, and it goes no further than Local.xcconfig.
LOCAL="$HERE/visionos/App/Local.xcconfig"
signing_ready=1
teams=""
if [ ! -f "$LOCAL" ]; then
  # plutil hands on only that one key (the teams Xcode lists for its signed-in accounts), and only
  # each team's ID and name are kept.
  teams="$(defaults export com.apple.dt.Xcode - 2>/dev/null |
    plutil -extract IDEProvisioningTeamByIdentifier json -o - - 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    accounts = json.load(sys.stdin)
except Exception:
    sys.exit(0)
seen = set()
for teams in accounts.values() if isinstance(accounts, dict) else []:
    for team in teams if isinstance(teams, list) else []:
        identifier = team.get("teamID")
        if identifier and identifier not in seen:
            seen.add(identifier)
            personal = " (Personal Team)" if team.get("isFreeProvisioningTeam") else ""
            print(identifier + "\t" + team.get("teamName", "") + personal)
' 2>/dev/null || true)"
  if [ "$(printf '%s' "$teams" | grep -c . || true)" = 1 ]; then
    team="$(printf '%s' "$teams" | cut -f1)"
    printf '// Your own settings (git ignores this file); Local.xcconfig.example has the rest.\nDEVELOPMENT_TEAM = %s\n' "$team" > "$LOCAL"
    step "Signing with $(printf '%s' "$teams" | cut -f2) ($team), the team Xcode is signed in with"
    echo "    Change it in visionos/App/Local.xcconfig."
  else
    signing_ready=0
  fi
fi

echo
echo "Done. Next:"
if [ "$signing_ready" = 0 ]; then
  if [ -n "$teams" ]; then
    echo "  1. Xcode is signed in with more than one team:"
    printf '%s\n' "$teams" | sed 's/^/       /'
    echo "     Copy visionos/App/Local.xcconfig.example to visionos/App/Local.xcconfig and put the"
    echo "     one to sign with in it."
  else
    echo "  1. Sign in to Xcode with your Apple Account (Xcode > Settings > Accounts) and run this"
    echo "     again, or copy visionos/App/Local.xcconfig.example to visionos/App/Local.xcconfig and"
    echo "     put your Team ID in it."
  fi
  echo "  2. open visionos/App/SHARVR.xcodeproj, pick your Apple Vision Pro, and Run."
else
  echo "  open visionos/App/SHARVR.xcodeproj, pick your Apple Vision Pro, and Run."
fi

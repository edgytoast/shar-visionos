# Shared by the build scripts, which source it after setting HERE to the repository's root.

# Where the upstream clone lives: SHAR_WORKING_TREE if it's set, else build/upstream, or, when this
# checkout's path has a space in it (FFmpeg's build can't take one), ~/Library/Developer/SHARVR.
sharvr_tree() {
  if [ -n "${SHAR_WORKING_TREE:-}" ]; then
    printf '%s\n' "$SHAR_WORKING_TREE"
  elif [[ "$HERE" == *[[:space:]]* ]]; then
    printf '%s\n' "$HOME/Library/Developer/SHARVR/upstream"
  else
    printf '%s\n' "$HERE/build/upstream"
  fi
}

# The clone's changes to upstream as patches/0002-visionos-engine-build.patch holds them (0001 is
# upstream's vcpkg.json alone), byte for byte the same whatever anyone's git settings are.
sharvr_engine_diff() {
  git -C "$1" -c core.abbrev=8 diff --no-ext-diff --no-color --no-relative --diff-algorithm=myers \
    --indent-heuristic -U3 --inter-hunk-context=0 --src-prefix=a/ --dst-prefix=b/ -- . ':(exclude)vcpkg.json'
}

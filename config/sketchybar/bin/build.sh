#!/usr/bin/env bash
# Compile every bin/*.swift whose binary is missing or older than its source.
# Called from sketchybarrc at startup, so a fresh clone needs no build step.
# Silent no-op when there is nothing to do (the common case).

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar"
mkdir -p "$LOG_DIR"

# Compile beside the binary and rename on success. Building over $out would
# delete the last WORKING helper the moment a source stops compiling - the bar
# would silently lose its screen metrics, mic indicator or meeting overlay with
# nothing anywhere saying why. The reason lands in build-<name>.err instead.
for src in "$BIN_DIR"/*.swift; do
  [ -e "$src" ] || continue
  out="${src%.swift}"
  [ ! -x "$out" ] || [ "$src" -nt "$out" ] || continue
  err="$LOG_DIR/build-$(basename "$out").err"
  if swiftc -O -o "$out.new" "$src" 2>"$err"; then
    mv "$out.new" "$out"
    rm -f "$err"
  else
    rm -f "$out.new"
    printf 'sketchybar: %s failed to compile, see %s\n' "$(basename "$src")" "$err" >&2
  fi
done

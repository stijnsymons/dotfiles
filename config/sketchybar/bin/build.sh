#!/usr/bin/env bash
# Compile every bin/*.swift whose binary is missing or older than its source.
# Called from sketchybarrc at startup, so a fresh clone needs no build step.
# Silent no-op when there is nothing to do (the common case).

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"

for src in "$BIN_DIR"/*.swift; do
  [ -e "$src" ] || continue
  out="${src%.swift}"
  if [ ! -x "$out" ] || [ "$src" -nt "$out" ]; then
    swiftc -O -o "$out" "$src" 2>/dev/null || rm -f "$out"
  fi
done

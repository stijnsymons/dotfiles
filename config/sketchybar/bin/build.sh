#!/usr/bin/env bash
# Compile the Swift helpers whose binaries are missing or older than a source
# they depend on. Called from sketchybarrc at startup, so a fresh clone needs no
# build step. Silent no-op when there is nothing to do (the common case).

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar"
mkdir -p "$LOG_DIR"

# Compile beside the binary and rename on success. Building over $out would
# delete the last WORKING helper the moment a source stops compiling - the bar
# would silently lose its screen metrics, mic indicator or meeting overlay with
# nothing anywhere saying why. The reason lands in build-<name>.err instead.
build() { # build <out> <log-name> <swiftc args...>
  local out="$1" name="$2"; shift 2
  local err="$LOG_DIR/build-$name.err"
  if swiftc -O -o "$out.new" "$@" 2>"$err"; then
    mv "$out.new" "$out"
    rm -f "$err"
  else
    rm -f "$out.new"
    printf 'sketchybar: %s failed to compile, see %s\n' "$name" "$err" >&2
    return 1
  fi
}

# --- sb-helper: Swift + a C shim, so it is built by hand rather than by the
# generic loop below.
#
# The shim exists because bootstrap_register() - the call that claims a
# mach_helper bootstrap name - is not merely deprecated but *unavailable* to
# Swift, a hard compile error rather than a warning. bootstrap_look_up() is
# missing from Swift's Darwin module too, so sb-shim.h doubles as the bridging
# header. See the comment at the top of sb-shim.h.
HELPER_SRC="$BIN_DIR/sb-helper.swift"
if [ -e "$HELPER_SRC" ]; then
  HELPER_OUT="$BIN_DIR/sb-helper"
  SHIM_C="$BIN_DIR/sb-shim.c"
  SHIM_H="$BIN_DIR/sb-shim.h"
  SHIM_O="$LOG_DIR/sb-shim.o"     # build artefact, not part of the config

  stale=0
  for dep in "$HELPER_SRC" "$SHIM_C" "$SHIM_H"; do
    [ ! -x "$HELPER_OUT" ] || [ "$dep" -nt "$HELPER_OUT" ] && stale=1
  done

  if [ "$stale" = 1 ]; then
    err="$LOG_DIR/build-sb-shim.err"
    # -Wno-deprecated-declarations: bootstrap_register is deprecated and there
    # is no replacement; sketchybar and JankyBorders use the same call.
    if clang -c -O2 -Wno-deprecated-declarations -o "$SHIM_O" "$SHIM_C" 2>"$err"; then
      rm -f "$err"
      build "$HELPER_OUT" sb-helper \
            -import-objc-header "$SHIM_H" \
            "$HELPER_SRC" "$SHIM_O" \
            -framework CoreAudio \
            -framework SystemConfiguration \
            -framework Foundation
    else
      printf 'sketchybar: sb-shim.c failed to compile, see %s\n' "$err" >&2
    fi
  fi
fi

# --- Every other bin/*.swift is a standalone one-file helper.
for src in "$BIN_DIR"/*.swift; do
  [ -e "$src" ] || continue
  [ "$src" = "$HELPER_SRC" ] && continue
  out="${src%.swift}"
  [ ! -x "$out" ] || [ "$src" -nt "$out" ] || continue
  build "$out" "$(basename "$out")" "$src"
done

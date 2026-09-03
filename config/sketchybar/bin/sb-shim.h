// bootstrap_register() is the one call a mach_helper needs and the one call
// Swift refuses to import: it was deprecated before 10.9, and swiftc rejects
// those outright ("unavailable in macOS") rather than warning. Wrapping it in C
// is the entire purpose of this file. sketchybar itself and JankyBorders lean
// on the same deprecated call, so there is no newer API to move to - if Apple
// ever removes it, the receive half of every sketchybar helper breaks at once.
// Doubles as sb-helper.swift's bridging header: bootstrap_look_up is NOT
// exposed by Swift's Darwin module either, so the send half needs this include
// even though only the register call needs the wrapper below.
#include <bootstrap.h>
#include <libproc.h>
#include <mach/mach.h>

int sb_bootstrap_register(mach_port_t bs_port, const char* name, mach_port_t port);

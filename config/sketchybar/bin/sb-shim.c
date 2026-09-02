#include <bootstrap.h>
#include "sb-shim.h"

int sb_bootstrap_register(mach_port_t bs_port, const char* name, mach_port_t port) {
  return bootstrap_register(bs_port, (char*)name, port);
}

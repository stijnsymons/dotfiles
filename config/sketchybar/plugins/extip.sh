#!/usr/bin/env bash
# The external IP, for the wifi popup. Prints one line and nothing else.
#
#   extip.sh            cached value, refreshed when stale
#   extip.sh --refresh  ignore the cache and re-ask now
#
# Cached because this is the only item on the bar that leaves the machine. The
# popup is rebuilt every time it opens and the wifi item ticks on a timer, so an
# uncached lookup would put a network round trip on a path that repaints several
# times a minute - and a DNS stall would hang the whole popup, not just this row.
# A public IP changes when the link changes, which the wifi item already knows
# about, so --refresh is wired to that rather than to a short TTL.
set -u

source "$CONFIG_DIR/colors.sh"

CACHE="$SB_CACHE_DIR/extip"
TTL=1800   # 30 min. A backstop for the case the link never changes but the ISP
           # re-leases anyway; the wifi item's --refresh is the real trigger.

# Two providers, not one. These are third-party endpoints that go down, rate
# limit, or start returning an HTML error page, and a status bar row reading
# "<!DOCTYPE" is worse than an empty one. Both return a bare address and nothing
# else, so the validation below is the same for each.
#
# --max-time, not just --connect-timeout: a provider that accepts the connection
# and then never answers is the failure that actually hangs this, and a connect
# timeout alone does not cover it. 2s is deliberately short - this is a nicety
# in a popup, not something worth making the user wait for.
fetch() {
  for url in "https://api.ipify.org" "https://ifconfig.me/ip"; do
    ip="$(curl -fsS --max-time 2 "$url" 2>/dev/null | tr -d '[:space:]')"
    # Shape check rather than trust in the provider. A captive portal answers
    # 200 with a login page, and a rate-limited provider answers 200 with a
    # sentence - both would otherwise be cached and printed into the popup as
    # if they were an address. The v6 branch requires a colon so that a bare
    # word like "error" cannot pass as hex.
    if printf '%s' "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F]{0,4}(:[0-9a-fA-F]{0,4}){2,7}$'; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

if [ "${1:-}" != "--refresh" ] && [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  if [ "$age" -lt "$TTL" ]; then
    cat "$CACHE"
    exit 0
  fi
fi

if IP="$(fetch)"; then
  printf '%s' "$IP" > "$CACHE"
  printf '%s\n' "$IP"
  exit 0
fi

# Offline, or both providers unreachable. The last known address is better than
# a blank row - it is what you had a moment ago and it says so by being stale
# rather than by being absent. Only when there has never been one does this
# print nothing, and the caller drops the row.
[ -f "$CACHE" ] && { cat "$CACHE"; exit 0; }
exit 0

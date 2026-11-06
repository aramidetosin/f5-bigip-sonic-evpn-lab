#!/bin/bash
# mgmt-access.sh [--check]: make the management network reachable; run by up.sh, re-runnable.
#  1. masquerade the management subnet out of the host's LAN interface (gen.py LAN_IF), so the nodes reach the internet
#     (the BIG-IPs need it to activate a licence)
#  2. optional: add the subnet to this host's Tailscale advertised routes (approve it once in your Tailscale admin console)
#  3. keep the subnet in the main routing table, so a host that accepts Tailscale routes still reaches its own lab
# --check: report only, change nothing.
cd "$(dirname "$0")"; . ./lib.sh
CHECK=0; [ "${1:-}" = --check ] && CHECK=1
NET=$MGMT_NET; LANIF=$(python3 -B -c 'import gen; print(gen.LAN_IF)')
say "1. masquerade $NET out of $LANIF"
if nft list chain ip clab_nat postrouting 2>/dev/null | grep -q "$NET"; then echo "  present"
elif [ $CHECK = 1 ]; then echo "  missing (would add)"
else nft add rule ip clab_nat postrouting ip saddr $NET oifname "$LANIF" masquerade && echo "  added"; fi
say "2. Tailscale subnet route $NET"
if ! command -v tailscale >/dev/null; then echo "  tailscale is not installed on $(hostname): skipped"
else
  cur=$(tailscale debug prefs 2>/dev/null | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get("AdvertiseRoutes") or []))')
  echo "  advertised now: ${cur:-none}"
  if echo ",$cur," | grep -q ",$NET,"; then echo "  already advertised"
  elif [ $CHECK = 1 ]; then echo "  would advertise: ${cur:+$cur,}$NET"
  else tailscale set --advertise-routes="${cur:+$cur,}$NET" && echo "  advertised: ${cur:+$cur,}$NET"
       echo "  ACTION FOR THE USER: approve $NET for this machine in the Tailscale admin console (Machines > $(hostname) > Edit route settings)"
  fi
  [ "$(sysctl -n net.ipv4.ip_forward)" = 1 ] && echo "  ip_forward on" || echo "  WARNING: net.ipv4.ip_forward is 0 (a subnet router needs it)"
  if ip rule show | grep -q "to $NET lookup main"; then echo "  local route rule present"
  elif [ $CHECK = 1 ]; then echo "  would add: ip rule to $NET lookup main (priority 5050)"
  else ip rule add to $NET lookup main priority 5050 && echo "  added: ip rule to $NET lookup main (priority 5050)"; fi
fi
say "3. from the LAN: route $NET via $(ip -4 -o addr show $LANIF | awk '{sub("/.*","",$4); print $4; exit}') ($(hostname) $LANIF)"

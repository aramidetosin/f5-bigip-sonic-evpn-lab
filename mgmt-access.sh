#!/bin/bash
# mgmt-access.sh [--check]: make the management network reachable; run by up.sh, re-runnable.
#  1. masquerade the management subnet out of the host's LAN interface (gen.py LAN_IF), so the nodes reach the internet
#     (the BIG-IPs need it to activate a licence)
#  2. print the route another machine on the LAN needs to reach the management subnet (via this host)
# --check: report only, change nothing.
cd "$(dirname "$0")"; . ./lib.sh
CHECK=0; [ "${1:-}" = --check ] && CHECK=1
NET=$MGMT_NET; LANIF=$(python3 -B -c 'import gen; print(gen.LAN_IF)')
say "1. masquerade $NET out of $LANIF"
if nft list chain ip clab_nat postrouting 2>/dev/null | grep -q "$NET"; then echo "  present"
elif [ $CHECK = 1 ]; then echo "  missing (would add)"
else nft add rule ip clab_nat postrouting ip saddr $NET oifname "$LANIF" masquerade && echo "  added"; fi
say "2. from the LAN: route $NET via $(ip -4 -o addr show $LANIF | awk '{sub("/.*","",$4); print $4; exit}') ($(hostname) $LANIF)"

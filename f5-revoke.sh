#!/bin/bash
# f5-revoke.sh [unit ...]: give a BIG-IP's licence back to F5 (tmsh revoke sys license) so its key can be activated again, before ./down.sh.
# Run on the lab server. Why not just the tmsh command: from part 14 on each unit has a DATA-PLANE default route (net route via the
# fabric), and TMM routes win over the management route for the box's own traffic, so DNS and activate.f5.com went into the fabric
# ("Cannot determine IP for license server"). This adds a /32 management route per name server and per licence-server
# address first (sys management-route lic-<ip>), revokes, removes them, and checks "Can't load license". Nothing else is changed.
cd "$(dirname "$0")"; . ./lib.sh
UNITS=("$@"); [ $# -eq 0 ] && UNITS=($F5_UNITS); RC=0
LIC=$(getent ahostsv4 activate.f5.com | awk '{print $1}' | sort -u | tr '\n' ' ')
[ -n "$LIC" ] || { say "activate.f5.com does not resolve on $(hostname)"; exit 1; }
for u in "${UNITS[@]}"; do
  out=$(ssh $SSHO -o BatchMode=yes admin@$C-$u "
    dns=\$(tmsh list sys dns name-servers | sed -n 's/.*name-servers { \(.*\) }/\1/p'); gw=\$(tmsh list sys management-route default gateway | awk '/gateway/{print \$2}')
    for d in \$dns $LIC; do tmsh create sys management-route lic-\$d network \$d/32 gateway \$gw 2>/dev/null; done
    echo y | timeout 300 tmsh revoke sys license 2>&1 | tail -1
    for d in \$dns $LIC; do tmsh delete sys management-route lic-\$d 2>/dev/null; done
    sleep 20; tmsh show sys license 2>&1 | head -1" 2>&1 | sed -E 's/[A-Z0-9]{5}(-[A-Z0-9]{5}){3}-[A-Z0-9]{7}/<key>/g')
  echo "$out" | grep -q "Can't load license" && say "$u: licence revoked ($(echo "$out" | head -1))" || { say "$u: NOT revoked: $out"; RC=1; }
done
exit $RC

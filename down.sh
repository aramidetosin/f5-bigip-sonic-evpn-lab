#!/bin/bash
# down.sh [--licences-revoked]: remove the lab. Order:
#   1 f5-save.sh: both BIG-IP configurations saved as UCS archives
#   2 licence check: refuses while a BIG-IP reports a licence, unless --licences-revoked (an evaluation key bound to a deleted VM is
#     lost: revoke it first in the web UI, System > License > Revoke)
#   3 containerlab destroy
cd "$(dirname "$0")"; . ./lib.sh
./secrets-init.sh >/dev/null
./f5-save.sh || { say "refusing: a BIG-IP config was not saved (./f5-save.sh), fix that first"; exit 1; }
if [ "${1:-}" != --licences-revoked ]; then
  for u in $F5_UNITS; do
    l=$(f5rest $u GET /mgmt/tm/sys/license | grep -o '"registrationKey":"[^"]*"' | head -1)
    [ -n "$l" ] && { say "refusing: $u still holds a licence. Revoke it (./f5-revoke.sh, or web UI: System > License > Revoke), then ./down.sh --licences-revoked"; exit 1; }
  done
fi
containerlab destroy -t $TOPO > logs/down.txt 2>&1 && say "lab removed (both BIG-IP configs saved as UCS archives)"

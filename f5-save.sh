#!/bin/bash
# f5-save.sh [unit ...]: save each BIG-IP's configuration as a UCS archive in $SECRETS/ucs/. Read/save only: it never changes the
# BIG-IP's configuration. UCS archives hold private keys, password hashes and the licence: keep them as secrets.
cd "$(dirname "$0")"; . ./lib.sh
UNITS=("$@"); [ $# -eq 0 ] && UNITS=($F5_UNITS)
OUT=$SECRETS/ucs; umask 077; mkdir -p $OUT; TS=$(date +%Y%m%d-%H%M%S); RC=0
for u in "${UNITS[@]}"; do
  n="$u-$TS"
  r=$(F5_TIMEOUT=900 f5rest $u POST /mgmt/tm/sys/ucs -H 'Content-Type: application/json' -d "{\"command\":\"save\",\"name\":\"$n\"}")
  echo "$r" | grep -q "\"name\":\"$n\"" || { say "$u: save FAILED: $(echo "$r" | head -c 200)"; RC=1; continue; }
  # download in 1 MiB chunks (the file-transfer endpoint needs Content-Range)
  f=$OUT/$n.ucs; : > $f; start=0; total=-1
  while :; do end=$((start + 1048575)); [ $total -ge 0 ] && [ $end -ge $total ] && end=$((total - 1))
    hdr=$(f5rest $u GET /mgmt/shared/file-transfer/ucs-downloads/$n.ucs -H "Content-Range: $start-$end/${total/-1/*}" -D - -o $f.part)
    cat $f.part >> $f; rm -f $f.part
    total=$(echo "$hdr" | tr -d '\r' | sed -n 's|^[Cc]ontent-[Rr]ange: [0-9]*-[0-9]*/\([0-9]*\)|\1|p' | tail -1)
    [ -n "$total" ] || { say "$u: download FAILED (no Content-Range)"; RC=1; break; }
    start=$((end + 1)); [ $start -ge $total ] && break; done
  [ -s $f ] && [ "$(stat -c %s $f)" = "$total" ] && say "$u: saved $(basename $f) ($total bytes)" || { say "$u: incomplete $f"; RC=1; }
  f5rest $u DELETE /mgmt/tm/sys/ucs/$n.ucs >/dev/null   # leave no extra archive on the BIG-IP's disk
done
exit $RC

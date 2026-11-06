#!/bin/bash
# sonic-apply.sh [switch ...]: configure the Dell SONiC switches. Waits for each VM's "Startup complete" and SSH, sets the hostname,
# and pushes configs/<switch>.cli through one chained sonic-cli call. Logs: logs/apply-<switch>.log.
cd "$(dirname "$0")"; . ./lib.sh; mkdir -p logs
SWS=("$@"); [ $# -eq 0 ] && SWS=($(awk '/kind: dell_sonic/{sub(":","",$1); print $1}' $TOPO))
one() {
  local n=$1
  until docker logs $C-$n 2>&1 | grep -q "Startup complete"; do sleep 20; done
  local t; for t in $(seq 1 30); do SW $n true 2>/dev/null && break; sleep 10; done
  SW $n true 2>/dev/null || { echo "$n: FAILED, no SSH to $(mip $n) after 5 min"; return 1; }
  SW $n 'sudo vtysh -c "show run" | grep -q "^hostname $(hostname)$" || { sudo systemctl restart bgp; sleep 25; }'
  mapfile -t CMDS < configs/$n.cli; KL $n "${CMDS[@]}" > logs/apply-$n.log 2>&1; local rc=$?
  local e; e=$(grep -c -i -E 'error|invalid|timed out|denied|refused' logs/apply-$n.log)
  if [ $rc != 0 ] || [ $e != 0 ]; then echo "$n: FAILED, rc $rc, $e error lines (logs/apply-$n.log)"; return 1; fi
  echo "$n: applied, 0 error lines"
}
RC=0; for n in "${SWS[@]}"; do one $n & done; for j in $(jobs -p); do wait $j || RC=1; done; exit $RC

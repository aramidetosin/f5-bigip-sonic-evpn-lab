#!/bin/bash
# gtm-wait.sh <unit> [timeout s]: after `tmsh modify sys provision gtm level nominal` on <unit>, prints each change of state with the
# seconds since this script started, until TMM is up again and gtmd runs (part 18): provisioning a module restarts TMM.
U=${1:?unit}; T=${2:-600}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
t0=$(date +%s); last=""
while [ $(( $(date +%s) - t0 )) -lt "$T" ]; do
  s=$(ssh $O admin@clab-f5-clos-dc-$U "bigstart status tmm gtmd 2>/dev/null | awk '{print \$1, \$2}' | tr '\n' ' '" 2>/dev/null)
  [ -n "$s" ] && [ "$s" != "$last" ] && { printf '+%3ds  %s\n' $(( $(date +%s) - t0 )) "$s"; last=$s; }
  case "$s" in "tmm run gtmd run "*) [ $(( $(date +%s) - t0 )) -gt 15 ] && { echo "gtmd running"; exit 0; };; esac
  sleep 3
done
echo "gtmd not running after $T s"; exit 1

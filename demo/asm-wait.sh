#!/bin/bash
# asm-wait.sh <unit> [timeout s]: from the lab server, after `tmsh modify sys provision asm level nominal` on <unit> (lb-f5a / lb-f5b),
# follows the ASM start in the unit's /var/log/asm (messages 01310053 written by asm_start) and prints each new step with the seconds
# since this script started, until "ASM started successfully" (part 16). Only lines written after the script started are counted.
U=${1:?unit}; T=${2:-600}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
S="ssh $O admin@clab-f5-clos-dc-$U"
n0=$($S "wc -l < /var/log/asm" 2>/dev/null); n0=${n0:-0}; t0=$(date +%s); last=""
while [ $(( $(date +%s) - t0 )) -lt "$T" ]; do
  l=$($S "tail -n +$((n0 + 1)) /var/log/asm | grep 01310053 | tail -1" 2>/dev/null | sed 's/.*01310053:[0-9]: //' | cut -c1-70)
  if [ -n "$l" ] && [ "$l" != "$last" ]; then printf '+%3ds  %s\n' $(( $(date +%s) - t0 )) "$l"; last=$l; fi
  case "$l" in "ASM started successfully"*) exit 0;; esac
  sleep 3
done
echo "no 'ASM started successfully' after $T s"; exit 1

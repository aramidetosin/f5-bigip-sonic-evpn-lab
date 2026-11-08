#!/bin/bash
# part10-reset.sh: put lb-f5a and the log-server back to the state BEFORE part 10 (remote logging and SNMP). Removes, in dependency
# order: the request-log profile on vs-web, the HSL filter/publisher/destinations, pool-hsl, the remote syslog server, the SNMP trap
# destination, the extra SNMP allowed address and port lockdown udp:161 on self-internal. On the log-server: the copied F5 MIB files
# (F5's, never kept in this repo) and old lines (moved aside to *.old, not deleted). lb-f5b is not touched.
set -u
B=${1:-lb-f5a}
L="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR admin@clab-f5-clos-dc-$B"
LS=clab-f5-clos-dc-log-server
for c in "modify ltm virtual vs-web profiles delete { reqlog-web }" "delete ltm profile request-log reqlog-web" \
         "delete sys log-config filter ltm-to-hsl" "delete sys log-config publisher hsl-pub" \
         "delete sys log-config destination remote-syslog hsl-syslog" "delete sys log-config destination remote-high-speed-log hsl-dest" \
         "delete ltm pool pool-hsl" "modify sys syslog remote-servers none" "modify sys snmp traps delete { logsrv-trap }" \
         "modify sys snmp allowed-addresses replace-all-with { 127.0.0.0/8 }" "modify net self self-internal allow-service none"; do
  $L "tmsh $c" 2>&1 | grep -v "was not found" || true
done
$L "tmsh save sys config" >/dev/null && echo "$B: part 10 objects removed, saved"
docker exec $LS sh -c 'rm -f /usr/share/snmp/mibs/F5-BIGIP-*-MIB.txt; sed -i "/F5-BIGIP-COMMON-MIB/d" /etc/snmp/snmp.conf 2>/dev/null
  for f in /var/log/remote/*.log /var/log/snmptraps.log; do [ -s "$f" ] && cat "$f" >> "$f.old" && : > "$f"; done
  pkill -x snmptrapd; sleep 1; snmptrapd -n -c /etc/snmp/snmptrapd.conf -Lf /var/log/snmptraps.log udp:10.20.0.20:162'
echo "$LS: F5 MIBs removed, logs moved to *.old, snmptrapd restarted"

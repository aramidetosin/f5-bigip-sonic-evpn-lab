#!/bin/bash
# f5-mibs.sh [bigip]: copy the BIG-IP's own F5 MIB files (F5-BIGIP-*.txt, /usr/share/snmp/mibs on the BIG-IP) into the log-server,
# so snmpwalk and snmptrapd there print names (F5-BIGIP-LOCAL-MIB::ltmPoolMbrStatusAvailState) instead of numeric OIDs.
# The files are F5's: they are copied at run time from the box, never kept in this project. Part 10 (lectures 46-47).
set -e
B=${1:-lb-f5a}
LS=clab-f5-clos-dc-log-server
for m in COMMON SYSTEM LOCAL; do
  ssh -o ConnectTimeout=8 admin@clab-f5-clos-dc-$B "cat /usr/share/snmp/mibs/F5-BIGIP-$m-MIB.txt" | docker exec -i $LS sh -c "cat > /usr/share/snmp/mibs/F5-BIGIP-$m-MIB.txt"
done
docker exec $LS sh -c 'mkdir -p /etc/snmp; grep -q "^mibs" /etc/snmp/snmp.conf 2>/dev/null || echo "mibs +F5-BIGIP-COMMON-MIB:F5-BIGIP-SYSTEM-MIB:F5-BIGIP-LOCAL-MIB" >> /etc/snmp/snmp.conf'
# snmptrapd reads the MIBs at start: restart it with the same arguments as tools-up.sh
docker exec $LS sh -c 'pkill -x snmptrapd; sleep 1; snmptrapd -n -c /etc/snmp/snmptrapd.conf -Lf /var/log/snmptraps.log udp:10.20.0.20:162'
echo "F5 MIBs loaded on $LS"

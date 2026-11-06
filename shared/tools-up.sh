#!/bin/bash
# tools-up.sh: the log-server: network and SSH as host-up.sh, then rsyslog (udp + tcp 514, one file per sender in /var/log/remote/)
# and snmptrapd (udp 162, traps in /var/log/snmptraps.log); snmpwalk / snmpget for polling the BIG-IPs.
set -e
NOHTTP=1 bash /shared/host-up.sh
ADDR=${IP%/*}
mkdir -p /var/log/remote
cat > /etc/rsyslog.conf <<EOF
global(net.enableDNS="off")
module(load="imudp")
module(load="imtcp")
input(type="imudp" address="$ADDR" port="514" ruleset="remote")
input(type="imtcp" address="$ADDR" port="514" ruleset="remote")
template(name="bysender" type="string" string="/var/log/remote/%fromhost-ip%.log")
ruleset(name="remote") { action(type="omfile" dynaFile="bysender") }
EOF
pgrep -x rsyslogd >/dev/null || rsyslogd
mkdir -p /etc/snmp
printf 'disableAuthorization yes\n' > /etc/snmp/snmptrapd.conf
pgrep -x snmptrapd >/dev/null || snmptrapd -n -c /etc/snmp/snmptrapd.conf -Lf /var/log/snmptraps.log udp:$ADDR:162

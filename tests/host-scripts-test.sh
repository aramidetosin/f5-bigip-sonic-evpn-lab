#!/bin/bash
# host-scripts-test.sh: test the Linux node images and startup scripts in plain Docker, without deploying the lab.
cd "$(dirname "$0")/.."; L=$PWD
S=${1:-}; SCRATCH=""
if [ -z "$S" ]; then SCRATCH=$(mktemp -d); S=$SCRATCH/secrets; F5LAB_SECRETS=$S ./secrets-init.sh >/dev/null; fi
P=0; F=0
t() { local d=$1 out=$2 want=$3; if echo "$out" | grep -q -- "$want"; then echo "  PASS  $d"; P=$((P+1)); else echo "  FAIL  $d (wanted '$want')"; echo "$out" | sed 's/^/        /' | tail -5; F=$((F+1)); fi; }
run() { local name=$1 img=$2 cmd=$3; shift 3
  docker run --rm --cap-add NET_ADMIN --network none --hostname $name -v $L/shared:/shared:ro "$@" --entrypoint sh $img -c "$cmd" 2>&1; }
echo "== server1: f5lab/web:1, BOND=1, http + https"
o=$(run server1 f5lab/web:1 'ip link add eth1 type dummy; ip link add eth2 type dummy; bash /shared/server-up.sh >/dev/null 2>&1; sleep 1
  grep -m1 "Bonding Mode" /proc/net/bonding/bond0; echo "http=$(curl -s http://10.20.0.11/)"; echo "health=$(curl -s http://10.20.0.11/health)"
  echo "https=$(curl -s --cacert /run/f5lab/tls/ca.crt --resolve server1.f5lab.test:443:10.20.0.11 https://server1.f5lab.test/)"
  curl -s -H "X-Forwarded-For: 10.10.0.11" -b "BIGipServerpool=abc" http://10.20.0.11/ | sed -n "s/^\(client seen\|x-forwarded-for\|cookie\):  */WHOAMI-\1=/p"
  curl -s --cacert /run/f5lab/tls/ca.crt --resolve server1.f5lab.test:443:10.20.0.11 https://server1.f5lab.test/ | sed -n "s/^scheme: */WHOAMI-scheme=/p"
  curl -s -H "Accept: text/html" http://10.20.0.11/ | grep -o "background:#[0-9a-f]*" | sed "s/^/WHOAMI-html-/"
  curl -sI http://10.20.0.11/ | grep -i x-server; netstat -ltn | grep -q ":22 " && echo sshd-running' \
  -v $S/tls:/run/f5lab/tls:ro -v $S/host.env:/run/f5lab/host.env:ro -e IP=10.20.0.11/24 -e GW=10.20.0.1 -e BOND=1 -e ROLE=web)
t "bond0 is 802.3ad" "$o" "802.3ad"; t "http answers 'server1 10.20.0.11'" "$o" "http=server1 10.20.0.11"; t "/health answers OK" "$o" "health=OK"
t "https with the lab CA" "$o" "https=server1 10.20.0.11"; t "X-Server header" "$o" "X-Server: server1"; t "whoami: client address seen" "$o" "WHOAMI-client seen=10.20.0.11:"
t "whoami: X-Forwarded-For" "$o" "WHOAMI-x-forwarded-for=10.10.0.11"; t "whoami: cookie" "$o" "WHOAMI-cookie=BIGipServerpool=abc"
t "whoami: browser gets server1 blue (#1971c2)" "$o" "WHOAMI-html-background:#1971c2"
t "whoami: https + TLS version" "$o" "WHOAMI-scheme=https TLSv1.[23]"; t "sshd running" "$o" "sshd-running"
echo "== sorry-server: maintenance page, http + https"
o=$(run sorry-server f5lab/web:1 'ip link add eth1 type dummy; bash /shared/server-up.sh >/dev/null 2>&1; sleep 1
  echo "http=$(curl -s http://10.20.30.30/)"; echo "https=$(curl -s --cacert /run/f5lab/tls/ca.crt --resolve sorry.f5lab.test:443:10.20.30.30 https://sorry.f5lab.test/)"' \
  -v $S/tls:/run/f5lab/tls:ro -e IP=10.20.30.30/24 -e GW=10.20.30.1 -e BOND=0 -e ROLE=sorry)
t "http maintenance page" "$o" "http=maintenance"; t "https maintenance page" "$o" "https=maintenance"
echo "== log-server: f5lab/tools:1, syslog 514 + snmptrapd 162"
o=$(run log-server f5lab/tools:1 'exec bash -c '"'"'ip link add eth1 type dummy; bash /shared/tools-up.sh >/dev/null 2>&1; sleep 1; netstat -lun
  echo "<14>hello-from-f5lab" > /dev/udp/10.20.0.20/514; snmptrap -v 2c -c public 10.20.0.20:162 "" 1.3.6.1.6.3.1.1.5.1 >/dev/null 2>&1; sleep 3
  echo "syslog=$(cat /var/log/remote/*.log 2>/dev/null | tail -1)"; echo "trap=$(grep -c coldStart /var/log/snmptraps.log 2>/dev/null)"'"'"'' \
  -e IP=10.20.0.20/24 -e GW=10.20.0.1 -e BOND=0)
t "udp 514 listening" "$o" "10.20.0.20:514"; t "udp 162 listening" "$o" "10.20.0.20:162"
t "a syslog line lands in /var/log/remote" "$o" "hello-from-f5lab"; t "an SNMP trap is logged" "$o" "trap=[1-9]"
echo "== lan-switch: scd/host:1, BOND=1 + BRIDGE eth3-eth5"
o=$(run lan-switch scd/host:1 'for i in 1 2 3 4 5; do ip link add eth$i type dummy; done; bash /shared/host-up.sh >/dev/null 2>&1
  for i in bond0 eth3 eth4 eth5; do echo "$i master=$(basename $(readlink /sys/class/net/$i/master))"; done; ip -br addr show br0' \
  -e IP=10.10.0.5/24 -e GW=10.10.0.1 -e BOND=1 -e "BRIDGE=eth3 eth4 eth5")
t "bond0 in br0" "$o" "bond0 master=br0"; t "eth5 in br0" "$o" "eth5 master=br0"; t "br0 holds 10.10.0.5" "$o" "10.10.0.5/24"
echo "== pc1: scd/host:1, BOND=0, trusts nothing but has the CA file"
o=$(run pc1 scd/host:1 'ip link add eth1 type dummy; bash /shared/host-up.sh >/dev/null 2>&1; ip -br addr show eth1; ip route | grep default; ls /run/f5lab/ca.crt' \
  -v $S/tls/ca.crt:/run/f5lab/ca.crt:ro -e IP=10.10.0.11/24 -e GW=10.10.0.1 -e BOND=0)
t "eth1 holds 10.10.0.11" "$o" "10.10.0.11/24"; t "default via 10.10.0.1" "$o" "default via 10.10.0.1"; t "CA file mounted" "$o" "/run/f5lab/ca.crt"
[ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
echo "host-scripts-test: $P PASS, $F FAIL"; [ $F = 0 ]

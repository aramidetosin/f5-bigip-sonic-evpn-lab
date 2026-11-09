#!/bin/bash
# validate.sh: prove the non-F5 side works (one PASS / FAIL line per check). Read-only. The BIG-IPs are checked for management
# reachability only.
cd "$(dirname "$0")"; . ./lib.sh
P=0; F=0
ok() { echo "  PASS  $*"; P=$((P+1)); }
ko() { echo "  FAIL  $*"; F=$((F+1)); }
chk() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d"; fi; }
nochk() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ko "$d (it must fail)"; else ok "$d"; fi; }
say "underlay + EVPN: established eBGP sessions per switch (spines 6, leaves 2)"
for s in $(awk '/kind: dell_sonic/{sub(":","",$1); print $1}' $TOPO); do
  want=2; case $s in spine*) want=6;; esac
  n=$(SW $s 'sudo vtysh -c "show bgp summary json"' 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin); p=d.get("ipv4Unicast",{}).get("peers",{}); print(sum(1 for v in p.values() if v.get("state")=="Established"))' 2>/dev/null)
  [ "${n:-0}" -ge $want ] && ok "$s: $n underlay sessions" || ko "$s: ${n:-0} underlay sessions (want $want)"
done
say "firewall transits: the service leaves peer with fw-pa in both VRFs"
for s in leaf1a-service leaf1b-service; do for v in Vrf-Outside Vrf-App; do
  st=$(SW $s "sudo vtysh -c 'show bgp vrf $v summary json'" 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin); p=d.get("ipv4Unicast",{}).get("peers",{}); print(" ".join(k for k,v in p.items() if v.get("state")=="Established"))' 2>/dev/null)
  echo "$st" | grep -q "10.254.[12].3" && ok "$s $v: fw-pa Established" || ko "$s $v: fw-pa not Established"
done; done
say "hosts reach their anycast gateway"
for h in server1 server2 server3 log-server; do chk "$h > 10.20.0.1" X $h "ping -c2 -W2 10.20.0.1"; done
chk "sorry-server > 10.20.30.1" X sorry-server "ping -c2 -W2 10.20.30.1"
for h in pc1 pc2 pc3; do chk "$h > 10.10.0.1" X $h "ping -c2 -W2 10.10.0.1"; done
# the kindest/node image has no ping: a routed fetch (VLAN 120 > the anycast gateway > the sorry-server in VLAN 130) proves the same
for h in $(. shared/k8s-values.sh; echo $K8S_NODES); do chk "$h > 10.20.0.1 > sorry-server http (routed)" X $h "curl -sf --max-time 5 -o /dev/null http://10.20.30.30/"; done
say "kubernetes: every node Ready"
n=$(kc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l); [ "$n" -eq 3 ] && ok "$n nodes Ready" || ko "$n nodes Ready (want 3)"
say "through the firewall: users reach the published range only"
chk "pc1 > sorry-server http (10.20.30.30:80, through fw-pa)" X pc1 "curl -sf --max-time 5 http://10.20.30.30/"
chk "pc1 > sorry-server https with the lab CA" X pc1 "curl -sf --max-time 5 --cacert /run/f5lab/ca.crt --resolve sorry.f5lab.test:443:10.20.30.30 https://sorry.f5lab.test/"
nochk "pc1 > server1 10.20.0.11 directly" X pc1 "curl -sf --max-time 5 http://10.20.0.11/"
nochk "pc1 > sorry-server ssh (only 80 / 443 / ping allowed)" X pc1 "nc -z -w 5 10.20.30.30 22"
say "servers answer (http, https) inside Vrf-App"
for h in server1 server2 server3; do chk "server2 > $h http" X server2 "curl -sf --max-time 5 http://$(python3 -B -c "import gen; print(gen.APP_HOSTS['$h'][2])")/"; done
chk "log-server: syslog udp/514 listening" X log-server "netstat -lun | grep -q ':514 '"
chk "log-server: snmptrapd udp/162 listening" X log-server "netstat -lun | grep -q ':162 '"
say "PC web desktops: Firefox answers on :3001 (https, login required)"
for h in pc1 pc2 pc3; do chk "$h web desktop https $(mip $h):3001" sh -c "curl -sk -o /dev/null -w '%{http_code}' --max-time 8 https://$(mip $h):3001/ | grep -q -E '^(200|401)$'"; done
say "BIG-IP management only: https + ssh answer on the management address"
for u in $F5_UNITS; do
  chk "$u https $(mip $u)" curl -sk -o /dev/null --max-time 8 "https://$(mip $u)/"
  chk "$u ssh $(mip $u):22" timeout 5 bash -c "</dev/tcp/$(mip $u)/22"
done
mkdir -p logs; say "management access"; ./mgmt-access.sh --check > logs/mgmt-access-check.txt 2>&1   # detail in the log, a summary on screen
grep -E "missing|WARNING|not installed" logs/mgmt-access-check.txt || echo "  ready (masquerade, subnet route, LAN route)"
say "validate: $P PASS, $F FAIL"; [ $F = 0 ]

#!/bin/bash
# up.sh [--check]: build the lab from scratch, as root, from this folder. Everything that is not F5 is configured; the BIG-IPs come
# up blank and unlicensed, with only their management interface reachable (SSH + web UI).
#   0 preflight   root, tools, images (builds the small Linux images from images/), a free management subnet, RAM, gen.py, secrets
#   1 deploy      containerlab deploy --reconfigure (refused while a BIG-IP of this lab runs: ./down.sh saves its config first)
#   2 access      mgmt-access.sh: masquerade, optional Tailscale subnet route, local route rule
#   3 switches    sonic-apply.sh: configs/<switch>.cli on all 8
#   4 firewall    pa-load.sh: bootstrap/fw-pa.xml (replace + commit)
#   5 BIG-IP      wait until both management interfaces answer HTTPS and SSH (nothing is configured on them), then SSH keys
#   6 validate    validate.sh
# --check stops after stage 0.
cd "$(dirname "$0")"; FAIL=0
say() { echo "[$(date +%H:%M:%S)] $*"; }
bad() { say "PREFLIGHT FAIL: $*"; FAIL=1; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
say "0 preflight"
for t in containerlab docker sshpass python3 openssl nft curl; do command -v $t >/dev/null || bad "$t missing"; done
python3 -B gen.py || bad "gen.py"
. ./lib.sh 2>/dev/null
for i in vrnetlab/dell_sonic:4.6.0 vrnetlab/paloalto_pa-vm:12.1.2 vrnetlab/f5_bigip-ve:17.5.1.11-0.0.12 $(. shared/k8s-values.sh; echo $K8S_IMAGE); do
  docker image inspect $i >/dev/null 2>&1 || bad "image $i missing (build it with vrnetlab)"; done
while read img dir; do docker image inspect $img >/dev/null 2>&1 && continue
  say "building $img from $dir"; docker build --network host -q -t $img $dir >/dev/null || bad "build $img"; done < images.txt
say "management subnet $MGMT_NET must be free (no docker network, no route) unless this lab already holds it"
if ! docker network inspect clab-$LAB >/dev/null 2>&1; then
  docker network ls -q | xargs -r docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' | grep -w "$MGMT_NET" && bad "$MGMT_NET used by a docker network"
  ip route | grep -q "^$MGMT_NET" && bad "$MGMT_NET already routed on this host"
fi
say "resources: $(free -g | awk '/Mem:/{print $7" GiB available"}'); need about 90 GiB (2 x 16 BIG-IP, 8 PA-VM, 6 x 6 leaves, 2 spines, hosts)"
a=$(free -g | awk '/Mem:/{print $7}'); [ "$a" -ge ${NEED_GIB:-100} ] || bad "only $a GiB available (NEED_GIB=${NEED_GIB:-100}, 10 kept free)"
./secrets-init.sh >/dev/null || bad "secrets-init.sh"
for u in $F5_UNITS; do docker inspect $C-$u >/dev/null 2>&1 && [ "${1:-}" != --check ] && \
  bad "$u is deployed: ./down.sh first (it saves your BIG-IP config and checks the licence is revoked); a redeploy deletes the VM"; done
[ $FAIL = 0 ] || { say "preflight failed"; exit 1; }
[ "${1:-}" = --check ] && { ./mgmt-access.sh --check; say "preflight OK (--check: not deploying)"; exit 0; }
mkdir -p logs
say "1a kubernetes node /var"; ./k8s-seed.sh || exit 1
say "1 deploy (--reconfigure)"
containerlab deploy -t $TOPO --reconfigure > logs/deploy.txt 2>&1 || { tail -20 logs/deploy.txt; exit 1; }
say "2 management access"; ./mgmt-access.sh > logs/mgmt-access.txt 2>&1   # the detail goes to the log; the screen shows a summary
grep -E "ACTION|WARNING|not installed" logs/mgmt-access.txt; say "management access ready (masquerade, subnet route, LAN route)"
say "3 switch configs"; ./sonic-apply.sh | tee logs/apply.txt
say "4 firewall"; ./pa-load.sh | tee logs/pa-load.txt
say "4b kubernetes"; ./k8s-up.sh | tee logs/k8s-up.txt
say "5 BIG-IP management (no configuration)"
for u in $F5_UNITS; do
  for i in $(seq 1 90); do
    h=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$(mip $u)/"); s=$(timeout 5 bash -c "</dev/tcp/$(mip $u)/22" 2>/dev/null && echo open)
    [ "$h" != 000 ] && [ "$s" = open ] && break; sleep 20; done
  say "$u: https $h, ssh ${s:-closed} on $(mip $u)"
done
say "5b ssh keys"; ./ssh-keys.sh | tee logs/ssh-keys.txt
say "6 validate"; ./validate.sh | tee logs/validate.txt
say "done. BIG-IP web UI: https://$(mip lb-f5a)  https://$(mip lb-f5b)  (user admin; the password: see USING-THE-LAB.md)"

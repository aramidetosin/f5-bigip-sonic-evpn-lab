# lib.sh: shared helpers for the lab scripts (source it). No password appears in any script: credentials live in root-only env files
# under $SECRETS (mode 600), read into the environment and handed to tools by environment or stdin, never on a command line, never
# printed. secrets-init.sh creates them.
LAB=f5-clos-dc; TOPO=$LAB.clab.yml; C=clab-$LAB
SECRETS=${F5LAB_SECRETS:-/root/f5-clos-dc-secrets}
MGMT_NET=$(awk -F': ' '/ipv4-subnet/{print $2}' $TOPO 2>/dev/null)
# appliances.env: SONIC_USER SONIC_PW (Dell SONiC switches), PA_USER PA_PW (fw-pa). The BIG-IPs keep their own <unit>.env.
if [ -r "$SECRETS/appliances.env" ]; then set -a; . "$SECRETS/appliances.env"; set +a
else echo "lib.sh: $SECRETS/appliances.env is missing or unreadable (run ./secrets-init.sh as root)" >&2; fi
mip() { awk -v n="$1" '$2==n{print $1}' mgmt-hosts.txt; }                       # management address of a node
X() { docker exec $C-$1 sh -c "$2" 2>&1; }                                       # run in a linux node
kc() { docker exec -i $C-k8s-cp kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }   # kubectl on the lab cluster
SSHO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# sshpass -e reads SSHPASS from the environment: the password never appears in a process list
SW() { SSHPASS="$SONIC_PW" sshpass -e ssh $SSHO -o ConnectTimeout=10 "${SONIC_USER:-admin}"@"$(mip $1)" "$2" </dev/null; }
KL() { local s=$1; shift; local a=""; for c in "$@"; do a+=" -c \"$c\""; done; SW $s "sonic-cli $a"; }   # KLISH, chained -c (stdin is ignored)
PA=$(awk '$2=="fw-pa"{print $1}' mgmt-hosts.txt 2>/dev/null)
# the PAN-OS API key: the password goes in the POST body from stdin, not in the URL (URLs land in logs)
pakey() { printf '%s' "$PA_PW" | curl -sk --data-urlencode "user=${PA_USER:-admin}" --data-urlencode "password@-" "https://$PA/api/?type=keygen" \
          | sed -n 's|.*<key>\(.*\)</key>.*|\1|p'; }
paop() { curl -sk "https://$PA/api/?type=op&key=$(pakey)" --data-urlencode "cmd=$1"; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
F5_UNITS="lb-f5a lb-f5b"
f5pw() { sed -n 's/^PASSWORD=//p' "$SECRETS/$1.env"; }
f5rest() { local u=$1 m=$2 p=$3; shift 3
  printf 'user = "admin:%s"\n' "$(f5pw $u)" | curl -sk --max-time ${F5_TIMEOUT:-60} -K - -X "$m" "https://$(mip $u)$p" "$@"; }

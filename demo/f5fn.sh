# f5fn.sh: shortcuts for the part 12 demos, run from the lab server (source it: . ./f5fn.sh)
#   f5 <command>        runs a command on lb-f5a (bash, as admin) over SSH
#   pc1 <command>       runs a command on pc1 over SSH
#   irule <file.tcl>    loads an iRule file into lb-f5a, named after the file (irules/ir-headers.tcl > ltm rule ir-headers);
#                       loading again replaces the rule's text (tmsh load sys config merge)
LBA=admin@clab-f5-clos-dc-lb-f5a
f5()  { ssh $LBA "$@"; }
pc1() { ssh -n admin@172.21.32.111 "$@"; }
irule() {
  local n; n=$(basename "$1" .tcl)
  { echo "ltm rule $n {"; cat "$1"; echo "}"; } |
    ssh $LBA "cat > /var/tmp/$n.conf && tmsh load sys config merge file /var/tmp/$n.conf >/dev/null; rc=\$?; rm -f /var/tmp/$n.conf; [ \$rc = 0 ] && echo loaded ltm rule $n"
}
# part 13: the second unit and two leaves
#   f5b <command>       runs a command on lb-f5b
#   leaf1a / leaf2a <command>   runs a SONiC CLI command on leaf1a-service (the BIG-IPs' external VLAN) / leaf2a-server (a remote VTEP)
LBB=admin@clab-f5-clos-dc-lb-f5b
f5b()    { ssh $LBB "$@"; }
leaf1a() { ssh admin@172.21.32.21 "$@"; }
leaf2a() { ssh admin@172.21.32.23 "$@"; }
# part 14
#   zebos <unit> <file>   loads a ZebOS (imish) config file into route domain 0 on lb-f5a or lb-f5b, and saves it (write memory)
#   border <command>      runs a SONiC CLI command on leaf3a-border (where the clients' VRF meets the fabric)
zebos() { ssh admin@clab-f5-clos-dc-$1 "cat > /var/tmp/zebos.conf && imish -r 0 -f /var/tmp/zebos.conf && imish -r 0 -e 'write memory' >/dev/null && echo loaded $2 on $1" < "$2"; }
border() { ssh admin@172.21.32.25 "$@"; }
leaf1b() { ssh admin@172.21.32.22 "$@"; }
# part 16
#   waf <command> [args]  runs waf-rest.sh (Advanced WAF over the unit's local iControl REST) on lb-f5a, or on $WAFU (lb-f5b)
#   srvlog [n]            the last n access-log lines of server1-3 (did a request reach the pool?)
waf() { ssh admin@clab-f5-clos-dc-${WAFU:-lb-f5a} POLICY=${POLICY:-waf-app} bash -s -- "$@" < waf-rest.sh; }
srvlog() { for s in server1 server2 server3; do docker exec clab-f5-clos-dc-$s tail -n ${1:-3} /var/log/nginx/access.log | sed "s/^/$s: /"; done; }
#   srvcount <text>       how many requests containing <text> server1-3 have logged in total (before / after: did it reach the pool?)
srvcount() { local n=0 c; for s in server1 server2 server3; do c=$(docker exec clab-f5-clos-dc-$s grep -cF "$1" /var/log/nginx/access.log); n=$((n + c)); done; echo "requests containing '$1' logged by server1-3: $n"; }
# part 17
#   f5merge <file.conf>   merges a tmsh config file into lb-f5a, or $F5U (tmsh load sys config merge), like irule but for any objects
f5merge() { ssh admin@clab-f5-clos-dc-${F5U:-lb-f5a} "cat > /var/tmp/merge.conf && tmsh load sys config merge file /var/tmp/merge.conf >/dev/null; rc=\$?; rm -f /var/tmp/merge.conf; [ \$rc = 0 ] && echo merged $(basename "$1")" < "$1"; }
#   wafimport <policy.json>   copies a declarative WAF policy file to lb-f5a (or $WAFU) and imports it (waf-rest.sh import)
#   oapiserve [s]         serves lab/shared over HTTP on the lab server's management address (172.21.32.1:8099) for s seconds,
#                         so a BIG-IP can fetch the OpenAPI file a declarative policy links to
wafimport() { ssh admin@clab-f5-clos-dc-${WAFU:-lb-f5a} "cat > /var/tmp/waf-import.json" < "$1" && waf import /var/tmp/waf-import.json; }
oapiserve() { (timeout ${1:-180} python3 -m http.server 8099 --bind 172.21.32.1 -d "$(cd "$(dirname "${BASH_SOURCE[0]}")/../shared" && pwd)" >/tmp/oapi-http.log 2>&1 &); sleep 1; echo "serving lab/shared on http://172.21.32.1:8099 for ${1:-180} s"; }
node()    { docker exec -i clab-f5-clos-dc-$1 "${@:2}"; }
kubectl() { docker exec -i clab-f5-clos-dc-k8s-cp kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }

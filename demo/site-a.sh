#!/bin/bash
# site-a.sh <action>: makes (or repairs) one failure of site A for the GSLB failover tests of part 19 and writes the moment it did so
# (epoch) to /tmp/gslb-t0, for gslb-timeline.sh.
#   app-fail   site A loses its servers: on server1-3, a blackhole route for site A's internal addresses (lb-f5a's self IP 10.20.0.241,
#              floating 10.20.0.240, SNAT 10.20.0.201-202). The servers still receive, but no reply reaches site A, so its monitors
#              and its traffic fail. Site B (10.20.0.242 and its automap) is untouched.
#   app-ok     removes those routes.
#   drain      an administrator disables site A's virtual server vs-rhi (planned maintenance); undrain enables it again.
#   dns-drain  BIG-IP DNS stops answering site A: its member site-a:vs-rhi of GSLB pool pool-a disabled (the config syncs to
#              both BIG-IP DNS); dns-undrain enables it again.
#   any-drain  (part 20) the anycast virtual server vs-any disabled on site A; measured: the virtual address stays available,
#              so RHI keeps advertising 10.20.5.200 and new flows hashed to site A are refused; any-undrain enables it.
#   any-withdraw (part 20) stop advertising 10.20.5.200 from site A (virtual address route-advertisement disabled); any-advertise:
#              back to route-advertisement any.
#   isolate    site A disappears: lb-f5a's data interfaces 1.1-1.3 disabled (fabric, servers, and the link to site B that carries
#              iQuery); management stays. connect enables them again.
A=${1:?app-fail|app-ok|drain|undrain|dns-drain|dns-undrain|any-drain|any-undrain|any-withdraw|any-advertise|isolate|connect}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SITEA="10.20.0.240 10.20.0.241 10.20.0.201 10.20.0.202"
mark() { date +%s.%N | cut -c1-14 > /tmp/gslb-t0; echo "t0 = $(date -u +%H:%M:%S) UTC: $1"; }   # t0 = when the action starts
srv() { for s in server1 server2 server3; do for a in $SITEA; do docker exec clab-f5-clos-dc-$s ip route $1 blackhole $a/32 2>/dev/null; done; done; }
f5a() { ssh $O admin@clab-f5-clos-dc-lb-f5a "$@" 2>&1 | grep -v api-status; }
case $A in
  app-fail) mark "site A cut off from server1-3 (blackhole routes on the servers)"; srv add;;
  app-ok)   mark "site A reaches server1-3 again"; srv del;;
  drain)    mark "vs-rhi disabled on lb-f5a"; f5a 'tmsh modify ltm virtual vs-rhi disabled';;
  undrain)  mark "vs-rhi enabled on lb-f5a"; f5a 'tmsh modify ltm virtual vs-rhi enabled';;
  dns-drain)   mark "GSLB member site-a:vs-rhi disabled"; f5a 'tmsh modify gtm pool a pool-a members modify { site-a:/Common/vs-rhi { disabled } }';;
  dns-undrain) mark "GSLB member site-a:vs-rhi enabled"; f5a 'tmsh modify gtm pool a pool-a members modify { site-a:/Common/vs-rhi { enabled } }';;
  any-drain)   mark "vs-any disabled on lb-f5a"; f5a 'tmsh modify ltm virtual vs-any disabled';;
  any-undrain) mark "vs-any enabled on lb-f5a"; f5a 'tmsh modify ltm virtual vs-any enabled';;
  any-withdraw)  mark "10.20.5.200 no longer advertised by lb-f5a"; f5a 'tmsh modify ltm virtual-address 10.20.5.200 route-advertisement disabled';;
  any-advertise) mark "10.20.5.200 advertised by lb-f5a again"; f5a 'tmsh modify ltm virtual-address 10.20.5.200 route-advertisement any';;
  isolate)  mark "lb-f5a interfaces 1.1-1.3 disabled"; f5a 'tmsh modify net interface 1.1 1.2 1.3 disabled';;
  connect)  mark "lb-f5a interfaces 1.1-1.3 enabled"; f5a 'tmsh modify net interface 1.1 1.2 1.3 enabled';;
  *) echo "unknown action $A"; exit 1;;
esac

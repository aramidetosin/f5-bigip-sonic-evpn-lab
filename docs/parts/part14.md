# Part 14: BGP and route health injection into SONiC

| | |
|---|---|
| Video | [F5 BIG-IP BGP Route Health Injection with SONiC EVPN (Part 14)](https://youtu.be/zOHVOkgX25U) (public from 2026-12-08 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-bgp-route-health-injection/) (from 2026-12-08 04:00 UTC) |
| Previous / next | [Part 13](part13.md) / [Part 15](part15.md) |

## Goal

Both BIG-IPs' external arms land on leaf1a, so a dead leaf1a takes the ARP VIP down whatever the HA pair does. I time that, then
add the routed design: a tagged transit from each unit to each service leaf, eBGP with BFD on all four sessions, and a second VIP,
10.20.5.10, advertised as a /32 only by the active unit and only while its virtual server is available (route health injection).
On the way, the routes the leaves send back break both VIPs; a deny-all inbound route map fixes it. Then a dead leaf, an HA
failover and a dead pool, each measured as routes.

## Starting state

- The lab is up and `./validate.sh` reports every check PASS.
- Part 13's end state: lb-f5a and lb-f5b in the sync-failover group dg-lb (auto-sync enabled), traffic-group-1 MAC masquerade
  02:00:0a:14:1e:0a, **lb-f5b ACTIVE, lb-f5a STANDBY**, In Sync; vs-web and vs-web-https on 10.20.30.100 with pool-web and SNAT pool
  snat-web (10.20.0.201, .202) on both units. No transit VLANs on the BIG-IPs, routing protocols off in route domain 0.
- The fabric side is already part of the lab: on leaf1a-service, Vlan3005 10.254.5.1/29, and on leaf1b-service, Vlan3007
  10.254.7.1/29, both in Vrf-App, with BGP neighbours 10.254.5.3/.4 and 10.254.7.3/.4 (AS 65020, keepalive 3, hold time 9, BFD).
  The firewall already accepts and publishes 10.20.5.0/24 (with /32s inside it), so no firewall change is needed.
- Both units are used in this part.
- To get here, follow the earlier parts' guides, or restore the UCS saved at the end of part 13 on both units with
  `./f5-restore.sh`. Save both units before you start: `./f5-save.sh`.

## Values used in this part

| Object | Value |
|---|---|
| Transit to leaf1a | VLAN transit-leaf1a, interface 1.1 tagged, tag 3005, 10.254.5.0/29: leaf1a .1, lb-f5a .3, lb-f5b .4 |
| Transit to leaf1b | VLAN transit-leaf1b, interface 1.2 tagged, tag 3007, 10.254.7.0/29: leaf1b .1, lb-f5a .3, lb-f5b .4 |
| Transit self IPs | transit-leaf1a-self, transit-leaf1b-self; allow-service tcp:179 udp:3784 udp:3785; traffic-group-local-only |
| Routing | route domain 0, routing-protocol BGP and BFD (set on each unit) |
| BGP | BIG-IP AS 65020 (router ID 10.254.5.3 / 10.254.5.4), leaves AS 65001, timers 3 9, advertisement-interval 0, fall-over bfd |
| BFD | interval 300 ms, minrx 300, multiplier 3, on both transit interfaces |
| Advertised | prefix-list VIPS: 10.20.5.0/24 ge 32, via `redistribute kernel route-map VIPS` |
| Accepted | nothing: route-map ACCEPT-NONE deny 10, inbound on both neighbours |
| Routed VIP | virtual-address 10.20.5.10, route-advertisement any, traffic-group-1; vs-rhi 10.20.5.10:80 |
| Pool and monitor | pool-rhi (server1-3:80); mon-rhi: GET /health, recv OK, interval 5, timeout 16 |
| leaf1a container | clab-f5-clos-dc-leaf1a-service (management 172.21.32.21) |

## Steps

Every command runs on the lab server (root, in the repo root). Load the shortcuts once per shell:

```bash
. ./demo/f5fn.sh
```

Besides `f5`, `f5b`, `pc1` and `leaf1a` (part 13), this part uses `leaf1b` and `border` (SONiC commands on leaf1b-service and
leaf3a-border) and `zebos <unit> <file>`: it copies a ZebOS file to the unit, loads it into route domain 0 with `imish -r 0 -f`, and
saves it with `write memory`.

### 1. Make lb-f5a the active unit

Part 13 ended with lb-f5b active. My run of this part starts with lb-f5a active, so fail over once:

```bash
f5b tmsh run sys failover standby
sleep 10; ./demo/ha-status.sh
```

You should see lb-f5a `failover ACTIVE` and lb-f5b `STANDBY`, both In Sync.

### 2. The weakness, timed: leaf1a frozen for 40 s

pc1 asks the ARP VIP five times a second; 10 s in, leaf1a-service is frozen for 40 s.

```bash
./demo/ha-status.sh; leaf1a 'show arp' | grep -E '10.20.30.100 '
(sleep 10; docker pause clab-f5-clos-dc-leaf1a-service; sleep 40; docker unpause clab-f5-clos-dc-leaf1a-service) >/dev/null & ./demo/ha-load.sh 70
```

In my run: `138 requests, 35 failed`, 42.6 s without an answer: nothing from the freeze until about 2.4 s after leaf1a came back.
HA cannot help: both units lost their external side at once. Give leaf1a time to recover its fabric and firewall sessions before
the next step (I waited 40 s).

### 3. Tagged transits on both units

VLANs and self IPs are local (not synced), so each unit gets its own. The transit self IPs allow only BGP and BFD.

```bash
f5 'tmsh create net vlan transit-leaf1a interfaces add { 1.1 { tagged } } tag 3005; tmsh create net vlan transit-leaf1b interfaces add { 1.2 { tagged } } tag 3007'
f5b 'tmsh create net vlan transit-leaf1a interfaces add { 1.1 { tagged } } tag 3005; tmsh create net vlan transit-leaf1b interfaces add { 1.2 { tagged } } tag 3007'
f5 'tmsh create net self transit-leaf1a-self address 10.254.5.3/29 vlan transit-leaf1a allow-service replace-all-with { tcp:179 udp:3784 udp:3785 } traffic-group traffic-group-local-only; tmsh create net self transit-leaf1b-self address 10.254.7.3/29 vlan transit-leaf1b allow-service replace-all-with { tcp:179 udp:3784 udp:3785 } traffic-group traffic-group-local-only'
f5b 'tmsh create net self transit-leaf1a-self address 10.254.5.4/29 vlan transit-leaf1a allow-service replace-all-with { tcp:179 udp:3784 udp:3785 } traffic-group traffic-group-local-only; tmsh create net self transit-leaf1b-self address 10.254.7.4/29 vlan transit-leaf1b allow-service replace-all-with { tcp:179 udp:3784 udp:3785 } traffic-group traffic-group-local-only'
f5 tmsh list net self one-line | grep transit; f5b tmsh list net self one-line | grep transit
f5 'ping -c 2 -W 1 10.254.5.1 | tail -1; ping -c 2 -W 1 10.254.7.1 | tail -1'
```

You should see: the allowed services listed by name, `tcp:bgp udp:bfd-control udp:bfd-echo`; lb-f5a pings both leaves (about
0.6-0.8 ms in my run).

### 4. BGP and BFD

Enable the routing protocols in route domain 0 on each unit (this setting does not sync), then load each unit's ZebOS file. The two
files differ only in the router ID.

```bash
f5 tmsh modify net route-domain 0 routing-protocol add { BGP BFD }; f5b tmsh modify net route-domain 0 routing-protocol add { BGP BFD }; sleep 15
cat demo/bgp/lb-f5a.conf
zebos lb-f5a demo/bgp/lb-f5a.conf; zebos lb-f5b demo/bgp/lb-f5b.conf; sleep 15
f5 "imish -r 0 -e 'show ip bgp summary'" | grep -E '^(Neighbor|10\.)'; f5 "imish -r 0 -e 'show bfd session'" | grep -E 'Sess-Idx|Single'
leaf1a "vtysh -c 'show bgp vrf Vrf-App summary'" | grep -E '^10\.254\.5'
```

The file for lb-f5a (`demo/bgp/lb-f5a.conf`):

```
ip prefix-list VIPS seq 10 permit 10.20.5.0/24 ge 32
route-map VIPS permit 10
 match ip address prefix-list VIPS
!
interface transit-leaf1a
 bfd interval 300 minrx 300 multiplier 3
!
interface transit-leaf1b
 bfd interval 300 minrx 300 multiplier 3
!
router bgp 65020
 bgp router-id 10.254.5.3
 bgp log-neighbor-changes
 neighbor 10.254.5.1 remote-as 65001
 neighbor 10.254.5.1 timers 3 9
 neighbor 10.254.5.1 advertisement-interval 0
 neighbor 10.254.5.1 fall-over bfd
 neighbor 10.254.7.1 remote-as 65001
 neighbor 10.254.7.1 timers 3 9
 neighbor 10.254.7.1 advertisement-interval 0
 neighbor 10.254.7.1 fall-over bfd
 redistribute kernel route-map VIPS
!
```

You should see: `loaded demo/bgp/lb-f5a.conf on lb-f5a` (and lb-f5b); on lb-f5a both neighbours established with 16 prefixes
received from each, and two BFD Single-Hop sessions Up. On leaf1a, both units (10.254.5.3 and .4) established, 0 prefixes received
from them, 16 sent to each. Both units keep BGP and BFD up all the time; only the active unit has a VIP route to advertise.

### 5. The routed VIP

A monitor on /health, its own pool, a virtual address with route advertisement, and the virtual server. Create them on lb-f5a;
auto-sync copies them to lb-f5b.

```bash
f5 tmsh create ltm monitor http mon-rhi defaults-from http interval 5 timeout 16 send '"GET /health HTTP/1.1\r\nHost: app.f5lab.test\r\nConnection: close\r\n\r\n"' recv OK
f5 tmsh create ltm pool pool-rhi monitor mon-rhi members add { server1:80 { address 10.20.0.11 } server2:80 { address 10.20.0.12 } server3:80 { address 10.20.0.13 } }
f5 tmsh create ltm virtual-address 10.20.5.10 address 10.20.5.10 route-advertisement any traffic-group traffic-group-1
f5 tmsh create ltm virtual vs-rhi destination 10.20.5.10:80 ip-protocol tcp pool pool-rhi profiles add { http-xff tcp } source-address-translation { type snat pool snat-web }; sleep 15
leaf1a "vtysh -c 'show ip route vrf Vrf-App 10.20.5.10/32'" | grep -E 'Known|via'; leaf1b "vtysh -c 'show ip route vrf Vrf-App 10.20.5.10/32'" | grep -E 'Known|via'
border "vtysh -c 'show ip route vrf Vrf-Outside 10.20.5.10/32'" | grep -E 'Known|via'
pc1 'curl -s -m 3 -o /dev/null -w "10.20.5.10: %{http_code}\n" http://10.20.5.10/; curl -s -m 3 -o /dev/null -w "app.f5lab.test: %{http_code}\n" http://app.f5lab.test/'
```

You should see: leaf1a has 10.20.5.10/32 by BGP via 10.254.5.3, Vlan3005; leaf1b via 10.254.7.3, Vlan3007; the border leaf, in
Vrf-Outside, two equal paths via the service VTEPs 10.255.255.11 and .12. Then pc1: `10.20.5.10: 000` **and**
`app.f5lab.test: 000`. Adding BGP broke the existing VIP too. Next step: why.

### 6. Why both VIPs fail: what the BIG-IP learned

```bash
f5 "imish -r 0 -e 'show ip bgp'" | grep -E '^\*' | head -14
f5 tmsh show net route lookup 10.20.0.11 | grep 10.20.0.11
f5 tmsh show net route | grep -c dynamic
```

You should see: BGP routes for 10.10.0.0/24, 10.20.0.0/24 and EVPN host /32s (10.20.0.11-.13, .20, and the BIG-IP's own SNAT
addresses .201 and .202); the lookup for server1 returns 10.20.0.11/32 via 10.254.5.1, transit-leaf1a, dynamic; 17 dynamic routes.
The /32 beats the connected 10.20.0.0/24 (longest match), so the server-side SYN leaves on the transit. The server answers the SNAT
address on its own subnet, so the SYN-ACK comes back on the internal VLAN, a different VLAN from the one the connection left on, and
the connection never completes.

### 7. The fix: accept nothing from the leaves

`demo/bgp/accept-none.conf`:

```
route-map ACCEPT-NONE deny 10
!
router bgp 65020
 neighbor 10.254.5.1 route-map ACCEPT-NONE in
 neighbor 10.254.7.1 route-map ACCEPT-NONE in
!
```

Load it on both units and re-apply the inbound policy with a soft clear (the sessions stay up):

```bash
cat demo/bgp/accept-none.conf
zebos lb-f5a demo/bgp/accept-none.conf; zebos lb-f5b demo/bgp/accept-none.conf; f5 "imish -r 0 -e 'clear ip bgp * soft in'"; f5b "imish -r 0 -e 'clear ip bgp * soft in'"; sleep 5
f5 tmsh show net route | grep -c dynamic; f5 "imish -r 0 -e 'show ip bgp'" | grep -E '^\*'
pc1 'curl -s -m 3 -o /dev/null -w "10.20.5.10: %{http_code}\n" http://10.20.5.10/; curl -s -m 3 -o /dev/null -w "app.f5lab.test: %{http_code}\n" http://app.f5lab.test/'; pc1 'curl -s http://10.20.5.10/' | grep -E '^(server|client seen):'
```

You should see: `0` dynamic routes; one BGP entry, `*> 10.20.5.10/32 0.0.0.0` (local); `10.20.5.10: 200` and
`app.f5lab.test: 200`; vs-rhi answered by server1, client seen 10.20.0.202 in my run. The BIG-IP needs no route back to the
clients: auto last hop sends replies to the MAC of the router that delivered the request, and the default route stays 10.20.30.1 on
the external VLAN.

### 8. leaf1a frozen again, now with the routed VIP

Same test as step 2, 60 s this time, against 10.20.5.10. Then the underlay session timers on spine1 (Ethernet0 faces leaf1a).

```bash
(sleep 10; docker pause clab-f5-clos-dc-leaf1a-service; sleep 60; docker unpause clab-f5-clos-dc-leaf1a-service) >/dev/null & URL=http://10.20.5.10/ ./demo/ha-load.sh 90
ssh admin@172.21.32.11 "vtysh -c 'show bgp neighbors Ethernet0'" | grep -E 'Hold time is|Last reset'
```

In my run: `307 requests, 11 failed`, 63.0 s between the first and the last failure, against 35 failed in a row with the ARP VIP.
In the rehearsal (431 requests, 9 failed) six failures came in the first 6.3 s, then single failures. spine1's session to leaf1a:
hold time 9 s, keepalive 3 s. The first seconds are the fabric's own detection (underlay BGP 3/9, no BFD in the underlay), not the
BIG-IP's.

### 9. An HA failover with the routed VIP

A failover now moves the route's next hop between .3 and .4. `./demo/route-watch.sh` polls leaf1a's route to 10.20.5.10/32 and
prints a line each time the next hop changes. Fail over from the active unit (lb-f5a), then back:

```bash
./demo/ha-status.sh; leaf1a "vtysh -c 'show ip route vrf Vrf-App 10.20.5.10/32'" | grep -E 'Known|via'
(sleep 8; f5 tmsh run sys failover standby >/dev/null) & ./demo/route-watch.sh 25 & URL=http://10.20.5.10/ ./demo/ha-load.sh 25; wait
(sleep 8; f5b tmsh run sys failover standby >/dev/null) & ./demo/route-watch.sh 25 & URL=http://10.20.5.10/ ./demo/ha-load.sh 25; wait
./demo/ha-status.sh
```

In my run: lb-f5a > lb-f5b: `82 requests, 3 failed`, 2.7 s without an answer (route timing not measured on that run). lb-f5b >
lb-f5a, failover at 8 s: leaf1a kept 10.254.5.4 until 17.8 s, then switched straight to 10.254.5.3 (never "no route");
`66 requests, 8 failed`, 8.9 s without an answer. lb-f5a ends ACTIVE. In the rehearsal: 7.7, 10.1, 3.9 and 11.4 s without an
answer. The ARP VIP lost at most one request per failover (part 13).

### 10. The application fails: route withdrawn

Remove /health on all three servers 3 s in, restore it 40 s later, and watch leaf1a's route. Then the BIG-IP's log.

```bash
(sleep 3; for s in 1 2 3; do docker exec clab-f5-clos-dc-server$s rm -f /www/health; done; sleep 40; for s in 1 2 3; do docker exec clab-f5-clos-dc-server$s sh -c 'echo OK > /www/health'; done) & ./demo/route-watch.sh 65
f5 "grep -h mcpd /var/log/ltm | grep -E 'vs-rhi has become' | tail -n 2"
```

In my run: /health removed at 3 s; leaf1a showed `no route` at 31.4 s; /health restored at 43 s; the route back via 10.254.5.3
at 46.7 s. lb-f5a logged vs-rhi unavailable at 06:19:22 and available at 06:19:42 (its own clock).

### 11. Check and save

```bash
./demo/ha-status.sh; leaf1b "vtysh -c 'show ip route vrf Vrf-App 10.20.5.10/32'" | grep -E 'Known|via'
pc1 'curl -s -m 3 -o /dev/null -w "10.20.5.10: %{http_code}\n" http://10.20.5.10/; curl -s -m 3 -o /dev/null -w "app.f5lab.test: %{http_code}\n" http://app.f5lab.test/'
f5 tmsh save sys config | tail -1; f5b tmsh save sys config | tail -1
```

You should see: lb-f5a ACTIVE; leaf1b routes 10.20.5.10/32 via 10.254.7.3; both VIPs `200`.

## Verify

- `imish -r 0 -e 'show ip bgp summary'` on each unit: both leaves established; after the fix, 0 prefixes accepted.
- `imish -r 0 -e 'show bfd session'`: two Single-Hop sessions Up per unit.
- `tmsh show net route | grep -c dynamic`: 0.
- leaf1a and leaf1b route 10.20.5.10/32 to the active unit's transit address (.3 for lb-f5a, .4 for lb-f5b); the border leaf has
  ECMP via 10.255.255.11 and .12 in Vrf-Outside.
- Both VIPs answer 200 from pc1.
- Leaf failure: 11 failed requests over a 60 s freeze with the routed VIP, against 35 in a row over a 40 s freeze with the ARP VIP.
- Pool down: the /32 left leaf1a about 28 s after /health was removed, and came back about 4 s after it was restored.

## Gotchas

- **The routes the leaves send back broke both VIPs.** EVPN host /32s from Vrf-App (servers, log server, even the BIG-IP's own
  .201/.202/.240-.242) beat the connected 10.20.0.0/24. Server-side SYNs left on the transit and the SYN-ACKs came back on the
  internal VLAN; vs-web failed too, from the moment BGP came up. Fix: `route-map ACCEPT-NONE deny 10` inbound on both neighbours,
  on both units, then `clear ip bgp * soft in`.
- `net route-domain 0 routing-protocol add { BGP BFD }` does not sync: set it on each unit. Transit VLANs, self IPs and each
  unit's ZebOS file are local too. The virtual address, vs-rhi, pool-rhi and mon-rhi sync.
- A failover with the routed VIP cost more than with the ARP VIP: 2.7 to 11.4 s without an answer. In the rehearsal leaf1a kept
  the old next hop for 10.9 s, then switched directly to the new one, while both units' own BGP tables had flipped within 0.4 s.
  The configs are identical (advertisement-interval 0, timers 3 9, fall-over bfd, graceful restart at its default restart-time
  120). I did not establish the cause; part 15 measures the leaf's side.
- A pool failure is not instant as a route: the monitor marks the members down first (timeout 16 s), then the virtual server
  becomes unavailable, then the route is withdrawn. In the rehearsal: virtual unavailable at +19.9 s, /32 gone from leaf1a at
  +34.1 s.
- lb-f5a's clock was 4.85 s behind the lab server's in my run. Compare BIG-IP log times with the lab server's timings with that in
  mind.
- spine1's "Last reset" line for leaf1a read "Hold Timer Expired" in the rehearsal and "No AFI/SAFI activated for peer" in the
  final run. The hold time (9 s) is the number that matters.

## End state

- Both VIPs side by side: 10.20.30.100 (ARP, vs-web, vs-web-https) and 10.20.5.10 (routed: vs-rhi, pool-rhi, mon-rhi, virtual
  address with route-advertisement any).
- On both units: VLANs transit-leaf1a and transit-leaf1b, self IPs transit-leaf1a-self / transit-leaf1b-self (.3 on lb-f5a, .4 on
  lb-f5b), route domain 0 routing-protocol BGP and BFD, ZebOS from `demo/bgp/lb-f5a.conf` / `lb-f5b.conf` plus
  `demo/bgp/accept-none.conf`.
- HA pair dg-lb as in part 13, **lb-f5a ACTIVE, lb-f5b STANDBY**. Configuration saved on both units.
- Save a UCS of both units now: `./f5-save.sh`.

## Reset

The full reset (routing, ZebOS, transits) is a restore of the UCS you saved before step 1, on both units:

```bash
./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<lb-f5a-file>.ucs
./f5-restore.sh lb-f5b /root/f5-clos-dc-secrets/ucs/<lb-f5b-file>.ucs
```

To remove only the routed VIP, on the active unit (auto-sync copies the deletes), in this order:

```bash
f5 tmsh delete ltm virtual vs-rhi
f5 tmsh delete ltm pool pool-rhi
f5 tmsh delete ltm monitor http mon-rhi
f5 tmsh list ltm virtual-address 10.20.5.10
```

If the last command still lists the virtual address, delete it with `f5 tmsh delete ltm virtual-address 10.20.5.10`.

## Files used

- `demo/f5fn.sh`: shell shortcuts (`f5`, `f5b`, `pc1`, `leaf1a`, `leaf1b`, `border`, `zebos`).
- `demo/bgp/lb-f5a.conf`: ZebOS config for lb-f5a (router ID 10.254.5.3).
- `demo/bgp/lb-f5b.conf`: ZebOS config for lb-f5b (router ID 10.254.5.4).
- `demo/bgp/accept-none.conf`: inbound deny-all route map for both neighbours, both units.
- `demo/ha-status.sh`: one line per unit: failover status, traffic-group-1 state, sync status.
- `demo/ha-load.sh`: pc1 asks a URL (`URL=`) five times a second, then prints requests, failures and the longest gap.
- `demo/route-watch.sh`: polls leaf1a's Vrf-App route to 10.20.5.10/32 and prints each next-hop change with the elapsed time.

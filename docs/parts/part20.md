# Part 20: Anycast VIPs with route health injection: one address, two sites, active-active

| | |
|---|---|
| Video | [F5 Anycast VIP with RHI: One Address, Two Sites (Part 20)](https://youtu.be/c1k7-eQ8zmY) (public from 2026-12-22 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-anycast-rhi/) (from 2026-12-22 04:00 UTC) |
| Previous / next | [Part 19](part19.md) / [Part 21](part21.md) |

## Goal

I put one address, 10.20.5.200, on both sites at once: a virtual server on lb-f5a (site A) and on lb-f5b (site B), each with its own
pool and SNAT, both announcing the /32 by BGP with route health injection. The leaves hold two equal next hops and spread flows by
ECMP, with no DNS and no cache in the way. I show who lands where with an L3 hash and with a 5-tuple hash, time a site whose
application fails and a site that disappears, follow open TCP connections through every change of path, and compare two ways of taking
a site out on purpose.

The numbers below are from my runs. Yours will differ from run to run: monitor timing and the hash's choice of path are not the same
twice.

## Starting state

- The lab is up and `./validate.sh` passes. The anycast name is part of the lab: `gen.py` `ANYCAST` (any.f5lab.test, 10.20.5.200);
  the PCs have it in `/etc/hosts` (`shared/pc-up.sh`). No fabric change is needed: 10.20.5.0/24 host routes are already reachable
  from the clients through the firewall.
- The end state of part 19: lb-f5a (site A, `pool-rhi` with monitor `mon-rhi`, `vs-rhi`) and lb-f5b (site B, `pool-siteb`,
  `vs-siteb`), standalone, both with BGP to leaf1a and leaf1b (part 14), both AS 65020. The GSLB configuration of parts 18-19 stays
  and is not used here.
- The leaves' multipath hash at its default, `net.ipv4.fib_multipath_hash_policy = 0` (L3). Step 7 changes it.
- Units used: both. To get here: the guide of part 19, or restore the UCS you saved at its end with `./f5-restore.sh`. Save both units
  before you start (`./f5-save.sh`).

Every command runs **on the lab server (root, in the repo's `demo` folder, with the helper functions loaded)**:

```bash
cd demo
. ./f5fn.sh
```

Helpers (from `demo/f5fn.sh`): `f5 '<cmd>'` / `f5b '<cmd>'` run a command on lb-f5a / lb-f5b (bash as admin); `pc1 '<cmd>'` runs it
on pc1; `leaf1a '<cmd>'` / `leaf1b '<cmd>'` run a command on leaf1a-service / leaf1b-service; `F5U=<unit> f5merge <file>` merges a
tmsh config file into that unit.

## Values used in this part

| Object | Value |
|---|---|
| Anycast name and address | any.f5lab.test, 10.20.5.200 |
| Site A | lb-f5a: `vs-any` 10.20.5.200:80 > `pool-rhi`, SNAT automap (10.20.0.240 / .241 as the servers see it), BGP next hop 10.254.5.3 |
| Site B | lb-f5b: `vs-any` 10.20.5.200:80 > `pool-siteb`, SNAT automap (10.20.0.242), BGP next hop 10.254.5.4 |
| Virtual address | 10.20.5.200/32, `route-advertisement any` on both units |
| Leaves | leaf1a, leaf1b: eBGP to both BIG-IPs (AS 65020) with BFD, `maximum-paths 8` in Vrf-App |
| Hash policy | `net.ipv4.fib_multipath_hash_policy`: 0 = L3 (addresses), 1 = L4 (5-tuple) |
| Site A actions (`site-a.sh`) | `app-fail` / `app-ok`; `isolate` / `connect`; `any-drain` / `any-undrain` (vs-any disabled / enabled); `any-withdraw` / `any-advertise` (route-advertisement disabled / any) |

## The measuring tools

- `any-count.sh <pc> [n]`: n fetches of `http://any.f5lab.test/` from a PC, each a new connection, counted by site. The site comes
  from the SNAT address the server saw: 10.20.0.242 is site B, anything else site A.
- `any-hash.sh [leaf] [sources...]`: asks a leaf's kernel which next hop it would choose for 10.20.5.200 per source address, for traffic
  arriving from the firewall (`ip route get ... iif Vlan3002 vrf Vrf-App`).
- `any-watch.sh <seconds> [log]`: pc1 fetches about four times a second (new connection each time, 1 s timeout), and leaf1a polls its
  own next hops to 10.20.5.200 about four times a second.
- `any-timeline.sh [log] [t0]`: merges that log with lb-f5a's LTM log, in seconds after t0 (written by `site-a.sh`). The leaves are VMs
  whose clocks ran about 8 s behind the lab server in my lab, and lb-f5a about 6.4 s: the script measures both offsets and corrects them.
- `any-conns.py <n> <seconds>`: runs on pc1; opens n keep-alive connections and sends one request on each about twice a second, on the
  same connection as long as it lives. It prints each connection's site every second (`x` when a request failed), then every break:
  when, and which site the connection had been using. Run it with the script on stdin:
  `ssh admin@172.21.32.111 'python3 - 8 85' < any-conns.py`.

## Steps

### 1. Where part 19 left the fabric

```bash
leaf1a "vtysh -c 'show ip route vrf Vrf-App 10.20.5.0/24 longer-prefixes'" | grep -E '^B'
leaf1a "vtysh -c 'show running-config'" | sed -n '/router bgp 65001 vrf Vrf-App/,/exit-address-family/p' | grep -E 'router bgp|neighbor 10.254.5.[34] (remote-as|bfd)|maximum-paths'
for l in leaf1a leaf1b; do $l 'sudo sysctl net.ipv4.fib_multipath_hash_policy'; done
```

You should see each site's /32s through its own BIG-IP (.3 = lb-f5a, .4 = lb-f5b); both BIG-IPs as AS 65020 with BFD and
`maximum-paths 8`; and hash policy 0 on both leaves.

### 2. Site A: the virtual server, then the advertisement

Site A's pool from part 14, which the new virtual server will use:

```bash
f5 'tmsh list ltm pool pool-rhi monitor members' | grep -E 'pool|monitor|address'
```

You should see `pool-rhi` with server1-3 and monitor `mon-rhi`.

The virtual server on the anycast address. `destination` is the address and port it listens on; `pool` is where it sends the
connections (site A's own servers); the `tcp` and `http` profiles make it a full proxy for HTTP; SNAT automap translates the client's
address to lb-f5a's own address, so the servers' replies come back through site A:

```bash
f5 'tmsh create ltm virtual vs-any destination 10.20.5.200:80 ip-protocol tcp pool pool-rhi profiles add { tcp http } source-address-translation { type automap }'
```

Creating the virtual server also created its virtual address, 10.20.5.200. Look at both, and at leaf1a:

```bash
f5 'tmsh list ltm virtual vs-any; tmsh list ltm virtual-address 10.20.5.200 route-advertisement'
leaf1a "vtysh -c 'show ip route vrf Vrf-App 10.20.5.200'" | grep -E 'Known|via' || echo 'leaf1a: no route to 10.20.5.200'
```

You should see `route-advertisement disabled` (the default for a new virtual address) and no route to 10.20.5.200 on leaf1a: the
address exists on lb-f5a, but nothing tells the fabric.

`route-advertisement any` is route health injection: the BIG-IP puts the /32 into its routing table while the virtual address is
available (any one of its virtual servers available), and removes it when it is not. Turn it on, and check leaf1a 10 s later:

```bash
f5 'tmsh modify ltm virtual-address 10.20.5.200 route-advertisement any; tmsh list ltm virtual-address 10.20.5.200 route-advertisement'
sleep 10; leaf1a "vtysh -c 'show ip route vrf Vrf-App 10.20.5.200'" | grep -E 'Known|via|not in'
```

You should see 10.20.5.200 via 10.254.5.3 (lb-f5a, site A) only.

### 3. How the advertisement reaches BGP

The BGP side was built in part 14; nothing in it changes here. On lb-f5a, in the routing module (`imish`, route domain 0): the
injected /32 is a kernel route owned by TMM:

```bash
f5 "imish -r 0 -e 'show ip route kernel' | grep 10.20.5.200"
```

You should see 10.20.5.200/32 as "directly connected, tmm".

BGP redistributes kernel routes through a route map, peers with both leaves with BFD, and accepts nothing from them:

```bash
f5 "imish -r 0 -e 'show running-config' | grep -A14 '^router bgp'"
```

You should see `router bgp 65020` with `redistribute kernel route-map VIPS`, both leaves (10.254.5.1, 10.254.7.1) as neighbours with
`fall-over bfd` (a lost leaf or BIG-IP is detected by BFD, not by the BGP hold timer) and `route-map ACCEPT-NONE in` (the BIG-IP
advertises, it does not learn routes from the fabric).

The route map lets out only /32s from 10.20.5.0/24:

```bash
f5 "imish -r 0 -e 'show running-config' | grep -E '^(ip prefix-list|route-map)| match'"
```

You should see `ip prefix-list VIPS seq 10 permit 10.20.5.0/24 ge 32` and `route-map VIPS permit 10` with
`match ip address prefix-list VIPS`. That is why the new address needed no routing change: 10.20.5.200/32 already matches.

What lb-f5a now advertises to leaf1a:

```bash
f5 "imish -r 0 -e 'show ip bgp neighbors 10.254.5.1 advertised-routes' | grep -E 'Network|10.20.5'"
```

In my run: 10.20.5.10, 10.20.5.53 and now 10.20.5.200.

### 4. Site B: the same address, its own pool

Site B's pool:

```bash
f5b 'tmsh list ltm pool pool-siteb monitor members' | grep -E 'pool|monitor|address'
```

You should see `pool-siteb` with server1-3 and monitor `http-app`.

The same virtual server on lb-f5b, with site B's pool, and route advertisement on its virtual address:

```bash
f5b 'tmsh create ltm virtual vs-any destination 10.20.5.200:80 ip-protocol tcp pool pool-siteb profiles add { tcp http } source-address-translation { type automap }; tmsh modify ltm virtual-address 10.20.5.200 route-advertisement any'
f5b 'tmsh list ltm virtual vs-any; tmsh list ltm virtual-address 10.20.5.200 route-advertisement'
sleep 10; for l in leaf1a leaf1b; do echo "== $l"; $l "vtysh -c 'show ip route vrf Vrf-App 10.20.5.200'" | grep -E 'Known|via'; done
pc1 'getent hosts any.f5lab.test'
```

You should see two next hops to 10.20.5.200 on each leaf (10.254.5.3 = site A, 10.254.5.4 = site B), and pc1 resolving
`any.f5lab.test` to 10.20.5.200 from `/etc/hosts`.

The same configuration as files, as an alternative to steps 2 and 4: `demo/anycast/any-a.conf` and `demo/anycast/any-b.conf` (they
differ only in the pool), merged with `F5U=lb-f5a f5merge anycast/any-a.conf && F5U=lb-f5b f5merge anycast/any-b.conf`.

### 5. The same route, from inside

leaf1a's BGP paths, the route in the kernel with its next-hop group, and lb-f5b's own BGP entry:

```bash
leaf1a "vtysh -c 'show bgp vrf Vrf-App ipv4 unicast 10.20.5.200/32'" | grep -E 'Paths|65020|multipath|from'
leaf1a 'id=$(ip route show vrf Vrf-App 10.20.5.200 | grep -o "nhid [0-9]*" | cut -d" " -f2); ip route show vrf Vrf-App 10.20.5.200; ip -d nexthop show id $id'
f5b "imish -r 0 -e 'show ip bgp 10.20.5.200/32' | grep -E 'entry|Advertised|10.254|Local|Origin'"
```

In my run: four BGP paths on leaf1a, the two from the BIG-IPs (AS 65020) marked multipath, and two more over EVPN from leaf1b with a
longer AS path. In the kernel: one route with a next-hop group of two, of the plain kind (no `type resilient`). On lb-f5b:
10.20.5.200/32 local, advertised to both leaves.

### 6. Who lands where: the L3 hash

```bash
for p in pc1 pc2 pc3; do ./any-count.sh $p 10; done
./any-hash.sh leaf1a
./any-hash.sh leaf1b 10.10.0.11 10.10.0.12 10.10.0.13
```

In my run: pc1, pc2 and pc3 all landed on site A, 10 of 10 each. leaf1a's own answer per source: pc1-3 (10.10.0.11-.13) > site A;
10.10.0.22, .23 and .25-.27 > site B. The leaves forward in the VM's Linux kernel; with policy 0 the hash uses only the addresses, so
every connection from one PC takes the same path. leaf1b would send pc3 to site B, but the PCs' traffic enters the fabric at leaf1a.

### 7. The 5-tuple hash

This is a live, non-persistent change on the leaves: `sysctl -w` sets the kernel value until the leaf restarts, and nothing writes it to
the leaves' saved configuration.

```bash
for l in leaf1a leaf1b; do $l 'sudo sysctl -w net.ipv4.fib_multipath_hash_policy=1'; done
for p in pc1 pc2 pc3; do ./any-count.sh $p 20; done
```

In my run, 20 fetches each (site A / site B): pc1 8/12, pc2 6/14, pc3 13/7, none failed. In the dry run: pc1 17/19. Each new
connection has a new source port, so it is hashed again.

### 8. Site A's application fails

Site A loses its servers (blackhole routes on server1-3, as in part 19) 6 s into a 45 s watch:

```bash
( (sleep 6; ./site-a.sh app-fail) & ); ./any-watch.sh 45 /tmp/af.log
clear; ./any-timeline.sh /tmp/af.log
```

In my run: fetches hashed to site A failed, those to site B kept working: 24 failed fetches, up to +27.0 s. LTM marked the members
down at +17.3 to +20.3 s and `vs-any` unavailable at +20.3 s; leaf1a had site B only from +27.0 s. Route health injection withdrew the
/32 once the virtual server was unavailable. As with GSLB, the monitor's timeout is the largest share; unlike GSLB, nothing is cached.

### 9. Repair

```bash
( (sleep 4; ./site-a.sh app-ok) & ); ./any-watch.sh 25 /tmp/ar.log
clear; ./any-timeline.sh /tmp/ar.log
```

In my run: `vs-any` available at +0.3 s; leaf1a had site A and site B again at +10.9 s; no failed fetch.

### 10. Site A disappears

All of lb-f5a's data interfaces down, then back:

```bash
( (sleep 6; ./site-a.sh isolate) & ); ./any-watch.sh 25 /tmp/ai.log
clear; ./any-timeline.sh /tmp/ai.log
./site-a.sh connect; for i in $(seq 20); do sleep 2; n=$(leaf1a "ip route show vrf Vrf-App 10.20.5.200" | grep -c nexthop); [ "$n" = 2 ] && { echo "two next hops again after $((i*2)) s"; break; }; done
```

In my run: 1 failed fetch (+0.8 s); leaf1a had site B only at +1.3 s (dry run: +0.9 s), far below the BGP hold time, consistent with
BFD on these sessions. LTM on lb-f5a noticed only at +16 to +21 s: site A was still running, it simply could not reach anything. After
`connect`: two next hops again after 14 s.

### 11. Open connections

Each site has its own connection table, so a flow the fabric moves to the other site is answered with a reset. Eight keep-alive
connections from pc1 for 85 s; site A isolated 15 s in and reconnected 25 s later:

```bash
sed -n '2,7p' any-conns.py
( (sleep 15; ./site-a.sh isolate; sleep 25; ./site-a.sh connect) & ); ssh admin@172.21.32.111 'python3 - 8 85' < any-conns.py
```

In my run: before, c1, c4, c7 and c8 on site A; c2, c3, c5 and c6 on site B. When site A was isolated, the four on site A were reset;
the four on site B carried on. When site A came back (about 14 s after its links), one connection that was on site B (c4, reopened
after its first break) was reset: the next-hop group changed, and the plain (non-resilient) group rehashed it onto site A. Summary: 5
broken connections, 4 on site A when it left, 1 on site B when it came back.

### 12. Taking a site out, attempt 1: disable the virtual server

`vs-any` disabled on lb-f5a 10 s in, with 8 keep-alive connections open and the watch running:

```bash
(ssh admin@172.21.32.111 'python3 - 8 45' < any-conns.py > /tmp/c-drain.out &); ( (sleep 10; ./site-a.sh any-drain) & ); QUIET=1 ./any-watch.sh 40 /tmp/ad.log
clear; ./any-timeline.sh /tmp/ad.log
sleep 3; grep -A9 broken /tmp/c-drain.out
f5 "tmsh show ltm virtual-address 10.20.5.200 field-fmt | grep -E 'status.(avail|enabled)'; imish -r 0 -e 'show ip bgp 10.20.5.200/32' | grep -E 'entry|Advertised|10.254'"
./site-a.sh any-undrain
```

In my run: 70 failed fetches from +0.7 s to the end (+29.8 s); leaf1a never dropped site A. The 8 open connections: 0 broken. The
virtual address stayed available and enabled, and BGP still advertised 10.20.5.200/32 to 10.254.5.1 and 10.254.7.1. Route health
injection follows the virtual address's availability, not the virtual server's enabled state: new connections hashed to site A were
refused while the open ones kept working.

### 13. Taking a site out, attempt 2: stop advertising

The virtual address's route advertisement disabled on lb-f5a 10 s in, and set back to `any` 30 s later:

```bash
(ssh admin@172.21.32.111 'python3 - 8 75' < any-conns.py > /tmp/c-wd.out &); ( (sleep 10; ./site-a.sh any-withdraw; cp /tmp/gslb-t0 /tmp/t-wd; sleep 30; ./site-a.sh any-advertise) & ); QUIET=1 ./any-watch.sh 70 /tmp/aw.log
clear; ./any-timeline.sh /tmp/aw.log $(cat /tmp/t-wd)
sleep 6; grep -A12 broken /tmp/c-wd.out
```

In my run: leaf1a had site B only at +7.1 s and site A and site B again at +37.1 s; 4 scattered failed fetches. The connections: 6 on
site A were reset as the route left (+7 s), and 1 on site B was reset as it returned. New connections moved cleanly; open ones on site A
did not survive. With stateless ECMP, every drain costs something.

## Verify

| Test | What I measured |
|---|---|
| Routes after the build | two next hops to 10.20.5.200 on leaf1a and leaf1b (10.254.5.3, 10.254.5.4) |
| L3 hash (policy 0) | pc1-3: site A 10/10 each |
| 5-tuple hash (policy 1) | site A / site B: pc1 8/12, pc2 6/14, pc3 13/7 |
| Site A application fails | 24 failed fetches, up to +27.0 s; vs-any unavailable +20.3 s; route withdrawn +27.0 s |
| Repair | vs-any available +0.3 s; route back +10.9 s; no failed fetch |
| Site A disappears | 1 failed fetch; route withdrawn +1.3 s; two next hops again 14 s after `connect` |
| Open connections, isolate and return | 4 reset on site A when it left, 1 on site B when it came back |
| vs-any disabled | route not withdrawn; 70 failed new fetches in 30 s; 0 open connections broken |
| Route advertisement disabled | route withdrawn +7.1 s; 6 open connections on site A reset; 1 on site B reset at the return |

## Gotchas

- **Disabling the virtual server does not withdraw the route.** Route health injection follows the virtual address's availability;
  a disabled virtual server leaves it available, so the /32 stays advertised and new flows hashed to that site are refused. To move new
  flows away, stop the advertisement (`route-advertisement disabled` on the virtual address).
- **Every change of path resets the flows it moves.** The two BIG-IPs do not share connection state. A site leaving resets its
  connections; a site returning rehashes some flows from the other site onto it, because the leaves' next-hop group is the plain kind,
  not resilient.
- **The L3 hash put every PC on one site.** With policy 0 the hash sees only addresses, and pc1-3 all hashed to site A. Check the
  leaf's choice per source with `any-hash.sh` before reading anything into an uneven spread.
- **The hash policy change is live only.** `sudo sysctl -w net.ipv4.fib_multipath_hash_policy=1` on leaf1a and leaf1b lasts until
  the leaf restarts; a rebuilt lab starts at 0 again.
- **Leaf clocks.** The leaves are VMs whose clocks ran about 8 s behind the lab server (lb-f5a about 6.4 s). `any-timeline.sh`
  corrects both per run.
- **Stray timeouts.** A single fetch occasionally timed out with nothing changed (in the dry run at -5.7 s, and in the drain run).
  They are left in the counts.
- **Application failure is still monitor-bound.** LTM marked the virtual server unavailable at +20.3 s (its monitor timeout is 16 s);
  the route followed at +27.0 s.

## End state

- `vs-any` 10.20.5.200:80 on both units (site A > `pool-rhi`, site B > `pool-siteb`), enabled, virtual address advertised by both:
  two next hops on leaf1a and leaf1b.
- Site A repaired (`app-ok`, `connect`, `any-undrain`, `any-advertise` all run).
- leaf1a and leaf1b at `fib_multipath_hash_policy = 1` until they restart.
- Parts 18-19's GSLB configuration unchanged.

Save it (from the repo root):

```bash
cd ..
./f5-save.sh
```

## Reset

Restore the UCS you saved at the start of this part (the end of part 19) on both units:

```bash
./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<lb-f5a-file>.ucs
./f5-restore.sh lb-f5b /root/f5-clos-dc-secrets/ucs/<lb-f5b-file>.ucs
```

Or delete this part's objects. I did not run these commands in my lab: check each result (`tmsh list ltm virtual-address 10.20.5.200`
should then find nothing on either unit).

```bash
f5 'tmsh delete ltm virtual vs-any'
f5b 'tmsh delete ltm virtual vs-any'
```

Then put the leaves' hash back to the default:

```bash
for l in leaf1a leaf1b; do $l 'sudo sysctl -w net.ipv4.fib_multipath_hash_policy=0'; done
```

If a run was interrupted, repair site A first: `./site-a.sh app-ok`, `./site-a.sh connect`, `./site-a.sh any-undrain`,
`./site-a.sh any-advertise`.

## Files used

- `demo/f5fn.sh`: the helpers `f5`, `f5b`, `pc1`, `leaf1a`, `leaf1b`, `f5merge`.
- `demo/bgp/lb-f5a.conf`, `demo/bgp/lb-f5b.conf`, `demo/bgp/accept-none.conf`: the BGP configuration from part 14 that step 3 reads.
- `demo/anycast/any-a.conf`: site A's `vs-any` (pool-rhi) and the virtual address with route advertisement, as a file (alternative to step 2).
- `demo/anycast/any-b.conf`: the same for site B (pool-siteb; alternative to step 4).
- `demo/any-count.sh`: n fetches from a PC, counted by site.
- `demo/any-hash.sh`: a leaf's next-hop choice per source address.
- `demo/any-watch.sh`: pc1's fetches and leaf1a's next hops, about four times a second.
- `demo/any-timeline.sh`: the watch merged with lb-f5a's LTM log, clocks corrected.
- `demo/any-conns.py`: keep-alive connections from pc1 and every break.
- `demo/site-a.sh`: one failure or repair of site A, with its start time.

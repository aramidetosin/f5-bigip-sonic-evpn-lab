# Part 18: GSLB with BIG-IP DNS: wide IPs, pools and the resolver

| | |
|---|---|
| Video | [F5 GSLB Explained: BIG-IP DNS Wide IPs, Two Sites (Part 18)](https://youtu.be/_ZlbbrhZiok) (public from 2026-12-17 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-gslb-big-ip-dns/) (from 2026-12-17 04:00 UTC) |
| Previous / next | [Part 17](part17.md) / [Part 19](part19.md) |

## Goal

I split the HA pair into two standalone sites under load: lb-f5a is site A, lb-f5b is site B, each announcing its own VIP to the
fabric by BGP. Then I provision BIG-IP DNS on both and time the outage it causes, build the iQuery trust by hand, join the two units in
a sync group, and publish a DNS listener per site. A wide IP `app.gslb.f5lab.test` with a pool per site answers by round robin, ratio
and topology, first straight from the listeners, then through the clients' real resolver, which changes who the BIG-IP sees as the
client and how long an answer lives.

## Starting state

- The lab is up and `./validate.sh` passes. The clients' resolver is part of the lab: BIND on lan-switch, 10.10.0.5
  (`shared/resolver-up.sh`), with a static-stub zone that sends `gslb.f5lab.test` to both listener addresses; the PCs use it as their
  only resolver. The firewall rule for DNS (udp and tcp 53) from the clients to the published ranges is part of the lab too.
- The end state of part 17: the HA pair (device group `dg-lb`, traffic-group-1), BGP from both units with route health injection
  (part 14), `vs-rhi` 10.20.5.10, `vs-web`, `vs-web-https`, `vs-api`, the SNAT pool `snat-web`, the floating self IPs `float-external`
  and `float-internal`, the monitor `http-app`, and the nodes server1-3. lb-f5a active.
- Your licence must include BIG-IP DNS (in my run: an evaluation key that bundles LTM, Advanced WAF and DNS).
- Units used: both. At the end they are no longer a pair.
- To get here: the guide of part 17, or restore the UCS you saved at its end with `./f5-restore.sh`. Save both units before you start
  (`./f5-save.sh`): restoring that UCS is how this part is reset.

Every command runs **on the lab server (root, in the repo's `demo` folder, with the helper functions loaded)**:

```bash
cd demo
. ./f5fn.sh
```

Helpers (from `demo/f5fn.sh`): `f5 '<cmd>'` / `f5b '<cmd>'` run a command on lb-f5a / lb-f5b (bash as admin); `pc1 '<cmd>'` runs it
on pc1; `leaf1a '<cmd>'` runs a SONiC CLI command on leaf1a-service; `F5U=lb-f5b f5merge <file>` merges a tmsh config file into
lb-f5b. `LEAF` below is only a shorthand for the route check on leaf1a:

```bash
LEAF="leaf1a \"vtysh -c 'show ip route vrf Vrf-App 10.20.5.0/24 longer-prefixes'\" | grep -E '^B'"
```

## Values used in this part

| Object | Value |
|---|---|
| Site A | lb-f5a: range 10.20.5.0/25, app VIP 10.20.5.10 (`vs-rhi`), DNS listener 10.20.5.53 |
| Site B | lb-f5b: range 10.20.5.128/25, app VIP 10.20.5.140 (`vs-siteb`), DNS listener 10.20.5.153 |
| Site B application | `pool-siteb` (server1-3:80, monitor `http-app`), `vs-siteb` 10.20.5.140:80, SNAT automap, route advertisement any |
| Data centres | `dc-a`, `dc-b` |
| GSLB servers | `site-a` 192.168.255.1 (lb-f5a), `site-b` 192.168.255.2 (lb-f5b): the HA-link self IPs; product bigip, monitor bigip, virtual-server discovery enabled |
| Sync group | `gslb-ab` |
| Listeners | `dns-a-udp`, `dns-a-tcp` 10.20.5.53:53 (lb-f5a); `dns-b-udp`, `dns-b-tcp` 10.20.5.153:53 (lb-f5b) |
| GSLB pools | `pool-a` = site-a:/Common/vs-rhi; `pool-b` = site-b:/Common/vs-siteb |
| Wide IP | `app.gslb.f5lab.test` (type A), pools pool-a and pool-b |
| Topology | ldns 10.10.0.12/32 (pc2) > pool-b, score 100; ldns 10.10.0.0/24 > pool-a, score 50 |
| Resolver | lan-switch 10.10.0.5 (BIND 9) |
| PCs | pc1 10.10.0.11, pc2 10.10.0.12, pc3 10.10.0.13 |

## Steps

### 1. Split the pair into two sites, under load

The danger is traffic-group-1: every floating self IP and every virtual address is in it, and once lb-f5b leaves the pair it would
make them all active too, so both units would answer for the same addresses. The order matters: lb-f5b goes forced offline, leaves
the device group, deletes its copies of those objects, gets its own application, and only then comes back online. No new fabric subnet
is needed: each site's addresses are /32 routes announced by BGP, as in part 14.

Check the pair, then start pc1 loading the web application (five requests a second for 120 s, in the background):

```bash
./ha-status.sh
URL=http://app.f5lab.test/ ./ha-load.sh 120 /tmp/split.log > /tmp/split.sum &
```

lb-f5b forced offline: it holds no traffic group and will not take one:

```bash
f5b 'tmsh run sys failover offline'; sleep 5; ./ha-status.sh
```

On lb-f5a, remove lb-f5b from the device group, then read lb-f5b's own view of the group:

```bash
f5 'tmsh modify cm device-group dg-lb devices delete { lb-f5b.f5lab.test }'; sleep 10; f5b 'tmsh list cm device-group dg-lb devices'
```

You should see only `lb-f5a.f5lab.test` in it, on both units. Device trust stays: BIG-IP DNS uses it.

List the traffic-group-1 objects on lb-f5b, delete them, and count what is left:

```bash
f5b "tmsh list net self one-line | grep traffic-group-1 | cut -c1-70; tmsh list ltm virtual-address one-line | cut -c1-70"
f5b 'tmsh delete ltm virtual vs-web vs-web-https vs-api vs-rhi; tmsh delete ltm snatpool snat-web; tmsh delete net self float-external float-internal'
f5b "tmsh list net self one-line | grep -c traffic-group-1; tmsh list ltm virtual-address one-line | wc -l"
```

You should see `0` and `0`. Deleting the four virtual servers removes their virtual addresses; the SNAT pool's translations go with it.

Site B's application is a config file (`demo/gslb/siteb.conf`): a pool of the same three servers with the same monitor, a virtual
server on 10.20.5.140 with SNAT automap (the shared SNAT pool stayed with site A), and route advertisement on its address. Merge it into
lb-f5b and bring lb-f5b back online:

```bash
cat gslb/siteb.conf
F5U=lb-f5b f5merge gslb/siteb.conf && f5b 'tmsh run sys failover online'
```

Both units are now active, each for itself. The fabric sees one /32 per site:

```bash
sleep 15; ./ha-status.sh; eval "$LEAF"
```

You should see 10.20.5.10/32 via lb-f5a (.3) and 10.20.5.140/32 via lb-f5b (.4). pc1 reaches both VIPs:

```bash
pc1 'curl -s -m3 http://10.20.5.10/ | head -1; curl -s -m3 http://10.20.5.140/ | head -1'
```

When the load has finished, read its summary:

```bash
while pgrep -f '[h]a-load.sh 120' >/dev/null; do sleep 1; done; cat /tmp/split.sum
```

In my run: 457 requests, 3 failed (single requests at 21 s and 32 s in). In the dry run: 467 requests, 0 failed.

### 2. Provision BIG-IP DNS on site B, timed

Provisioning a module restarts TMM, so on a standalone unit it is a site outage. Look at the provisioning first, start pc1 loading
site B's VIP for 200 s, then provision gtm and follow TMM and gtmd with `gtm-wait.sh`:

```bash
f5b "tmsh show sys provision | grep -E '^ *(Module|asm|gtm|host|tmos) '"
URL=http://10.20.5.140/ ./ha-load.sh 200 /tmp/provb.log > /tmp/provb.sum &
f5b 'tmsh modify sys provision gtm level nominal' && ./gtm-wait.sh lb-f5b
f5b "tmsh show sys provision | grep -E '^ *(Module|asm|gtm|host|tmos) '"
while pgrep -f '[h]a-load.sh 200' >/dev/null; do sleep 1; done; cat /tmp/provb.sum
```

In my run: +7 s TMM finishing, +10 s down, +17 s running, +52 s gtmd running. Memory: gtm 656 MB (host), asm 3072 > 2674 MB, tmos
5810 > 6494 MB. Site B: 556 requests, 125 failed: one outage of about 88 s (12 s to 100 s in), plus one single failure at 162 s.

### 3. Provision BIG-IP DNS on site A, timed

The same on lb-f5a, while pc1 loads site A's VIP:

```bash
URL=http://10.20.5.10/ ./ha-load.sh 200 /tmp/prova.log > /tmp/prova.sum &
f5 'tmsh modify sys provision gtm level nominal' && ./gtm-wait.sh lb-f5a
while pgrep -f '[h]a-load.sh 200' >/dev/null; do sleep 1; done; cat /tmp/prova.sum
```

In my run: 535 requests, 130 failed: about 93 s down (15 s to 108 s in), plus two single failures.

### 4. iQuery trust, by hand

BIG-IP DNS talks to each BIG-IP's big3d over iQuery (tcp 4353, TLS with certificates). `iquery-trust.sh` does what `bigip_add` does,
in the open: each unit's device certificate is appended to the other unit's `/config/gtm/server.crt` (the servers its gtmd trusts)
and `/config/big3d/client.crt` (the clients its big3d accepts), then big3d restarts on both. Both units started with only their own
factory certificate.

```bash
sed -n '2,7p' iquery-trust.sh
./iquery-trust.sh
echo "second run, certificates already there: $(./iquery-trust.sh | grep -c 'already there')"
```

You should see four certificates added and `big3d restarted on both`; the second run adds nothing (4 already there).

### 5. Data centres, servers and the sync group

On lb-f5a: a data centre per site, and a GSLB server per BIG-IP. The servers use the HA-link self IPs: the only link between the two
sites in this lab, and their port lockdown (default) already allows iQuery. Virtual-server discovery reads each BIG-IP's virtual
servers, so they need not be typed again.

```bash
f5 'tmsh create gtm datacenter dc-a; tmsh create gtm datacenter dc-b'
f5 'tmsh create gtm server site-a datacenter dc-a product bigip addresses add { 192.168.255.1 { device-name lb-f5a.f5lab.test } } monitor bigip virtual-server-discovery enabled'
f5 'tmsh create gtm server site-b datacenter dc-b product bigip addresses add { 192.168.255.2 { device-name lb-f5b.f5lab.test } } monitor bigip virtual-server-discovery enabled'
for u in f5 f5b; do $u 'tmsh modify gtm global-settings general synchronization yes synchronization-group-name gslb-ab'; done
```

Then iQuery, the discovered virtual servers, and lb-f5b's own GSLB configuration:

```bash
sleep 30; f5 "tmsh show gtm iquery | grep -E '^ *(Server|Server Type|State) '"
f5 "tmsh list gtm server site-a site-b virtual-servers | grep -E 'gtm server|^ +/Common|destination'"
f5b 'tmsh list gtm server 2>&1 | head -3'
```

In my run: iQuery connected to both, site-a as `BIGIP-DNS` and site-b as `BIGIP`. Discovered: site-a vs-api, vs-rhi, vs-web,
vs-web-https; site-b vs-siteb. lb-f5b listed no GSLB servers: it is not in the sync group yet.

### 6. lb-f5b joins the sync group

`gtm_add` on lb-f5b, pointed at lb-f5a, copies lb-f5a's GSLB configuration and joins its sync group. `-no-ssl-exchange` skips its SSH
certificate exchange: the trust from step 4 is already there. It restarts gtmd and named on lb-f5b.

```bash
f5b 'gtm_add -y -no-ssl-exchange 192.168.255.1 </dev/null 2>&1 | tail -4'
sleep 60; f5b "tmsh list gtm server one-line | cut -c1-60; tmsh list gtm datacenter one-line"
f5 "tmsh show gtm iquery | grep -E '^ *(Server|Server Type) '"
```

You should see lb-f5b list both servers and both data centres, and both servers as `BIGIP-DNS`.

### 7. A DNS listener per site

A listener is where BIG-IP DNS receives queries: one address per site, udp and tcp, advertised as a /32 like the app VIPs.

```bash
f5 'tmsh create gtm listener dns-a-udp address 10.20.5.53 mask 255.255.255.255 port 53 ip-protocol udp; tmsh create gtm listener dns-a-tcp address 10.20.5.53 mask 255.255.255.255 port 53 ip-protocol tcp profiles add { dns tcp }; tmsh modify ltm virtual-address 10.20.5.53 route-advertisement any'
f5b 'tmsh create gtm listener dns-b-udp address 10.20.5.153 mask 255.255.255.255 port 53 ip-protocol udp; tmsh create gtm listener dns-b-tcp address 10.20.5.153 mask 255.255.255.255 port 53 ip-protocol tcp profiles add { dns tcp }; tmsh modify ltm virtual-address 10.20.5.153 route-advertisement any'
```

Check the two listener addresses on both units:

```bash
sleep 20; for u in f5 f5b; do $u "tmsh show ltm virtual-address field-fmt | grep -E '^ltm virtual-address|status-reason' | paste - - | grep -E '\.(53|153) '"; done
```

In my run both were `unknown` (a listener has no service check), and an unknown virtual address is advertised. If lb-f5b's listener
shows "GTM marked down: gtmd required but not running", restart gtmd on lb-f5b (see Gotchas):

```bash
f5b "tmsh show ltm virtual dns-b-udp field-fmt | grep -q 'gtmd required' && { bigstart restart gtmd; echo 'gtmd restarted'; sleep 80; } || echo 'site B listeners: no fix needed'"
sleep 10; eval "$LEAF"
```

You should see 10.20.5.10 and 10.20.5.53 via lb-f5a (.3), 10.20.5.140 and 10.20.5.153 via lb-f5b (.4).

### 8. GSLB pools and the wide IP (round robin)

A GSLB pool per site, each holding that site's app virtual server, and the wide IP that answers with one of them:

```bash
f5 'tmsh create gtm pool a pool-a members add { site-a:/Common/vs-rhi }; tmsh create gtm pool a pool-b members add { site-b:/Common/vs-siteb }'
f5 'tmsh create gtm wideip a app.gslb.f5lab.test pools add { pool-a pool-b } pool-lb-mode round-robin; tmsh list gtm wideip a app.gslb.f5lab.test'
```

Ask a listener directly from pc1, then count six answers from each listener (`gslb-dig.sh <pc> <server> <n>`):

```bash
sleep 5; pc1 'dig @10.20.5.53 app.gslb.f5lab.test' | grep -E 'flags|^app'
./gslb-dig.sh pc1 10.20.5.53 6; ./gslb-dig.sh pc1 10.20.5.153 6
```

You should see `flags: qr aa` (authoritative) and TTL 30. In my run: 4 site A, 2 site B from each listener (the dry run: 3 and 3).

### 9. Ratio 3:1

```bash
f5 'tmsh modify gtm wideip a app.gslb.f5lab.test pool-lb-mode ratio pools modify { pool-a { ratio 3 } pool-b { ratio 1 } }'
./gslb-dig.sh pc1 10.20.5.53 40
pc1 'for i in $(seq 16); do dig +short @10.20.5.53 app.gslb.f5lab.test; done' | tr '\n' ' '; echo
```

In my run: 31 of 40 site A, 9 site B. The sequence of answers is not a fixed repeating pattern.

### 10. Topology: the answer depends on who asks

Topology records match the LDNS (the address the query comes from) and score a pool. pc2 gets site B; the rest of the client LAN gets
site A.

```bash
f5 'tmsh create gtm topology ldns: subnet 10.10.0.12/32 server: pool /Common/pool-b score 100; tmsh create gtm topology ldns: subnet 10.10.0.0/24 server: pool /Common/pool-a score 50'
f5 'tmsh modify gtm wideip a app.gslb.f5lab.test pool-lb-mode topology; tmsh list gtm topology'
sleep 5; for p in pc1 pc2 pc3; do ./gslb-dig.sh $p 10.20.5.53 5; done
```

You should see pc1 and pc3: site A, 5 of 5; pc2: site B, 5 of 5.

### 11. Through the resolver

The PCs really resolve through the resolver on lan-switch. Its configuration, then three lookups from pc1, 4 s apart:

```bash
docker exec clab-f5-clos-dc-lan-switch grep -E 'zone|static-stub|server-addresses' /etc/bind/named.conf
pc1 'cat /etc/resolv.conf; for i in 1 2 3; do dig app.gslb.f5lab.test | grep ^app; sleep 4; done'
```

You should see the static-stub zone `gslb.f5lab.test` with server addresses 10.20.5.53 and 10.20.5.153, pc1 using 10.10.0.5, and the
TTL counting down: 30, 26, 22. The resolver answers from its cache until the TTL runs out.

Now pc2 through the resolver, and the resolver's query log:

```bash
./gslb-dig.sh pc2 10.10.0.5 5
docker exec clab-f5-clos-dc-lan-switch tail -3 /var/cache/bind/queries.log | cut -c1-110
pc1 'curl -s http://app.gslb.f5lab.test/ | head -1'
```

In my run pc2 got site A, 5 of 5: the listener sees the resolver (10.10.0.5) as the LDNS, not pc2, so pc2's topology record never
matches. The query log shows the queries coming from 10.10.0.12 to 10.10.0.5. The fetch by name from pc1 reached server2, through
site A.

## Verify

- `./ha-status.sh`: both units active, standalone. `tmsh list cm device-group dg-lb devices` lists only lb-f5a.
- leaf1a: 10.20.5.10/32 and 10.20.5.53/32 via lb-f5a (.3); 10.20.5.140/32 and 10.20.5.153/32 via lb-f5b (.4).
- `tmsh show gtm iquery` on lb-f5a: site-a and site-b, both `BIGIP-DNS`, connected.
- `dig @10.20.5.53 app.gslb.f5lab.test` from pc1: `aa`, TTL 30.
- What I measured: round robin 4:2 of 6 on both listeners; ratio 3:1 gave 31:9 of 40; topology pc1 and pc3 site A, pc2 site B (5/5
  each, straight to the listener); through the resolver, pc2 site A 5/5 and TTL 30, 26, 22.
- Provisioning gtm: site B down about 88 s, site A about 93 s.

## Gotchas

- **Provisioning is an outage.** Provisioning gtm restarts TMM: on a standalone unit the whole site stops answering for about 1.5
  minutes (dry run: site B 84.8 s, site A 99.5 s; recorded: about 88 s and 93 s).
- **lb-f5b showed as `BIGIP`, not `BIGIP-DNS`, and had no GSLB configuration** after the sync group was set on both. iQuery was
  connected both ways, but nothing was copied until `gtm_add -y -no-ssl-exchange 192.168.255.1` on lb-f5b. Then both were `BIGIP-DNS`
  and the configuration was there.
- **lb-f5b's listener stuck down (dry run).** Created seconds after `gtm_add` had restarted gtmd, lb-f5b's listener stayed at "GTM
  marked down: gtmd required but not running", so its /32 was not advertised, until `bigstart restart gtmd` on lb-f5b. Then the bigip
  monitor flapped it down and up once, a minute apart, and it was stable after. In the recorded run the listeners were created later
  and no restart was needed.
- **Round robin was not 3:3.** In the recorded run both listeners gave 4:2 of 6 (the dry run gave 3:3). Ratio 3:1 gave 17:3 of 20,
  30:10, 29:11 and 31:9 of 40 across runs: proportional, not a strict repeating sequence. Why the round robin is uneven over six
  queries is not established: one hypothesis, not verified, is a separate rotation per TMM, with each query arriving on a new source port.
- **Topology through a resolver matches the resolver, not the client.** pc2's /32 record matches only when pc2 asks the listener
  itself. Through 10.10.0.5 the LDNS is the resolver, and the /24 record wins.
- **The resolver caches.** A change on the BIG-IP reaches clients behind the resolver only after the cached answer's TTL (30 s here).
- **The resolver in the lab.** BIND on lan-switch does no forwarding: the container's own DNS (127.0.0.11) never answered there,
  because the containers' default route points into the fabric. So it has an empty local root zone (fast NXDOMAIN or SERVFAIL for
  every other name) and the static-stub for `gslb.f5lab.test`.

## End state

- lb-f5a and lb-f5b standalone and both active: lb-f5a is site A (`vs-rhi` 10.20.5.10 and the part 14-17 objects), lb-f5b is site B
  (`pool-siteb`, `vs-siteb` 10.20.5.140). `dg-lb` holds only lb-f5a; device trust stays.
- gtm provisioned on both; sync group `gslb-ab`; data centres `dc-a`, `dc-b`; servers `site-a`, `site-b`.
- Listeners `dns-a-udp`/`dns-a-tcp` 10.20.5.53 (lb-f5a), `dns-b-udp`/`dns-b-tcp` 10.20.5.153 (lb-f5b), advertised by BGP.
- GSLB pools `pool-a`, `pool-b`; wide IP `app.gslb.f5lab.test` in topology mode (pc2 > site B, the rest of 10.10.0.0/24 > site A).

Part 19 starts here. Save it (from the repo root):

```bash
cd ..
./f5-save.sh
```

## Reset

Restore the UCS you saved at the start of this part (the end of part 17) on both units. This is the path I tested: the load returned
rc 0 on both, gtm was deprovisioned and the pair came back.

```bash
./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<lb-f5a-file>.ucs
./f5-restore.sh lb-f5b /root/f5-clos-dc-secrets/ucs/<lb-f5b-file>.ucs
```

The restore deprovisions gtm, so TMM restarts again on each unit. Then check `./demo/ha-status.sh`. In my run only
`datasync-global-dg` was left pending ("Synchronize lb-f5a to group"). I synced it from lb-f5a, the active unit:

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh run cm config-sync to-group datasync-global-dg'
```

The standby then restarts datasyncd; there was no failover.

## Files used

- `demo/f5fn.sh`: the helpers `f5`, `f5b`, `pc1`, `leaf1a`, `f5merge`.
- `demo/ha-status.sh`: failover state and sync status of both units.
- `demo/ha-load.sh`: pc1 loads a URL five times a second and summarises the failures and the longest gap.
- `demo/gslb/siteb.conf`: site B's application (`pool-siteb`, `vs-siteb`, its virtual address with route advertisement).
- `demo/gtm-wait.sh`: follows TMM and gtmd after provisioning, with the seconds since the start.
- `demo/iquery-trust.sh`: the iQuery certificate exchange between the two units (what `bigip_add` does).
- `demo/gslb-dig.sh`: n queries from a PC to a DNS server, counted per answer and site.

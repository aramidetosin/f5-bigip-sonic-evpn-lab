# Part 15: Where the VIP lands inside SONiC: FRR, APPL_DB and ASIC_DB

| | |
|---|---|
| Video | [SONiC Deep Dive: How an F5 VIP Route Lands in the ASIC (Part 15)](https://youtu.be/js35rDvBAFc) (public from 2026-12-10 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-inside-sonic/) (from 2026-12-10 04:00 UTC) |
| Previous / next | [Part 14](part14.md) / [Part 16](part16.md) |

## Goal

I follow the routed VIP from part 14, 10.20.5.10/32, through one leaf (leaf1a-service): the configuration path (KLISH > CONFIG_DB
> frrcfgd > FRR), then the route path (bgpd > zebra > kernel and fpmsyncd > APPL_DB > orchagent > ASIC_DB). Then I trace a BIG-IP
failover through the kernel, APPL_DB and ASIC_DB in milliseconds, and check that a remote leaf never notices it. Nothing new is
configured on the BIG-IPs, and the leaves are only read.

## Starting state

- The lab is up and `./validate.sh` reports every check PASS.
- Part 14's end state: lb-f5a and lb-f5b in dg-lb, **lb-f5a ACTIVE**; both VIPs answer (10.20.30.100 by ARP, 10.20.5.10 routed:
  vs-rhi, pool-rhi, mon-rhi, route-advertisement any); BGP and BFD from both units to leaf1a (10.254.5.1) and leaf1b (10.254.7.1),
  inbound route map ACCEPT-NONE.
- Units used: both (only for failovers). Leaves used: leaf1a-service (172.21.32.21) and leaf2a-server (172.21.32.23).
- To get here, follow the earlier parts' guides, or restore the UCS saved at the end of part 14 on both units with
  `./f5-restore.sh`.

## Values used in this part

| Object | Value |
|---|---|
| Leaf software | Dell Enterprise SONiC 4.6.0 (SONiC-OS-4.6.0-Enterprise_Base), virtual switch (x86_64-kvm) |
| Route followed | 10.20.5.10/32 in Vrf-App |
| Next hop on leaf1a | 10.254.5.3 (lb-f5a) or 10.254.5.4 (lb-f5b), Vlan3005 |
| Vrf-App | kernel table 1001, VNI 50002 |
| Redis databases | CONFIG_DB: instance redis, db 4; APPL_DB: redis2, db 0; ASIC_DB: redis3, db 1; STATE_DB: redis, db 6 |
| Redis password | /run/redis/auth/passwd on the leaf (readable by admin; the scripts read it and never print it) |
| CONFIG_DB key | BGP_NEIGHBOR\|Vrf-App\|10.254.5.3 |
| zebra options | `-M fpm --fpm-nhg` (routes to fpmsyncd as next-hop groups) |
| Remote leaf | leaf2a-server; service VTEPs 10.255.255.11 (leaf1a) and 10.255.255.12 (leaf1b) |

## Steps

Every command runs on the lab server (root, in the repo root). Load the shortcuts once per shell:

```bash
. ./demo/f5fn.sh
```

`leaf1a` and `leaf2a` run a command on leaf1a-service and leaf2a-server as admin, over SSH.

### 1. Make lb-f5b the active unit

My run of this part starts with lb-f5b active (so the first trace below is lb-f5b > lb-f5a, and the pair ends where it
started). Part 14 ended with lb-f5a active, so fail over once:

```bash
f5 tmsh run sys failover standby
sleep 10; ./demo/ha-status.sh
```

You should see lb-f5b `failover ACTIVE`, lb-f5a `STANDBY`. leaf1a now routes 10.20.5.10/32 via 10.254.5.4.

### 2. What runs on a SONiC leaf

```bash
leaf1a 'show version 2>/dev/null | head -3'
leaf1a 'docker ps --format {{.Names}} | sort | tr "\n" " "'; echo
leaf1a 'docker exec bgp supervisorctl status' | grep -E '^(zebra|bgpd|bfdd|fpmsyncd|frrcfgd) '
leaf1a 'docker exec bgp ps -eo args' | grep ^/usr/lib/frr/zebra
```

You should see: SONiC-OS-4.6.0-Enterprise_Base; containers including bgp, database, swss, syncd, teamd, iccpd; in the bgp
container zebra, bgpd, bfdd, fpmsyncd and frrcfgd RUNNING; zebra started with `-M fpm --fpm-nhg`. The database container runs the
Redis instances; swss runs orchagent and the port, neighbour and FDB sync daemons; syncd is the only process that talks to the
ASIC (here a software SAI).

### 3. The configuration path: CONFIG_DB to FRR

KLISH writes CONFIG_DB; frrcfgd renders CONFIG_DB into FRR's running configuration.

```bash
leaf1a "sonic-db-cli CONFIG_DB HGETALL 'BGP_NEIGHBOR|Vrf-App|10.254.5.3' 2>/dev/null" | paste - -
leaf1a "vtysh -c 'show running-config'" | grep -E '^ neighbor 10.254.5.3 '
```

You should see in CONFIG_DB: `asn 65020`, `keepalive 3`, `holdtime 9`, `bfd true` (and more fields). In FRR, the same neighbour:
remote-as 65020, bfd, advertisement-interval 0, timers 3 9, and a connect timer of 30.

### 4. FRR's RIB and the kernel

```bash
leaf1a "vtysh -c 'show ip route vrf Vrf-App 10.20.5.10/32'" | grep -vE '^$'
leaf1a "vtysh -c 'show ip route vrf Vrf-App 10.20.5.10/32 json'" | grep -E '"(nexthopGroupId|table|installed|ip|interfaceName)"'
leaf1a 'ip route show vrf Vrf-App 10.20.5.10'
```

You should see: known via bgp, distance 20, selected, via 10.254.5.4 on Vlan3005; in JSON `installed true`, `table 1001` and a
`nexthopGroupId` (917 in my run); in the kernel, `10.20.5.10 nhid 917 via 10.254.5.4 dev Vlan3005 proto bgp metric 20`. The same
group number in both: zebra created the next-hop object in the kernel.

### 5. APPL_DB and ASIC_DB, object by object

`demo/sonic-walk.sh` runs on the leaf (fed on stdin) and follows the route through both databases.

```bash
leaf1a 'bash -s' < demo/sonic-walk.sh
```

You should see, one object per line (values from my run):

- APPL_DB `ROUTE_TABLE:Vrf-App:10.20.5.10/32` > `nexthop_group 116`; `NEXT_HOP_GROUP_TABLE:116` > nexthop 10.254.5.4, ifname
  Vlan3005.
- ASIC_DB `SAI_OBJECT_TYPE_ROUTE_ENTRY` dest 10.20.5.10/32 in virtual router `oid:0x3000000000a70` > `NEXT_HOP_ID` (object
  ...b03) > NEXT_HOP of type IP, 10.254.5.4, router interface ...a82 > ROUTER_INTERFACE of type VLAN, same virtual router, the
  switch's MAC (0C:00:BE:E8:57:06), MTU 9100 > VLAN object with VLAN_ID 3005; a NEIGHBOR_ENTRY for 10.254.5.4 on that router
  interface.
- APPL_DB `NEIGH_TABLE:Vlan3005:10.254.5.4` > neigh aa:c1:ab:50:13:fb (lb-f5b's interface 1.1).

The top byte of each object ID gives its type (0x3 virtual router, 0x4 next hop, 0x5 next-hop group, 0x6 router interface). The
same prefix also exists in APPL_DB for Vrf-Outside, with the firewall (10.254.1.3, Vlan3001) as next hop.

### 6. Four layers, one answer

`demo/sonic-layers.sh` polls FRR, the kernel, APPL_DB and ASIC_DB in a loop on the leaf and prints a line whenever any of them
changes. Copy it to the leaf and run it for 4 s:

```bash
scp -q demo/sonic-layers.sh admin@172.21.32.21:/tmp/ && leaf1a 'bash /tmp/sonic-layers.sh 4'
```

You should see one line: `frr 10.254.5.4   kern 10.254.5.4   appl 10.254.5.4 (group 116)   asic 10.254.5.4`. One pass takes
about 0.58 s, too slow to see the order of a change. The next step uses the events instead.

### 7. A failover, traced in milliseconds

`demo/sonic-trace.sh <leaf> <unit> <seconds>` measures the leaf's clock offset over SSH, starts `demo/sonic-trace-leaf.sh` on the
leaf (the kernel's `ip -ts monitor route` and Redis MONITOR on the APPL_DB and ASIC_DB instances, filtered to the route), tells
`<unit>` to go standby 5 s in, and prints every change in ms after the failover command. Run it twice, against whichever unit is
active:

```bash
./demo/ha-status.sh
./demo/sonic-trace.sh 172.21.32.21 $(./demo/ha-status.sh | awk '/failover ACTIVE/ {print $1}') 25
./demo/sonic-trace.sh 172.21.32.21 $(./demo/ha-status.sh | awk '/failover ACTIVE/ {print $1}') 25
./demo/ha-status.sh
```

In my run, the leaf clock was 6.8 s off the lab server's, with an SSH round trip of about 0.4 s, so the seconds after the command
are good to about 0.2 s; the milliseconds between layers all come from the leaf's own clock.

First trace, lb-f5b > lb-f5a:

- nothing for 7 s;
- +7028 ms kernel: nhid 821 via 10.255.255.12 dev Vlan1502 (leaf1b's VTEP, over the L3 VNI VLAN);
- +7032 ms APPL_DB group 116 deleted; +7034 ms route > group 97;
- +7038 ms ASIC_DB route > a next hop of type TUNNEL_ENCAP to 10.255.255.12;
- +7105 ms kernel: nhid 922 via 10.254.5.3 (lb-f5a, direct); +7109 ms APPL_DB group 117 = 10.254.5.3; +7112 ms route > group 117;
- +7117 ms ASIC_DB route > next hop ...b02, type IP, 10.254.5.3.

Second trace, lb-f5a > lb-f5b:

- nothing for 10 s;
- +10143 ms kernel: nhid 927, multipath (several next hops); +10155 ms APPL_DB group 118 = 10.254.5.4; +10174 ms route > group
  24036 (an EVPN multipath group);
- +10176 ms ASIC_DB route > a NEXT_HOP_GROUP object;
- +10220 ms kernel: nhid 928 via 10.254.5.4 (direct); +10231 ms route > group 118; +10235 ms groups 117 and 24036 deleted;
- +10237 ms ASIC_DB route > next hop ...b03 (10.254.5.4).

The pair ends with lb-f5b ACTIVE, lb-f5a STANDBY.

### 8. A remote leaf

```bash
leaf2a "vtysh -c 'show ip route vrf Vrf-App 10.20.5.10/32'" | grep -E 'Known|via'
leaf2a "sonic-db-cli APPL_DB HGET 'ROUTE_TABLE:Vrf-App:10.20.5.10/32' nexthop_group 2>/dev/null"
```

You should see: 10.20.5.10/32 via 10.255.255.11 and 10.255.255.12, equal cost (both service leaves' VTEPs); APPL_DB next-hop group
24006. It was the same before and after the failovers: a BIG-IP failover never reaches the remote leaves.

## Verify

- FRR, the kernel, APPL_DB and ASIC_DB on leaf1a agree on the same next hop (sonic-layers.sh prints one line).
- The walk ends at the active unit's MAC in NEIGH_TABLE (aa:c1:ab:50:13:fb for lb-f5b, aa:c1:ab:ed:0b:53 for lb-f5a).
- Over six traces in my runs: the leaf heard the change 3.7 to 10.1 s after the failover command; from the kernel to ASIC_DB took
  9 to 33 ms. Order every time: kernel first (zebra), then APPL_DB (fpmsyncd, 5-12 ms later), then ASIC_DB (orchagent, 2-7 ms after
  that, in the exploration runs).
- Every trace had an intermediate step of about 80 ms before the direct next hop: via leaf1b's VTEP (lb-f5b > lb-f5a runs) or an
  EVPN multipath group (lb-f5a > lb-f5b runs).
- leaf2a: ECMP via 10.255.255.11 and .12, group 24006, unchanged.

## Gotchas

- The seconds of a routed-VIP failover (part 14) are not spent in SONiC: the leaf hears nothing for 3.7-10.1 s, then programs all
  layers within about 90 ms. The delay is before the BGP update reaches the leaf.
- The 80 ms detour has a likely explanation: leaf1b still had its own route to the old active unit and advertised it over EVPN
  until that unit withdrew. I did not capture leaf1b at the same moment, so this is a hypothesis (not measured).
- CONFIG_DB is the source of truth for FRR's configuration on this switch. A change typed straight into vtysh is not what
  frrcfgd renders at boot.
- With `--fpm-nhg`, APPL_DB holds routes that point at next-hop groups (NEXT_HOP_GROUP_TABLE), not inline next hops. Look up the
  group to find the next hop.
- On this virtual switch the Linux kernel forwards the packets; syncd drives a software SAI. The databases and SAI objects are the
  same as on hardware.
- Redis needs the password from /run/redis/auth/passwd. The scripts put it in REDISCLI_AUTH and never print it; `sonic-db-cli`
  takes about 0.16 s per call.
- A polling loop (about 0.58 s per pass) sees all four layers change in the same pass. Use event monitors (ip monitor, Redis
  MONITOR) to see the order.

## End state

- No configuration changed on the BIG-IPs or the leaves. Part 14's objects are unchanged.
- **lb-f5b ACTIVE, lb-f5a STANDBY** (two failovers in step 7 after the one in step 1). Both VIPs answer.
- Scripts copied to the leaf's /tmp (sonic-layers.sh, sonic-trace-leaf.sh) are harmless and can stay.
- Optional: `./f5-save.sh` (the configuration is the same as at the end of part 14).

## Reset

Nothing to undo: the leaves were only read, and MONITOR and `ip monitor` only listen. To make lb-f5a active again as at the start
of this part, run `f5b tmsh run sys failover standby`.

## Files used

- `demo/f5fn.sh`: shell shortcuts (`f5`, `f5b`, `leaf1a`, `leaf2a`).
- `demo/ha-status.sh`: one line per unit: failover status, traffic-group-1 state, sync status.
- `demo/sonic-walk.sh`: runs on a leaf; walks one route through APPL_DB and ASIC_DB, one object per line.
- `demo/sonic-layers.sh`: runs on a leaf; polls FRR, kernel, APPL_DB and ASIC_DB and prints each change.
- `demo/sonic-trace.sh`: from the lab server; fails the given unit over and prints the leaf's route events in ms.
- `demo/sonic-trace-leaf.sh`: runs on the leaf (copied by sonic-trace.sh); records kernel, APPL_DB and ASIC_DB events.

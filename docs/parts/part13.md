# Part 13: High availability across a leaf pair

| | |
|---|---|
| Video | [F5 BIG-IP HA: Sync-Failover Across a Leaf Pair, Timed (Part 13)](https://youtu.be/1WD3s8T2Qkc) (public from 2026-12-05 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-high-availability/) (from 2026-12-05 04:00 UTC) |
| Previous / next | [Part 12](part12.md) / [Part 14](part14.md) |

## Goal

I join lb-f5a and lb-f5b into an active-standby pair: distinct device names, HA addresses, device trust, a sync-failover
device group and the first config sync. Then I time failover under traffic (planned, with MAC masquerade, and a hard failure),
watch what leaf1a and a remote leaf see when the addresses move, and test config sync, auto-sync and the loss of the HA cable.

## Starting state

- The lab is up and `./validate.sh` (on the lab server, in the repo root) reports every check PASS.
- Part 12's end state on lb-f5a: vs-web (10.20.30.100:80, pool-web, SNAT pool snat-web, profiles http-xff, oneconnect, reqlog-web,
  tcp; no iRules, no policies) and vs-web-https (10.20.30.100:443), their pools and monitors, the floating self IPs float-external
  10.20.30.10 and float-internal 10.20.0.240 (traffic-group-1).
- lb-f5b, from part 2 only: VLANs external (1.1), internal (1.2) and ha (1.3), self IPs 10.20.30.12, 10.20.0.242 and
  192.168.255.2 (traffic-group-local-only). No floating self IPs, no virtual servers. Its cm device name is still the default
  `bigip1`.
- Both units are standalone and licensed, and both have the same admin password.
- Both units are used in this part.
- Before you start, save both units so you can come back: `./f5-save.sh` (one UCS per unit). A UCS saved at the end of part 12 can
  be restored with `./f5-restore.sh lb-f5a <file>.ucs` (and the same for lb-f5b).

## Values used in this part

| Object | Value |
|---|---|
| Device names | lb-f5a.f5lab.test, lb-f5b.f5lab.test (lb-f5b renamed from `bigip1`) |
| HA VLAN (direct cable, interface 1.3 on each unit) | 192.168.255.0/30: lb-f5a .1, lb-f5b .2 |
| Management addresses | lb-f5a 172.21.32.43, lb-f5b 172.21.32.44 |
| Config sync and mirroring address | the unit's HA self IP |
| Failover unicast addresses | the HA self IP and the management address (two paths) |
| Device group | dg-lb, type sync-failover, network failover enabled (auto-sync enabled later) |
| Traffic group | traffic-group-1 (floating selfs, VIP 10.20.30.100, SNAT translations) |
| MAC masquerade | traffic-group-1 mac 02:00:0a:14:1e:0a |
| Unit MACs (interface 1.1) | lb-f5a aa:c1:ab:ed:0b:53 (leaf1a Ethernet3), lb-f5b aa:c1:ab:50:13:fb (leaf1a Ethernet4) |
| External VLAN on leaf1a | Vlan130; leaf1a VTEP 10.255.255.11, leaf1b VTEP 10.255.255.12 |
| Failover timeout | sys db failover.nettimeoutsec 3 (default, not changed) |
| Test load | pc1, 5 requests per second to http://app.f5lab.test/, 1 s timeout (./demo/ha-load.sh) |

## Steps

Every command runs on the lab server (root, in the repo root). First load the shortcuts once per shell:

```bash
. ./demo/f5fn.sh
```

`f5` and `f5b` run a command on lb-f5a / lb-f5b (bash as admin, over SSH); `pc1` runs a command on pc1; `leaf1a` and `leaf2a` run a
SONiC command on leaf1a-service (the BIG-IPs' external VLAN) and leaf2a-server (a remote VTEP). `./demo/ha-status.sh` prints one
line per unit: failover status, traffic-group-1 state, sync status.

### 1. The starting point: two standalone units

Both units are active for themselves, and the fabric knows the VIP only behind lb-f5a.

```bash
./demo/ha-status.sh
f5 tmsh list cm device one-line | grep -oE 'cm device [^ ]+'; f5b tmsh list cm device one-line | grep -oE 'cm device [^ ]+'
leaf1a 'show arp' | grep -E '10.20.30.(10|100) '
leaf1a 'show mac' | grep -iE 'aa:c1:ab:(ed:0b:53|50:13:fb)|02:00:0a:14:1e:0a'
leaf2a "vtysh -c 'show evpn arp-cache vni all'" | grep -E '10.20.30.100 '
```

You should see: both units `failover ACTIVE`, `traffic-group-1 ACTIVE`, `sync: Standalone`; `cm device lb-f5a.f5lab.test` and
`cm device bigip1`; on leaf1a, 10.20.30.10 and 10.20.30.100 at aa:c1:ab:ed:0b:53 on Ethernet3, Vlan130; on leaf2a, 10.20.30.100 as a
remote entry via leaf1a's VTEP 10.255.255.11. The last column of the EVPN entry is the MAC mobility sequence number.

### 2. Distinct device names and HA addresses

Two devices in one trust domain need different names. Then each unit gets its config sync address, its failover (unicast)
addresses on two paths, and its mirroring address.

```bash
f5b tmsh mv cm device bigip1 lb-f5b.f5lab.test && f5b tmsh list cm device one-line | grep -oE 'cm device [^ ]+'
f5 tmsh modify cm device lb-f5a.f5lab.test configsync-ip 192.168.255.1 unicast-address { { ip 192.168.255.1 } { ip 172.21.32.43 } } mirror-ip 192.168.255.1
f5b tmsh modify cm device lb-f5b.f5lab.test configsync-ip 192.168.255.2 unicast-address { { ip 192.168.255.2 } { ip 172.21.32.44 } } mirror-ip 192.168.255.2
f5b tmsh list cm device lb-f5b.f5lab.test configsync-ip unicast-address mirror-ip
```

You should see: `cm device lb-f5b.f5lab.test`. The unicast addresses are stored as `{ ip 192.168.255.2 }` and
`{ ip management-ip }`: the management address is kept as a keyword, not as the literal address.

### 3. Device trust

From lb-f5a, add lb-f5b to the trust domain. The command needs lb-f5b's admin credentials. Read the password into a variable from
where it lives, so it is never typed or shown:

```bash
PW=$(sed -n 's/^PASSWORD=//p' /root/f5-clos-dc-secrets/lb-f5b.env)
f5 tmsh modify cm trust-domain Root ca-devices add { 192.168.255.2 } name lb-f5b.f5lab.test username admin password "$PW"
f5 tmsh list cm trust-domain Root ca-devices
f5 tmsh show cm sync-status | grep -E '^(Status|Mode)'
```

You should see: a warning that `name`, `username` and `password` are deprecated properties (the command still works); both
devices in `ca-devices`; `Status In Sync`, `Mode trust-only`. If you keep your credentials elsewhere, replace the first line
with `PW='<lb-f5b-admin-password>'`.

### 4. The sync-failover device group and the first sync

Create the group with both devices, wait, then push lb-f5a's configuration to the group. Watch which unit ends up active.

```bash
f5 tmsh create cm device-group dg-lb devices add { lb-f5a.f5lab.test lb-f5b.f5lab.test } type sync-failover network-failover enabled
sleep 10; f5 tmsh show cm sync-status | grep -A6 '^Status'
f5 tmsh run cm config-sync to-group dg-lb; sleep 20; ./demo/ha-status.sh
for u in f5 f5b; do $u "grep -hE 'Leaving active|Remaining Active|gratuitous|Active for traffic|Standby for traffic' /var/log/ltm | tail -n 3"; done
leaf1a 'show arp' | grep -E '10.20.30.(10|100) '
```

You should see: `Awaiting Initial Sync`, then after the sync `In Sync` on both, with **lb-f5a STANDBY and lb-f5b ACTIVE**. lb-f5a
logged "Leaving active in favor of active peer"; lb-f5b logged "Remaining Active" and then requested TMM to resend gratuitous ARPs
for traffic-group-1. On leaf1a, 10.20.30.10 and .100 moved to aa:c1:ab:50:13:fb on Ethernet4. The first sync moved the traffic:
lb-f5b was a standalone active unit, and when the pair formed, lb-f5a yielded. The application kept answering.

### 5. What the sync copied, and what it left alone

```bash
f5b tmsh list net self one-line
f5b tmsh list ltm virtual one-line | grep -oE 'ltm virtual [^ ]+|destination [^ ]+'
f5b tmsh list sys global-settings hostname
```

You should see: float-external and float-internal (traffic-group-1) and vs-web / vs-web-https arrived on lb-f5b; its own self IPs
and its hostname are unchanged.

### 6. A planned failover under traffic

pc1 asks the VIP five times a second for 24 s; 8 s in, the active unit (lb-f5b) is told to go standby.

```bash
(sleep 8; f5b tmsh run sys failover standby >/dev/null) & ./demo/ha-load.sh 24
./demo/ha-status.sh
leaf1a 'show arp' | grep -E '10.20.30.(10|100) '
leaf2a "vtysh -c 'show evpn arp-cache vni all'" | grep -E '10.20.30.100 '
```

In my run: `89 requests, 1 failed`. lb-f5a ACTIVE; leaf1a's ARP entries back on Ethernet3 at lb-f5a's MAC; leaf2a still learns the
VIP via leaf1a's VTEP, with a higher sequence number (the move was signalled by EVPN MAC mobility).

### 7. MAC masquerade, then a failover the other way

With masquerade, traffic-group-1 uses one MAC on whichever unit is active, so the leaves only relearn the port, not the MAC.

```bash
f5 tmsh modify cm traffic-group traffic-group-1 mac 02:00:0a:14:1e:0a && f5 tmsh run cm config-sync to-group dg-lb
leaf1a 'show arp' | grep -E '10.20.30.(10|100) '; leaf1a 'show mac' | grep -iE 'aa:c1:ab:(ed:0b:53|50:13:fb)|02:00:0a:14:1e:0a'
(sleep 8; f5 tmsh run sys failover standby >/dev/null) & ./demo/ha-load.sh 24
./demo/ha-status.sh; leaf1a 'show arp' | grep -E '10.20.30.(10|100) '; leaf1a 'show mac' | grep -iE 'aa:c1:ab:(ed:0b:53|50:13:fb)|02:00:0a:14:1e:0a'
leaf2a "vtysh -c 'show evpn mac vni all'" | grep -iE 'VNI|02:00:0a:14:1e:0a'
```

In my run: the VIP and the floating address at 02:00:0a:14:1e:0a on Ethernet3 right after the sync; failover lb-f5a > lb-f5b:
`88 requests, 1 failed`; the same MAC, now on Ethernet4. leaf2a lists the MAC once per VNI: VNI 10130 via 10.255.255.11 (leaf1a,
the external VLAN 130 side) and VNI 10120 via 10.255.255.12 (leaf1b, the internal side, where the floating 10.20.0.240 lives).

### 8. Config sync by hand, then auto-sync

A change on the active unit (now lb-f5b) leaves the pair out of sync until it is pushed.

```bash
f5b tmsh modify ltm pool pool-web description '"part 13 sync test"'; ./demo/ha-status.sh
f5b tmsh show cm sync-status | grep -A3 '^Details'
f5b tmsh run cm config-sync to-group dg-lb; sleep 8; ./demo/ha-status.sh; f5 tmsh list ltm pool pool-web description
f5b tmsh modify cm device-group dg-lb auto-sync enabled; f5b tmsh modify ltm pool pool-web description none; sleep 8; ./demo/ha-status.sh; f5 tmsh list ltm pool pool-web description
```

You should see: `Changes Pending` on both units and "Synchronize lb-f5b.f5lab.test to group dg-lb" as the recommended action; after
the sync, `In Sync` and the description on lb-f5a. With auto-sync enabled, removing the description on lb-f5b reaches lb-f5a without
a manual sync.

### 9. A hard failure: the active unit frozen

`docker pause` freezes lb-f5b (the active unit) 8 s into the load: no goodbye, no heartbeats. Measure from the traffic: status
commands over SSH to a frozen unit hang.

```bash
(sleep 8; docker pause clab-f5-clos-dc-lb-f5b >/dev/null) & ./demo/ha-load.sh 30
f5 "grep -hE 'No failover status|Leaving Standby|Active for traffic' /var/log/ltm | tail -n 4"
docker unpause clab-f5-clos-dc-lb-f5b; sleep 60; ./demo/ha-status.sh
```

In my run: `102 requests, 4 failed`, 3.9 s without an answer. lb-f5a logged "No failover status messages received for 3.100
seconds" on both paths, then "Leaving Standby for Active" one second later. After the unpause (about 40 s frozen), lb-f5b came back
still ACTIVE; with two active units, lb-f5a logged "Leaving active in favor of active peer" and went STANDBY, and lb-f5b resent
gratuitous ARPs: the traffic moved back to lb-f5b.

### 10. The HA cable fails

Disable interface 1.3 on lb-f5b: the failover heartbeats still have the management path.

```bash
f5b tmsh modify net interface 1.3 disabled; sleep 10; ./demo/ha-status.sh
f5b "grep -h 'No failover status' /var/log/ltm | tail -n 1"
f5b tmsh modify net interface 1.3 enabled; sleep 8; ./demo/ha-status.sh
```

You should see: no failover. lb-f5b logs "No failover status messages ... 3.100 seconds, from device lb-f5a" for the HA path only;
the management path keeps the pair in agreement. Status unchanged after the interface is enabled again.

### 11. Check and save

```bash
f5 tmsh list cm device-group dg-lb one-line; f5 tmsh list cm traffic-group traffic-group-1 mac
./demo/ha-status.sh; pc1 'curl -s http://app.f5lab.test/' | grep -E '^(server|client seen):'
f5 tmsh save sys config | tail -1; f5b tmsh save sys config | tail -1
```

You should see: dg-lb with auto-sync enabled, type sync-failover; mac 02:00:0a:14:1e:0a; lb-f5b ACTIVE, lb-f5a STANDBY, In Sync;
the app answered (server1, client seen 10.20.0.202 in my run).

## Verify

- `./demo/ha-status.sh`: one unit `failover ACTIVE`, the other `STANDBY`, both `sync: In Sync`.
- Planned failover under 5 requests/s: at most one failed request (89 requests, 1 failed; with masquerade 88 requests, 1 failed).
  In my rehearsal runs without masquerade: 0, 0, 1, 1, 1 failed; with masquerade: 1, 0, 1, 0, 1.
- Hard failure: 4 failed requests, 3.9 s without an answer (failover.nettimeoutsec 3: lb-f5a waited 3.1 s, then went active).
- leaf1a follows the move (ARP and MAC on Ethernet3 or Ethernet4); a remote leaf sees it as an EVPN MAC mobility update.
- `tmsh show cm failover-status` on a unit lists both heartbeat paths (management 172.21.32.43:1026 and HA 192.168.255.1:1026 on
  lb-f5a), each with packets received, transitions and `Ok`.

## Gotchas

- The first config sync moved the traffic. lb-f5b was a standalone active unit; when the pair formed, lb-f5a yielded ("Leaving
  active in favor of active peer"). Plan a pairing like a failover.
- The trust command prints a deprecated-properties warning for `name`, `username` and `password`. It still worked.
- `unicast-address` stores the management path as the keyword `management-ip`, not the address.
- Not synced: non-floating self IPs, VLANs, the hostname. Synced: floating self IPs, virtual servers, pools, profiles, and (tested
  with auto-sync on) a static route. "Configuration CRC values disagree amongst peers" appears in the log until the peers agree.
- No automatic failback: traffic-group-1 has auto-failback-enabled false (auto-failback-time 60), failover-method ha-order, ha-order
  none, ha-group none. A recovered unit does not take the traffic back by itself.
- When a frozen unit comes back still active, two units are briefly active. In both of my hard-failure runs (lb-f5a frozen about
  148 s, and lb-f5b frozen about 40 s) lb-f5a was the one that yielded. So after a hard failure the traffic can move twice.
- Do not measure a hard failure with status commands: SSH to a frozen unit hangs. Measure from the client side (ha-load.sh).
- The standby is not idle: it runs its own health monitors (pool-web members available on the standby), so it knows the pool
  state at the moment it takes over.
- With masquerade, a remote leaf lists the same MAC twice, once per VNI, behind two different VTEPs (VLAN 130 side on leaf1a,
  internal side on leaf1b). That is expected: both floating addresses share the traffic group's MAC.

## End state

- lb-f5a and lb-f5b: sync-failover pair dg-lb, auto-sync enabled, network failover over the HA VLAN and the management network.
- traffic-group-1 MAC masquerade 02:00:0a:14:1e:0a.
- **lb-f5b ACTIVE, lb-f5a STANDBY**, In Sync. All part 12 objects exist on both units.
- Configuration saved on both units. Save a UCS of both units now: `./f5-save.sh`.

## Reset

Restore the UCS you saved before step 1, on both units:

```bash
./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<lb-f5a-file>.ucs
./f5-restore.sh lb-f5b /root/f5-clos-dc-secrets/ucs/<lb-f5b-file>.ucs
```

That is how I went back to this part's starting state after my rehearsal.

## Files used

- `demo/f5fn.sh`: shell shortcuts (`f5`, `f5b`, `pc1`, `leaf1a`, `leaf2a`).
- `demo/ha-status.sh`: one line per unit: failover status, traffic-group-1 state, sync status.
- `demo/ha-load.sh`: pc1 asks a URL five times a second (1 s timeout), then prints requests, failures and the longest gap.

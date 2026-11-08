# Part 3: The first virtual server, and why it fails behind a firewall

| | |
|---|---|
| Video | [F5 First Virtual Server: Why It Fails and How SNAT Fixes It (Part 3)](https://youtu.be/ZM1QMd9j_9k) (public from 2026-11-12 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-first-virtual-server/) (from 2026-11-12 04:00 UTC) |
| Previous / next | [Part 2](part02.md) / [Part 4](part04.md) |

## Goal

I build the first load-balanced application on lb-f5a: three nodes, a pool with an HTTP monitor, and a virtual server
10.20.30.100:80 with source address translation **None**. From pc1 the request is sent and never answered. I prove where the packets
die on the BIG-IP, on the servers and on the firewall, then fix it with SNAT AutoMap and measure what a user gets.

## Starting state

- The end state of [Part 2](part02.md): both units licensed with the platform basics; on lb-f5a the VLANs `external`, `internal`,
  `ha`, the self IPs `self-external` 10.20.30.11, `self-internal` 10.20.0.241, `self-ha` 192.168.255.1, the floating self IPs
  `float-external` 10.20.30.10 and `float-internal` 10.20.0.240 (traffic-group-1), and the route `default-gw` via 10.20.30.1.
- If you rebuilt the lab: license the units again, then restore the UCS saved at the end of part 2 with
  `./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<file>.ucs` (and the same for lb-f5b).
- Unit used: **lb-f5a only**. lb-f5b gets these objects by config sync when the pair is built (part 13).

Bash on lb-f5a from the lab server: `ssh admin@clab-f5-clos-dc-lb-f5a`. Web UI: `https://172.21.32.43`.

## Values used in this part

| Object | Value |
|---|---|
| Nodes | `server1` 10.20.0.11, `server2` 10.20.0.12, `server3` 10.20.0.13 (node default monitor) |
| Pool | `pool-web`: monitor `http`, Round Robin, members server1:80, server2:80, server3:80 |
| Virtual server | `vs-web`: Standard, 10.20.30.100:80, profiles `http` + `tcp`, default pool `pool-web` |
| Source address translation | None first, then Auto Map |
| Virtual address | 10.20.30.100, ARP enabled, traffic-group-1 (created with the virtual server) |
| Client | pc1 10.10.0.11 (management 172.21.32.111), `app.f5lab.test` = 10.20.30.100 in its `/etc/hosts` |
| Firewall | fw-pa, management 172.21.32.40; app-side transit address 10.254.2.3 |

## Steps

### 1. Nodes

In the web UI of lb-f5a (`https://172.21.32.43`), three times:
- **Local Traffic > Nodes > Create**: Name `server1`; Address `10.20.0.11`; **Finished**.
- **Local Traffic > Nodes > Create**: Name `server2`; Address `10.20.0.12`; **Finished**.
- **Local Traffic > Nodes > Create**: Name `server3`; Address `10.20.0.13`; **Finished**.

Naming nodes after the servers (instead of letting the BIG-IP name them by address) keeps every later output readable.

### 2. Pool

**Local Traffic > Pools > Create**: Name `pool-web`; Health Monitors: move `http` to Active; Load Balancing Method: `Round Robin`; New
Members: **Node List**, `server1`, Service Port `80`, **Add**; `server2`, `80`, **Add**; `server3`, `80`, **Add**; **Finished**.

The status icon starts blue (unknown) until the monitor's first checks finish.

### 3. Virtual server, with SNAT None

**Local Traffic > Virtual Servers > Create**: Name `vs-web`; Type `Standard`; Destination Address `10.20.30.100`; Service Port `80`;
HTTP Profile (Client): `http`; Source Address Translation: `None` (the default, chosen deliberately); Default Pool: `pool-web`;
**Finished**.

### 4. The same objects in tmsh

On lb-f5a (bash as admin):

```bash
tmsh list ltm node
tmsh list ltm pool pool-web
tmsh show ltm pool pool-web members field-fmt | grep -E 'ltm pool|addr |availability-state'
tmsh list ltm virtual vs-web
tmsh list ltm virtual-address 10.20.30.100 arp traffic-group
```

You should see:
- three nodes, each just an address;
- three members `server1:http`, `server2:http`, `server3:http`, monitor `http`, all `available`;
- `vs-web` with destination `10.20.30.100:http`, the pool, the `tcp` and `http` profiles, `translate-address enabled` (rewrite the
  destination), and **no** `source-address-translation` block;
- the virtual address with `arp enabled` and `traffic-group traffic-group-1`.

### 5. The request that never returns

On the lab server (root, in the repo folder):

```bash
ssh admin@172.21.32.111 'hostname; ip -4 -br addr show eth1; grep app.f5lab.test /etc/hosts'
ssh admin@172.21.32.111 'time curl -v -m 10 http://app.f5lab.test/'
```

You should see pc1 at 10.10.0.11, `app.f5lab.test` = 10.20.30.100, then curl: connected, `Request completely sent off`, and after 10
seconds `Operation timed out after 10002 milliseconds with 0 bytes received` (my run). The TCP connection to the virtual server was
established: reaching the BIG-IP is not the problem.

### 6. The way back to pc1 goes through the firewall

On the lab server:

```bash
ssh admin@172.21.32.23 'hostname; sudo vtysh -c "show ip route vrf Vrf-App 10.10.0.0/24"'
ssh admin@172.21.32.21 'hostname; sudo vtysh -c "show ip route vrf Vrf-App 10.10.0.0/24"'
```

You should see, on leaf2a-server, 10.10.0.0/24 by BGP with two next hops, 10.255.255.11 and 10.255.255.12 (the service leaves'
VTEPs) over VLAN 1502; on leaf1a-service, the same prefix via 10.254.2.3, the firewall. The servers' gateway is the fabric
(10.20.0.1), so a server's reply to 10.10.0.11 has one way out: the firewall.

### 7. Where the packets die: lb-f5a

Start a request from pc1 in the background (8 seconds later), and capture on lb-f5a on interface `0.0` (every VLAN). On the lab
server:

```bash
(sleep 8; ssh -n admin@172.21.32.111 'curl -s -m 10 -o /dev/null http://app.f5lab.test/') &
ssh admin@clab-f5-clos-dc-lb-f5a "timeout 20 tcpdump -nni 0.0 -l 'tcp port 80 and host 10.10.0.11'"
```

You should see the client side complete: pc1's SYN to 10.20.30.100, the BIG-IP's SYN-ACK, pc1's ACK, the GET, the BIG-IP's ACK (full
proxy). Then the server side: a SYN **from 10.10.0.11** to a pool member, repeated at +3, +6 and +9 seconds, never answered. At 10
seconds pc1 sends its FIN and the BIG-IP resets both sides (the server-side RST also carries 10.10.0.11).

### 8. Where the packets die: the servers

The servers' admin accounts cannot capture, so this runs on the lab server inside each server's container:

```bash
for n in 1 2 3; do docker exec clab-f5-clos-dc-server$n timeout 22 tcpdump -nni bond0 -l 'tcp port 80 and host 10.10.0.11' 2>/dev/null | sed -u "s/^/server$n  /" & done; sleep 8; ssh -n admin@172.21.32.111 'curl -s -m 10 -o /dev/null http://app.f5lab.test/'; wait
```

You should see the SYN arrive from 10.10.0.11 on the chosen member, and that member answer with a SYN-ACK every time (and retransmit
it on its own timer). The SYN-ACK goes to 10.10.0.11 through the server's default gateway, the fabric, not back to the BIG-IP. At the
end, the BIG-IP's RST, also from 10.10.0.11.

### 9. Where the packets die: the firewall

On the lab server, open the PAN-OS CLI and read the drop counter:

```bash
ssh admin@172.21.32.40
```

In the PAN-OS CLI:

```
set cli pager off
show counter global | match non_syn
exit
```

Then one request from pc1, on the lab server:

```bash
ssh admin@172.21.32.111 'curl -s -m 10 -o /dev/null -w "HTTP %{http_code} after %{time_total} s\n" http://app.f5lab.test/'
```

And the firewall again (`ssh admin@172.21.32.40`):

```
set cli pager off
show counter global | match non_syn
show session all filter destination 10.20.30.100
exit
```

You should see two counters at the same value, one of them `flow_tcp_non_syn_drop` ("non-SYN TCP without session match"). In my run they went from 45 to 53
for one request (`HTTP 000 after 10` seconds): eight drops, the server's SYN-ACK and its retransmissions. The firewall has a session
for pc1 > 10.20.30.100, not for the server's reply, so the SYN-ACK is dropped **before** policy: it shows as a counter, not as a
traffic-log entry. The session table for 10.20.30.100 is already empty (the BIG-IP reset the connection when pc1 gave up).

### 10. The fix: SNAT AutoMap

**Local Traffic > Virtual Servers > `vs-web`**: Source Address Translation: `Auto Map`; **Update**.

The same in tmsh:

```bash
tmsh modify ltm virtual vs-web source-address-translation { type automap }
```

The BIG-IP now opens the server-side connection from one of its own internal addresses, so the server replies straight to the
BIG-IP, and the answer leaves through the firewall session the request came in on.

### 11. pc1 after the fix

On the lab server:

```bash
ssh admin@172.21.32.111 'for i in 1 2 3 4 5 6; do curl -s -m 5 http://app.f5lab.test/ | grep -E "^(server|client seen):"; done'
```

You should see six answers. In my run: server1, server2, server1, server3, server2, server1, and `client seen: 10.20.0.240` every
time: AutoMap picked the floating internal self IP, and the client's source port was kept.

### 12. The firewall after the fix

Repeat step 9 exactly. In my run the drop counter read 135 before and 135 after (higher than before because of the failing tests in
between), and the request returned `HTTP 200` in about 15 ms.

### 13. lb-f5a after the fix

On the lab server:

```bash
(sleep 8; ssh -n admin@172.21.32.111 'curl -s -m 5 -o /dev/null http://app.f5lab.test/') &
ssh admin@clab-f5-clos-dc-lb-f5a "timeout 14 tcpdump -nni 0.0 -l 'tcp port 80 and (host 10.10.0.11 or host 10.20.0.240)'"
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm virtual vs-web' | grep -A3 source-address-translation
```

You should see two complete TCP conversations: the client side as before, and a server side from 10.20.0.240 to a member with a
SYN-ACK straight back, the request and the response. The source port is the same on both sides (51544 in my run). tmsh shows
`source-address-translation { type automap }`.

## Verify

Reset the statistics, send 90 new connections from pc1, then read the server-side totals per member. On the lab server:

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh reset-stats ltm pool pool-web; tmsh reset-stats ltm virtual vs-web'
ssh -n admin@172.21.32.111 'ok=0; for i in $(seq 90); do [ $(curl -s -o /dev/null -m 3 -w %{http_code} http://app.f5lab.test/) = 200 ] && ok=$((ok+1)); done; echo "90 requests, $ok answered"'
ssh admin@clab-f5-clos-dc-lb-f5a "tmsh show ltm pool pool-web members field-fmt" | grep -E '^ +addr |serverside.tot-conns'
```

What I measured: `90 requests, 90 answered`, and 29 / 30 / 31 server-side connections per member. Not a strict 1-2-3 rotation: each of
the 4 TMMs keeps its own round-robin pointer, which also explains the order 1, 2, 1, 3, 2, 1 in step 11.

In a real browser: pc1's web desktop (`https://172.21.32.111:3001`, user `admin`, password from `sudo cat /root/f5-clos-dc-secrets/pc.env`
on the lab server), load `http://app.f5lab.test/`. In my run every reload stayed on server2 (green), with `client seen:
10.20.0.240:34508` each time: one kept-alive TCP connection. The BIG-IP balances connections, not requests (OneConnect, part 9).

## Gotchas

- Without SNAT, the BIG-IP keeps the client's address as the source on the server side. The servers' gateway is the fabric, so the
  reply goes to the firewall, which has no session for it and drops it as a non-SYN packet without a session match.
- That drop happens before policy: look at `show counter global | match non_syn`, not at the traffic log.
- The curl on pc1 shows a connected session and a sent request, then a timeout: the client side is fine, which points past the BIG-IP.
- AutoMap prefers the floating self IP (10.20.0.240) over the unit's own (10.20.0.241).
- Firefox reloads stay on one member: the browser reuses one TCP connection.
- `tcpdump` on the BIG-IP works from admin's bash; `-i 0.0` captures every VLAN.
- Seen once, not reproduced in three later runs: one 90-request run lost 6 requests while leaf1a-service's ARP entry for 10.20.30.100
  briefly showed Action Drop.

## End state

On lb-f5a (lb-f5b unchanged from part 2):
- nodes `server1`, `server2`, `server3`;
- pool `pool-web` (monitor `http`, Round Robin, members server1:80, server2:80, server3:80, all available);
- virtual server `vs-web` 10.20.30.100:80, profiles `http` + `tcp`, default pool `pool-web`, **source address translation Auto Map**;
- virtual address 10.20.30.100 (ARP enabled, traffic-group-1).

Save the config on the unit (`tmsh save sys config`) and a UCS of both units (on the lab server, in the repo folder):

```bash
./f5-save.sh
```

Remember to revoke both licences before `./down.sh` (then `./down.sh --licences-revoked`).

## Reset

Back to the end state of part 2, on lb-f5a (bash as admin), in dependency order:

```bash
tmsh delete ltm virtual vs-web
tmsh list ltm virtual-address
```

If `10.20.30.100` is still listed, delete it with `tmsh delete ltm virtual-address 10.20.30.100`. Then:

```bash
tmsh delete ltm pool pool-web
tmsh delete ltm node server1
tmsh delete ltm node server2
tmsh delete ltm node server3
tmsh save sys config
```

Or restore the UCS saved at the end of part 2 with `./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<file>.ucs`.

To repeat only the failure and the fix, set the virtual server back to no translation:
`tmsh modify ltm virtual vs-web source-address-translation { type none }`.

## Files used

None from `demo/`. Lab scripts: `f5-save.sh`, `f5-restore.sh`.

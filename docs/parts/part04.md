# Part 4: SNAT in depth: AutoMap, SNAT pools and X-Forwarded-For

| | |
|---|---|
| Video | [F5 SNAT Explained: AutoMap, SNAT Pools, X-Forwarded-For (Part 4)](https://youtu.be/CKsyx8h5S0M) (public from 2026-11-14 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-snat-in-depth/) (from 2026-11-14 04:00 UTC) |
| Previous / next | [Part 3](part03.md) / [Part 5](part05.md) |

## Goal

I look at what SNAT AutoMap really does on lb-f5a (the address it picks, the port it keeps, the connection table), replace it with a
SNAT pool, test which SNAT wins when a standalone SNAT list also matches, and give the servers the real client address back with an
X-Forwarded-For HTTP profile. Then I show that a client can forge that header, and close the hole with header-erase.

## Starting state

- The end state of [Part 3](part03.md), on lb-f5a: nodes `server1`, `server2`, `server3`; pool `pool-web` (monitor `http`, Round Robin,
  server1-3:80); virtual server `vs-web` 10.20.30.100:80 with profiles `http` + `tcp` and **source address translation Auto Map**;
  plus part 2's network (`float-internal` 10.20.0.240 in traffic-group-1, `self-internal` 10.20.0.241).
- If you rebuilt the lab: license the units, then restore the UCS saved at the end of part 3 with
  `./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<file>.ucs` (and lb-f5b).
- Unit used: **lb-f5a only**. Web UI `https://172.21.32.43`; bash from the lab server: `ssh admin@clab-f5-clos-dc-lb-f5a`.

## Values used in this part

| Object | Value |
|---|---|
| SNAT pool | `snat-web`: 10.20.0.201, 10.20.0.202 |
| Standalone SNAT (SNAT list, deleted at the end) | `snat-pcs`: translation 10.20.0.210, origin 10.10.0.0/24, all VLANs |
| HTTP profile | `http-xff`: parent `http`, Insert X-Forwarded-For Enabled; later header-erase `X-Forwarded-For` |
| Virtual server | `vs-web`: SNAT pool `snat-web`, HTTP profile `http-xff` at the end |
| Client | pc1 10.10.0.11 (management 172.21.32.111) |
| Forged header value | 203.0.113.66 (documentation range) |

## Steps

### 1. AutoMap, as part 3 left it

On the lab server (root, in the repo folder):

```bash
ssh admin@172.21.32.111 'for i in 1 2 3; do curl -s http://app.f5lab.test/ | grep -E "^(server|client seen)"; done'
for n in 1 2 3; do docker exec clab-f5-clos-dc-server$n tail -40 /var/log/nginx/access.log | grep HTTP/1.1 | tail -2 | sed "s/^/server$n  /"; done
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list net self one-line'
```

You should see three answers from different servers, `client seen: 10.20.0.240` every time (the port changes: each request is a new
connection and the client port is preserved); every access-log line on server1-3 from 10.20.0.240 with X-Forwarded-For `-`; and
`float-internal` 10.20.0.240 in traffic-group-1 on VLAN `internal`, the address AutoMap picked. `self-internal` 10.20.0.241 is the
unit's own address (traffic-group-local-only).

### 2. One connection in the BIG-IP's connection table

Hold a connection open from pc1 with a fixed source port (45010) for 20 seconds, then read lb-f5a's connection table. On the lab
server:

```bash
ssh -n admin@172.21.32.111 '(printf "GET / HTTP/1.1\r\nHost: app.f5lab.test\r\n\r\n"; sleep 20) | nc -p 45010 10.20.30.100 80 >/dev/null' &
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show sys connection cs-client-addr 10.10.0.11 all-properties' | grep -vE '^ *$|Neuron|Ingress|Conn Id|Acceleration|Type|Unit|Bits'
```

You should see one record with both sides. In my run: client side 10.10.0.11:45010 > 10.20.30.100:80; server side
10.20.0.240:45010 > 10.20.0.12:80 (the source port kept); TMM 2; last hop on `external` with MAC 00:00:5e:00:01:01, the fabric's
anycast gateway.

### 3. Create the SNAT pool

In the web UI of lb-f5a: **Local Traffic > Address Translation > SNAT Pool List > Create**: Name `snat-web`; Member List: IP Address
`10.20.0.201`, **Add**; `10.20.0.202`, **Add**; **Finished**.

The same in tmsh:

```bash
tmsh create ltm snatpool snat-web members add { 10.20.0.201 10.20.0.202 }
```

### 4. Put it on the virtual server

**Local Traffic > Virtual Servers > `vs-web`**: Source Address Translation: `SNAT`; SNAT Pool: `snat-web`; **Update**.

The same in tmsh:

```bash
tmsh modify ltm virtual vs-web source-address-translation { type snat pool snat-web }
```

New connections use the pool; connections already open keep the address they started with, so the change is safe on a live virtual
server.

### 5. The SNAT pool at work

On the lab server:

```bash
ssh admin@172.21.32.111 'for i in $(seq 6); do curl -s http://app.f5lab.test/ | grep "^client seen"; done'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm snatpool snat-web; tmsh list ltm snat-translation'
docker exec clab-f5-clos-dc-server1 ip neigh | grep -E '^10.20.0.(201|202|240) '
ssh admin@clab-f5-clos-dc-lb-f5a 'ip link show internal' | grep ether
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show ltm snat-translation field-fmt' | grep -E 'snat-translation|tot-conns'
```

You should see:
- `client seen` 10.20.0.201 or 10.20.0.202, chosen per connection (a mix, not a strict alternation);
- the pool with its two members, and one `snat-translation` object per address that I never created: the BIG-IP made them, with
  `inherited-traffic-group true` and `traffic-group traffic-group-1`, so they move with the active unit;
- on server1, 10.20.0.201, .202 and .240 all on the same MAC, lb-f5a's `internal` MAC (aa:c1:ab:46:d0:c5 in my run);
- total connections per translation address (they include every earlier test: counters count since the object was created).

### 6. A standalone SNAT (SNAT list)

**Local Traffic > Address Translation > SNAT List > Create**. Look at the defaults first: Origin "All IPv4 Addresses", and VLAN / Tunnel
Traffic "All VLANs and Tunnels": left like that, the object would translate everyone, arriving anywhere. Then: Name `snat-pcs`;
Translation: `IP Address`, `10.20.0.210`; Origin: Address List, `10.10.0.0/24`, **Add**; VLAN / Tunnel Traffic: left on all (for this
test only; in a real design, enable it only on the VLAN where that traffic arrives); **Finished**.

### 7. Which SNAT wins

On the lab server:

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm snat snat-pcs; tmsh list ltm virtual vs-web source-address-translation'
ssh admin@172.21.32.111 'curl -s http://app.f5lab.test/' | grep -E '^(server|client seen|x-forwarded-for)'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm virtual vs-web source-address-translation { type none pool none }'
ssh admin@172.21.32.111 'curl -s http://app.f5lab.test/' | grep -E '^(server|client seen|x-forwarded-for)'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm virtual vs-web source-address-translation { type snat pool snat-web }'
ssh admin@172.21.32.111 'curl -s http://app.f5lab.test/' | grep -E '^(server|client seen|x-forwarded-for)'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh delete ltm snat snat-pcs; tmsh list ltm snat-translation one-line'
```

You should see:
- with the virtual server on the SNAT pool: `client seen: 10.20.0.201` (or .202): the virtual server's own setting wins;
- with the virtual server on None: `client seen: 10.20.0.210`: the standalone SNAT fills the gap;
- back on the SNAT pool: .201 or .202 again (.202 in my run);
- after deleting `snat-pcs`, only the translations 10.20.0.201 and 10.20.0.202 remain: deleting the SNAT deleted the translation it
  had created.

### 8. Create the X-Forwarded-For profile

**Local Traffic > Profiles > Services > HTTP > Create**: Name `http-xff`; Parent Profile `http`; Insert X-Forwarded-For: tick its
custom (override) box, then `Enabled`; **Finished**.

The same in tmsh:

```bash
tmsh create ltm profile http http-xff defaults-from http insert-xforwarded-for enabled
```

I never change the built-in `http` profile: a child shows exactly what differs from its parent.

### 9. Put it on the virtual server

**Local Traffic > Virtual Servers > `vs-web`**: HTTP Profile (Client): `http-xff` (was `http`); **Update**. Source address
translation stays on the SNAT pool: X-Forwarded-For works alongside SNAT, it does not replace it.

### 10. The client's address, back

On the lab server:

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm profile http http-xff; tmsh list ltm virtual vs-web profiles'
ssh admin@172.21.32.111 'curl -s http://app.f5lab.test/' | grep -E '^(server|client seen|x-forwarded-for)'
for n in 1 2 3; do docker exec clab-f5-clos-dc-server$n tail -40 /var/log/nginx/access.log | grep HTTP/1.1 | tail -2 | sed "s/^/server$n  /"; done
```

You should see `http-xff` with `defaults-from http` and `insert-xforwarded-for enabled`, and `vs-web` listing `http-xff` and `tcp`;
`client seen` a SNAT pool address and `x-forwarded-for: 10.10.0.11`; the access logs now carry 10.10.0.11 next to the SNAT address.

In pc1's Firefox (`https://172.21.32.111:3001`), `http://app.f5lab.test/` shows the same: in my run server1, `client seen:
10.20.0.201`, `x-forwarded-for: 10.10.0.11`.

### 11. A client can forge the header

On the lab server:

```bash
ssh admin@172.21.32.111 'curl -s -H "X-Forwarded-For: 203.0.113.66" http://app.f5lab.test/' | grep -E '^(client seen|x-forwarded-for)'
```

You should see `x-forwarded-for: 203.0.113.66, 10.10.0.11`: the BIG-IP appended its value to the client's.

The raw request on the wire, captured on all three servers while pc1 sends the forged request once:

```bash
for n in 1 2 3; do docker exec clab-f5-clos-dc-server$n timeout 14 tcpdump -nni bond0 -l -A -s 0 'tcp dst port 80 and src net 10.20.0.200/29 and tcp[13]&8!=0' 2>/dev/null | grep -aiE '^(host|x-forwarded-for):' | sed -u "s/^/server$n  /" & done; sleep 6; ssh -n admin@172.21.32.111 'curl -s -o /dev/null -H "X-Forwarded-For: 203.0.113.66" http://app.f5lab.test/'; wait
```

You should see, on the member that received it (server2 in my run), one `X-Forwarded-For` line: `203.0.113.66, 10.10.0.11`, the
client's value first, the BIG-IP's appended on the right. The lines print when the captures stop.

### 12. Erase, then insert

On the lab server:

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm profile http http-xff header-erase X-Forwarded-For; tmsh list ltm profile http http-xff'
ssh admin@172.21.32.111 'curl -s -H "X-Forwarded-For: 203.0.113.66" http://app.f5lab.test/' | grep -E '^(client seen|x-forwarded-for)'
```

You should see the profile with both `header-erase X-Forwarded-For` and `insert-xforwarded-for enabled`, and the server receive
`x-forwarded-for: 10.10.0.11` only: the erase runs before the insert.

Save the configuration:

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh save sys config'
```

## Verify

- AutoMap: every access-log line on server1-3 showed 10.20.0.240 and X-Forwarded-For `-`; the connection table showed one record,
  10.10.0.11:45010 > 10.20.30.100:80 | 10.20.0.240:45010 > 10.20.0.12:80. In a separate test, pc1 with `curl --local-port 45001`
  arrived at the server as 10.20.0.240:45001 (`source-port preserve`).
- SNAT pool: `client seen` 10.20.0.201 / 10.20.0.202; on server1, .201, .202 and .240 resolve to lb-f5a's internal MAC.
- Precedence: VS SNAT pool > .201/.202; VS None > the SNAT list's .210.
- X-Forwarded-For: 10.10.0.11 inserted; a forged value is appended to (`203.0.113.66, 10.10.0.11`); with header-erase, only
  10.10.0.11 arrives.

## Gotchas

- In tmsh, `source-address-translation { type none }` on a virtual server that uses a SNAT pool needs `pool none` as well: a
  translation of type none cannot keep a pool attached.
- The SNAT List form defaults to origin "All IPv4 Addresses" and "All VLANs and Tunnels": a standalone SNAT left on the defaults
  translates everything.
- A standalone SNAT applies to a virtual server's traffic only when the virtual server's own source address translation is None.
- Deleting a SNAT or a SNAT pool removes the snat-translation objects it created automatically.
- The SNAT pool picks an address per connection; it does not strictly alternate.
- X-Forwarded-For insert appends to a header the client already sent. Erase it at the edge (`header-erase X-Forwarded-For`), then
  insert; the erase runs first.
- The HTTP monitor's checks come from the self IP 10.20.0.241, not from the SNAT addresses.
- In the HTTP profile form, ticking the custom box for Insert X-Forwarded-For swaps in the selectable field; the parent's value stays
  greyed out until you tick it.

## End state

On lb-f5a (lb-f5b unchanged from part 2):
- nodes `server1`, `server2`, `server3`; pool `pool-web` (monitor `http`, Round Robin, server1-3:80);
- SNAT pool `snat-web` (10.20.0.201, 10.20.0.202), with its two snat-translation objects in traffic-group-1;
- HTTP profile `http-xff` (parent `http`, `insert-xforwarded-for enabled`, `header-erase X-Forwarded-For`);
- virtual server `vs-web` 10.20.30.100:80, profiles `http-xff` + `tcp`, default pool `pool-web`, source address translation SNAT pool
  `snat-web`;
- no standalone SNAT (`snat-pcs` deleted).

Save a UCS of both units (on the lab server, in the repo folder):

```bash
./f5-save.sh
```

Remember to revoke both licences before `./down.sh` (then `./down.sh --licences-revoked`).

## Reset

Back to the end state of part 3, on lb-f5a (bash as admin). The safest way is the UCS saved at the end of part 3:
`./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<file>.ucs` on the lab server. With tmsh, in dependency order:

```bash
tmsh modify ltm virtual vs-web source-address-translation { type automap pool none }
tmsh modify ltm virtual vs-web profiles replace-all-with { http tcp }
tmsh delete ltm profile http http-xff
tmsh delete ltm snatpool snat-web
tmsh save sys config
```

If you stopped between steps 6 and 7, delete the standalone SNAT too: `tmsh delete ltm snat snat-pcs`.

## Files used

None from `demo/`. Lab scripts: `f5-save.sh`, `f5-restore.sh`.

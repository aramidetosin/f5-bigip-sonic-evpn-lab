# Part 5: Load-balancing methods, measured

| | |
|---|---|
| Video | [F5 Load Balancing Methods Measured: Round Robin vs Least Connections (Part 5)](https://youtu.be/Yz-Yn1jOLUk) (public from 2026-11-17 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-load-balancing-methods/) (from 2026-11-17 04:00 UTC) |
| Previous / next | [Part 4](part04.md) / [Part 6](part06.md) |

## Goal

I change the load-balancing method of `pool-web` and count, on the BIG-IP itself, where every new connection went. Round robin and
Ratio (member) are static: they follow the configuration. Then I slow one server down on purpose and compare round robin, Least
Connections (member) and Fastest (application) on the same burst of long downloads. The point: a static method keeps sending a slow
server its share; a dynamic method reacts, but only to what the BIG-IP can measure.

## Starting state

- The lab is up and `./validate.sh` passes.
- lb-f5a only. The objects from parts 2-4 exist on it:
  - nodes `server1` (10.20.0.11), `server2` (10.20.0.12), `server3` (10.20.0.13);
  - pool `pool-web`: members server1:80, server2:80, server3:80, monitor `http`, load-balancing mode round robin, every ratio 1;
  - virtual server `vs-web` 10.20.30.100:80: profiles `tcp` and `http-xff` (parent http, X-Forwarded-For inserted, a client's own
    X-Forwarded-For header erased first), source address translation = SNAT pool `snat-web` (10.20.0.201, 10.20.0.202), pool `pool-web`;
  - the standalone SNAT `snat-pcs` from part 4 is deleted.
- To get there: follow [Part 2](part02.md), [Part 3](part03.md) and [Part 4](part04.md), or restore the UCS you saved at the end of
  part 4 with `./f5-restore.sh lb-f5a <file.ucs>` (the archives are in `/root/f5-clos-dc-secrets/ucs/`).

## Values used in this part

| Object | Value |
|---|---|
| BIG-IP | lb-f5a, web UI `https://172.21.32.43` (user admin; password: `sudo sed -n 's/^PASSWORD=//p' /root/f5-clos-dc-secrets/lb-f5a.env`) |
| Pool | `pool-web`: server1:80, server2:80, server3:80 |
| VIP | `vs-web` 10.20.30.100:80, name `app.f5lab.test` on the PCs |
| Client | pc1, 10.10.0.11 (management 172.21.32.111) |
| Ratio weights | server1 3, server2 2, server3 1 |
| Slow server | server3: `tc netem delay 100ms` on its `bond0` |
| Large object | `http://app.f5lab.test/static/large.bin`, 4 MiB (served by every server) |
| Burst | 30 downloads of large.bin from pc1, one every 0.25 s |
| Methods tried | round-robin, ratio-member, least-connections-member, fastest-app-response |

Every server answers with the header `X-Server: <hostname>`, so a client can see which member answered.

## Steps

All commands run on the lab server (root, in the repo folder) unless a step says otherwise. The lab server reaches lb-f5a and the PCs
by SSH as admin without a password.

### 1. Round robin, counted

Check the method and a ratio, reset the pool's statistics, send 99 requests from pc1 (each curl is a new TCP connection), then count
the server-side connections per member.

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm pool pool-web load-balancing-mode members { server1:http { ratio } }' | grep -E 'mode|ratio'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh reset-stats ltm pool pool-web'
ssh admin@172.21.32.111 'ok=0; for i in $(seq 99); do [ $(curl -s -o /dev/null -w %{http_code} http://app.f5lab.test/) = 200 ] && ok=$((ok+1)); done; echo "99 requests, $ok answered"'
./demo/pool-count.sh
```

You should see `load-balancing-mode round-robin`, `ratio 1`, `99 requests, 99 answered`, and a total of 33 on each member.

### 2. Ratio (member), in the web UI

In the web UI of lb-f5a (https://172.21.32.43):

1. Local Traffic > Pools > `pool-web` > Members tab.
2. Load Balancing Method: **Ratio (member)** > Update.
3. In the Current Members list, click `server1:80`: Ratio **3** > Update. Back on the Members tab, `server2:80`: Ratio **2** > Update.
   Then `server3:80`: Ratio **1** > Update.

Check it and count 120 requests:

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm pool pool-web all-properties' | grep -E 'load-balancing-mode|:http [{]|  ratio'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh reset-stats ltm pool pool-web'
ssh admin@172.21.32.111 'ok=0; for i in $(seq 120); do [ $(curl -s -o /dev/null -w %{http_code} http://app.f5lab.test/) = 200 ] && ok=$((ok+1)); done; echo "120 requests, $ok answered"'
./demo/pool-count.sh
```

You should see `load-balancing-mode ratio-member` and ratios 3 / 2 / 1. In the run in the video: 62 / 39 / 19 (other runs 60 / 40 / 20 and
57 / 41 / 22). Close to 3:2:1, not exact.

### 3. Slow one server down

`./demo/slow.sh` adds a network delay to one server's `bond0` with tc netem. Then I time one 4 MiB download per request from pc1.

```bash
./demo/slow.sh server3 100ms
ssh admin@172.21.32.111 'for i in 1 2 3 4 5 6; do curl -s -o /dev/null -w "%header{x-server}  %{size_download} bytes in %{time_total} s\n" http://app.f5lab.test/static/large.bin; done'
```

You should see the netem qdisc on bond0, then six lines of `4194304 bytes in ... s`. In my run: about 7.0-7.2 s from server3 and
0.4-0.7 s from server1 and server2. Server3 is slow, not down: its monitor stays green.

### 4. Round robin with a slow server

Back to round robin (the ratios no longer matter in this mode). Then the burst: 30 downloads from pc1, one every 0.25 s, while
`./demo/pool-watch.sh` prints the open server-side connections per member once a second.

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm pool pool-web load-balancing-mode round-robin; tmsh list ltm pool pool-web load-balancing-mode' | grep mode
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh reset-stats ltm pool pool-web'; (./demo/burst.sh 30 0.25 &); ./demo/pool-watch.sh 13
./demo/pool-count.sh
```

In my run: server3's open connections climbed to 9 while server1 and server2 stayed low; totals 11 / 10 / 9 (server3 peak open 9).
Round robin still gave the slow server its third of the new connections.

### 5. Least Connections (member), in the web UI

In the web UI of lb-f5a: Local Traffic > Pools > `pool-web` > Members tab > Load Balancing Method: **Least Connections (member)** >
Update.

The same burst:

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm pool pool-web load-balancing-mode' | grep mode
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh reset-stats ltm pool pool-web'; (./demo/burst.sh 30 0.25 &); ./demo/pool-watch.sh 13
./demo/pool-count.sh
```

You should see `load-balancing-mode least-connections-member`. In my run: totals 13 / 10 / 7, server3 peak open 7. The BIG-IP saw
server3's connections stay open and sent it fewer new ones.

### 6. Fastest (application)

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm pool pool-web load-balancing-mode fastest-app-response; tmsh list ltm pool pool-web load-balancing-mode' | grep mode
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh reset-stats ltm pool pool-web'; ./demo/burst.sh 30 0.25; ./demo/pool-count.sh
```

In my run: 12 / 11 / 7. In dry runs (not in the video) Observed (member) gave 11 / 10 / 9 and Predictive (member) 10 / 10 / 10: these
two turn connection counts over time into a ratio, and showed no shift within one 7.5 s burst.

### 7. Clean up

Server3 back to full speed, `pool-web` back to round robin with every ratio 1, configuration saved.

```bash
./demo/slow.sh server3 off
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm pool pool-web load-balancing-mode round-robin members modify { server1:http { ratio 1 } server2:http { ratio 1 } server3:http { ratio 1 } }; tmsh save sys config' | tail -1
```

## Verify

- Round robin, 99 new connections from one client: 33 / 33 / 33.
- Ratio 3:2:1, 120 connections: 62 / 39 / 19 (60 / 40 / 20 and 57 / 41 / 22 in other runs).
- server3 with 100 ms netem: a 4 MiB download takes about 7 s, against 0.4-0.7 s from the others.
- Burst of 30 long downloads, server3 slow:

| Method | server1 / server2 / server3 | server3 peak open |
|---|---|---|
| round-robin | 11 / 10 / 9 | 9 |
| least-connections-member | 13 / 10 / 7 | 7 |
| fastest-app-response | 12 / 11 / 7 | (not shown) |

- `./demo/pool-count.sh` reads `serverside.tot-conns` and `serverside.max-conns` per member from
  `tmsh show ltm pool pool-web members field-fmt`; `./demo/pool-watch.sh` reads `serverside.cur-conns`.

## Gotchas

- A short run of requests on one server is not a broken round robin: each TMM keeps its own round-robin pointer (4 TMMs on lb-f5a),
  so the order seen from one client is not strictly 1, 2, 3. Count many connections, after `tmsh reset-stats`.
- Ratio is not exact over 120 connections (62 / 39 / 19, not 60 / 40 / 20), for the same per-TMM reason.
- The BIG-IP balances connections, not requests. A browser that keeps one TCP connection open stays on one member. curl in a loop
  opens a new connection per request, which is why the counts above match the request counts.
- A slow server is not a down server. The monitor still marks server3 up, so static methods keep sending it its share.
- Least connections counts only the connections this BIG-IP has open to the member (member flavour: only inside this pool). The
  node flavour counts the server across every pool it is in.
- Observed and predictive did not move within a 7.5 s burst in my dry runs (10-11 per member). Do not expect them to react to a short
  spike.
- The mode descriptions I rely on come from the box itself: `tmsh help ltm pool` on lb-f5a (it also gives slow-ramp-time's default,
  10 s).

## End state

- `pool-web`: round robin, every ratio 1, monitor `http`, server1-3:80.
- server3 at full speed (no netem qdisc on bond0).
- Everything else unchanged from part 4 (`vs-web` with SNAT pool `snat-web` and `http-xff`). Configuration saved.

Save it for part 6:

```bash
./f5-save.sh lb-f5a
```

## Reset

To go back to this part's starting state from anywhere in it:

```bash
./demo/slow.sh server3 off
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm pool pool-web load-balancing-mode round-robin members modify { server1:http { ratio 1 } server2:http { ratio 1 } server3:http { ratio 1 } }; tmsh save sys config'
```

Or restore the UCS saved at the end of part 4 with `./f5-restore.sh lb-f5a <file.ucs>`.

## Files used

- `demo/pool-count.sh`: total and peak server-side connections per member of a pool on lb-f5a, since the last reset-stats.
- `demo/pool-watch.sh`: open server-side connections per member, once a second.
- `demo/burst.sh`: from pc1, N downloads of a path (default `/static/large.bin`), one every G seconds, each in the background.
- `demo/slow.sh`: add or remove a tc netem delay on one server's bond0.

# Part 11: Troubleshooting with tcpdump, from the BIG-IP to the fabric

| | |
|---|---|
| Video | [F5 Troubleshooting with tcpdump on a SONiC Fabric (Part 11)](https://youtu.be/qHPF4bKL31I) (public from 2026-12-01 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-troubleshooting-tcpdump/) (from 2026-12-01 04:00 UTC) |
| Previous / next | [Part 10](part10.md) / [Part 12](part12.md) |

## Goal
I capture one request on the BIG-IP and read both sides of the full proxy in one capture, with the F5 trailer that links them.
Then I re-create part 3's failure (SNAT off on vs-web) and follow the server's answer packet by packet: on the BIG-IP, on the server
leaves, on the service leaf and on the firewall, until I find where it stops. I finish with a capture file, reset causes and a
packet filter that drops packets tcpdump still shows.

## Starting state
- The lab is up and `./validate.sh` passes.
- lb-f5a carries the end state of [Part 10](part10.md): vs-web 10.20.30.100:80 (tcp, http-xff, oneconnect, reqlog-web, SNAT pool
  snat-web, persist-cookie, pool-web with priority groups 10 / 10 / 5 / 1), snat-web 10.20.0.201, 10.20.0.202, 10.20.30.201,
  vs-web-https from part 8, and part 10's logging objects (remotesyslog1, logsrv-trap, pool-hsl, hsl-pub, ltm-to-hsl).
- Used: lb-f5a, pc1 and pc2, leaf1a-service (172.21.32.21), leaf2a-server (172.21.32.23), leaf2b-server (172.21.32.24) and fw-pa
  (172.21.32.40). lb-f5b is not touched.
- To get there: the guides of parts 2 to 10, or restore the UCS saved at the end of part 10 with `./f5-restore.sh lb-f5a <file.ucs>`.

## Values used in this part
| Object | Value |
|---|---|
| Client | pc1 10.10.0.11 (mgmt 172.21.32.111); pc2 10.10.0.12 (mgmt 172.21.32.112) for the packet filter test |
| VIP | vs-web 10.20.30.100:80 (app.f5lab.test) |
| Capture filter on the BIG-IP | `host 10.10.0.11 and tcp port 80` |
| BIG-IP interfaces | `0.0` (every VLAN TMM handles), `0.0:nnnp` (full F5 trailer plus the peer flow) |
| Failure | vs-web `source-address-translation { type none pool none }` (restored to `type snat pool snat-web`) |
| Capture file | /var/tmp/part11.pcap on lb-f5a |
| Reset-cause db variables | tm.rstcause.pkt, tm.rstcause.log (enabled for one test, disabled again) |
| Packet filter | block-pc1-ping: order 10, action discard, logging enabled, rule `( proto ICMP ) and ( src host 10.10.0.11 )` (removed again) |

## Steps
All commands run on the lab server (root, in the repo folder). They reach every node over SSH as admin. Shortcuts used below:

```bash
LBA=admin@clab-f5-clos-dc-lb-f5a
PC1=admin@172.21.32.111
```

Each capture is started first, and one request from pc1 is sent a few seconds later in the background (the `( sleep ...; ... ) &`
part). `demo/f5trim.sh` only shortens the BIG-IP's tcpdump lines for reading: it drops TCP options, seq/ack/win and some trailer
fields, and keeps addresses, flags, length, direction, TMM, listener, port, flowid and peerid.

### 1. tcpdump on 0.0: the client side
```bash
(sleep 6; ssh -n $PC1 'curl -s -m 5 -o /dev/null http://app.f5lab.test/demo') & ssh $LBA "timeout 12 tcpdump -nni 0.0 -l 'host 10.10.0.11 and tcp port 80' 2>/dev/null" | ./demo/f5trim.sh
```

You should see the client side only: 10.10.0.11 to 10.20.30.100. Plain `-i 0.0` already prints a short F5 trailer on every line:
in/out, slot1/tmmN, lis= (the virtual server), port= (the interface), trunk=.

### 2. tcpdump on 0.0:nnnp: both sides of the proxy
`:nnn` adds the full F5 trailer. `p` also captures the PEER flow, so filtering on the client's address also shows the server-side
packets of the same connection.

```bash
(sleep 6; ssh -n $PC1 'curl -s -m 5 -o /dev/null http://app.f5lab.test/demo') & ssh $LBA "timeout 12 tcpdump -nni 0.0:nnnp -l 'host 10.10.0.11 and tcp port 80' 2>/dev/null" | ./demo/f5trim.sh
```

You should see the client side and the server side, 10.20.0.201 (SNAT) to a server, in one capture. The client-side flowid and the
server-side flowid point at each other through peerid. The very first client SYN has `lis=` empty: the listener has not matched yet.
With OneConnect on vs-web, a request can ride an existing server-side connection, so there may be no server-side SYN at all.

### 3. Part 3's failure, seen by the BIG-IP
I turn SNAT off on vs-web. In tmsh `type none` alone is refused while a pool is set (01071753:3), so `pool none` goes with it.

```bash
ssh $LBA 'tmsh modify ltm virtual vs-web source-address-translation { type none pool none }'
(sleep 4; ssh -n $PC1 'curl -s -m 8 -o /dev/null http://app.f5lab.test/demo') & ssh $LBA "timeout 18 tcpdump -nni 0.0:nnnp -l 'host 10.10.0.11 and tcp port 80' 2>/dev/null" | ./demo/f5trim.sh
```

You should see the client side complete (SYN, SYN-ACK, ACK, GET), then the server-side SYN from 10.10.0.11 (no SNAT now) to the
server, repeated and never answered, then a reset (R) to both sides. In one run the server-side SYN to server2 repeated at
1 s intervals and the reset came at +4 s; in a run right after, for server1 and server2, the SYN repeated at 0 / +3 / +6 / +9 s and
the reset came at +12 s (tcp profile: syn-rto-base 3000, syn-max-retrans 3, minimum-rto 1000). I did not establish why the first run
used 1 s.

### 4. Into the fabric: the server leaves and the service leaf
SONiC VS forwards in the Linux kernel, so `tcpdump -i any` on a leaf sees transit packets on each layer. I capture on three leaves
at once (still with SNAT off): the server pair leaf2a/leaf2b and leaf1a-service. The `grep` keeps only the lines on the tunnel,
port-channel and firewall transit interfaces; `sed` prefixes each line with the leaf name.

```bash
ssh admin@172.21.32.23 "sudo timeout 14 tcpdump -nni any -l 'tcp port 80 and host 10.10.0.11' 2>/dev/null" | grep --line-buffered -E ' (vtep1-[0-9]+|PortChannel[0-9]+|Vlan3002) ' | sed -u 's/^/leaf2a /' & \
ssh admin@172.21.32.24 "sudo timeout 14 tcpdump -nni any -l 'tcp port 80 and host 10.10.0.11' 2>/dev/null" | grep --line-buffered -E ' (vtep1-[0-9]+|PortChannel[0-9]+|Vlan3002) ' | sed -u 's/^/leaf2b /' & \
ssh admin@172.21.32.21 "sudo timeout 14 tcpdump -nni any -l 'tcp port 80 and src net 10.20.0.0/24 and dst host 10.10.0.11' 2>/dev/null" | grep --line-buffered -E ' (vtep1-[0-9]+|PortChannel[0-9]+|Vlan3002) ' | sed -u 's/^/leaf1a /' & \
sleep 4; ssh -n $PC1 'curl -s -m 8 -o /dev/null http://app.f5lab.test/demo'; wait
```

You should see (my run, the request went to server2):
- leaf2a: the SYN in on vtep1-120 (the L2 VNI of VLAN 120), out PortChannel22 to server2.
- leaf2b: server2's SYN-ACK in on PortChannel22, routed out vtep1-1502 (the Vrf-App L3 VNI). The SYN entered one leaf and the
  SYN-ACK left through the other: ESI LAG hashing.
- leaf1a-service: that SYN-ACK in on vtep1-1502, out Vlan3002 (the firewall transit, fw-transit-app) on PortChannel10, which is the
  firewall.
- The SYN repeats every 3 s.

The server answers. The answer goes to the client's address, 10.10.0.11, so the fabric routes it to the firewall, not to the BIG-IP.

### 5. The firewall drops it
On fw-pa the counter for TCP packets without a session is read before and after one request (still with SNAT off).

```bash
ssh admin@172.21.32.40
```

On fw-pa (PAN-OS CLI):

```bash
set cli pager off
show counter global | match non_syn
exit
```

On the lab server:

```bash
ssh $PC1 'curl -s -m 8 -o /dev/null -w "HTTP %{http_code} after %{time_total} s\n" http://app.f5lab.test/demo'
```

Then the same counter on fw-pa again. You should see `HTTP 000 after 4.01 s`, and `flow_tcp_non_syn_drop` go from 179 to 187. The
firewall never saw the SYN (the BIG-IP sent it straight to the server), so the SYN-ACK is a non-SYN packet without a session.

### 6. SNAT back on
```bash
ssh $LBA 'tmsh modify ltm virtual vs-web source-address-translation { type snat pool snat-web }'
(sleep 6; ssh -n $PC1 'curl -s -m 5 -o /dev/null http://app.f5lab.test/demo') & ssh $LBA "timeout 12 tcpdump -nni 0.0:nnnp -l 'host 10.10.0.11 and tcp port 80' 2>/dev/null" | ./demo/f5trim.sh
```

You should see the server side from 10.20.0.201 complete, and 200 OK to the client.

### 7. Reset causes
Two db variables make the BIG-IP write the reason for a reset into the RST packet and into /var/log/ltm. Both are disabled by
default. I enable them, turn SNAT off for one request, capture only resets, then restore everything.

```bash
ssh $LBA 'tmsh modify sys db tm.rstcause.pkt value enable; tmsh modify sys db tm.rstcause.log value enable'; ssh $LBA 'tmsh modify ltm virtual vs-web source-address-translation { type none pool none }'
(sleep 3; ssh -n $PC1 'curl -s -m 14 -o /dev/null http://app.f5lab.test/demo') & ssh $LBA "timeout 17 tcpdump -nni 0.0 -A -l 'host 10.10.0.11 and tcp port 80 and tcp[13] & 4 != 0' 2>/dev/null" | grep -aoE '^[0-9:.]+ IP [^:]+: Flags \[R.\]|BIG-IP: [^.]+'
ssh $LBA 'grep 01230140 /var/log/ltm | tail -n 2'
ssh $LBA 'tmsh modify ltm virtual vs-web source-address-translation { type snat pool snat-web }'; ssh $LBA 'tmsh modify sys db tm.rstcause.pkt value disable; tmsh modify sys db tm.rstcause.log value disable'
```

You should see "TCP retransmit timeout" and "{peer} TCP retransmit timeout" in the RST payloads, and the same reasons in
/var/log/ltm with message ID 01230140:3.

### 8. A capture file for Wireshark
```bash
(sleep 3; ssh -n $PC1 'curl -s -m 5 -o /dev/null http://app.f5lab.test/demo') & ssh $LBA "timeout 8 tcpdump -nni 0.0:nnnp -s0 -w /var/tmp/part11.pcap 'host 10.10.0.11 and tcp port 80'"
ssh $LBA 'ls -l /var/tmp/part11.pcap; tcpdump -nr /var/tmp/part11.pcap 2>/dev/null | wc -l'
scp -q $LBA:/var/tmp/part11.pcap /tmp/ && ls -l /tmp/part11.pcap
```

You should see a file of 5,302 bytes with 18 packets, copied to /tmp on the lab server. Opened in Wireshark, the `:nnnp` capture
carries the F5 trailer.

### 9. A packet filter: dropped, but still in tcpdump
```bash
ssh $LBA 'tmsh modify sys db packetfilter value enable; tmsh create net packet-filter block-pc1-ping order 10 action discard logging enabled rule "( proto ICMP ) and ( src host 10.10.0.11 )"; tmsh list net packet-filter'
(sleep 3; ssh -n $PC1 'ping -c 3 -W 1 10.20.30.100 | tail -2'; ssh -n admin@172.21.32.112 'ping -c 2 -W 1 10.20.30.100 | tail -2') & ssh $LBA "timeout 10 tcpdump -nni 0.0 -l 'icmp and host 10.20.30.100' 2>/dev/null"
ssh $LBA 'tail -n 3 /var/log/pktfilter'
ssh $LBA 'tmsh show net packet-filter block-pc1-ping' | grep -i hits
ssh $LBA 'tmsh delete net packet-filter block-pc1-ping; tmsh modify sys db packetfilter value disable; tmsh list net packet-filter; tmsh list sys db packetfilter'
```

You should see:
- pc1: 3 echo requests visible in tcpdump, and 100% packet loss. pc2: 2 of 2 answered.
- /var/log/pktfilter: three lines like `01250003:5: /Common/block-pc1-ping (2): discard on /Common/external, len: 98 [IPv4 84
  10.10.0.11 -> 10.20.30.100 ICMP 8:0]`.
- Matched Hits 3.
- After the delete: no packet filter, db packetfilter disable.

tcpdump on the BIG-IP captures before the packet filter acts, so a packet in the capture is not proof that the BIG-IP accepted it.

### 10. Check the end state and save
```bash
ssh $LBA 'tmsh list ltm virtual vs-web' | grep -A3 source-address
ssh -n $PC1 'curl -s http://app.f5lab.test/' | grep -E '^(server|client seen):'
ssh $LBA 'tmsh save sys config' | tail -1
```

You should see vs-web's source-address-translation back on SNAT pool snat-web, and a request answered (server2, client seen 10.20.0.201
in my run).

## Verify
- `0.0:nnnp` shows both sides of one request, linked by flowid and peerid.
- With SNAT off: the client side completes, the server-side SYN is retransmitted and never answered, the BIG-IP resets both sides.
- In the fabric: server2's SYN-ACK goes leaf2b > vtep1-1502 > leaf1a-service > Vlan3002 / PortChannel10, to the firewall.
- On fw-pa: `flow_tcp_non_syn_drop` 179 > 187 for one request; the client gets HTTP 000 after 4.01 s.
- With SNAT on: the server side from 10.20.0.201 completes and the client gets 200 OK.
- Packet filter: 100% loss for pc1, pc2 answered, Matched Hits 3, while tcpdump still showed pc1's echo requests.

## Gotchas
- With OneConnect on vs-web, a request can reuse an idle server-side connection: no server-side SYN in the capture is not a fault.
- `type none` alone is refused while the virtual server has a SNAT pool set (01071753:3): use `type none pool none`.
- The SYN retransmit timing differed between runs (1 s in one, 3 s with the reset at +12 s in another). Read the timing from the
  capture, not from memory.
- The leaf clocks differ by about 1.2 s (leaf2a against leaf2b). Compare the sequence of packets across devices, not their
  timestamps.
- SONiC VS forwards in the kernel, so tcpdump on a leaf sees transit traffic. On hardware SONiC the ASIC forwards and only packets
  sent to the CPU reach tcpdump: use a mirror session there.
- With ESI LAG the SYN and the SYN-ACK of one connection can use different leaves (leaf2a in, leaf2b out). Capture on both leaves
  of a pair.
- tcpdump on the BIG-IP sees packets before the packet filter. A packet in the capture can still be discarded.
- tcpdump on the BIG-IP also has `--f5 <provider>` and the db variable tcpdump.sslprovider (disable) for TLS key material; I did not
  use them here.

## End state
lb-f5a is the same as at the start of this part: vs-web with SNAT pool snat-web, no packet filter, db packetfilter disable,
tm.rstcause.pkt and tm.rstcause.log disabled. The capture file /var/tmp/part11.pcap stays on lb-f5a and a copy in /tmp on the lab
server. Configuration saved.

```bash
./f5-save.sh lb-f5a
```

## Reset
Every change in this part is undone inside the part. If a step was interrupted, these put the starting state back (in tmsh on
lb-f5a):

```bash
tmsh modify ltm virtual vs-web source-address-translation { type snat pool snat-web }
tmsh modify sys db tm.rstcause.pkt value disable
tmsh modify sys db tm.rstcause.log value disable
tmsh delete net packet-filter block-pc1-ping
tmsh modify sys db packetfilter value disable
tmsh save sys config
```

The capture file can be removed on lb-f5a (bash) with `rm -f /var/tmp/part11.pcap`. Or restore the UCS saved at the end of part 10.

## Files used
- `demo/f5trim.sh`: shortens BIG-IP tcpdump lines for reading (keeps addresses, flags, length, direction, TMM, listener, port,
  flowid, peerid).

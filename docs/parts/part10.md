# Part 10: Remote logging and SNMP

| | |
|---|---|
| Video | [F5 Remote Logging and SNMP Traps (Part 10)](https://youtu.be/UdWAnxUOZ1A) (public from 2026-11-28 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-remote-logging-snmp/) (from 2026-11-28 04:00 UTC) |
| Previous / next | [Part 9](part09.md) / [Part 11](part11.md) |

## Goal
I make lb-f5a tell a log server what happens to it: remote syslog, SNMP traps, SNMP polling, high-speed request logging from TMM,
and high-speed logging for the system's own messages. Each step is proven with the same event: server3's nginx stops and starts,
and I check where the down and up messages arrive. The last step shows a publisher setting that silently stops the local log and
the SNMP traps.

## Starting state
- The lab is up and `./validate.sh` passes. The log-server (10.20.0.20, internal VLAN) runs rsyslog on UDP/TCP 514, writing one file
  per sender under /var/log/remote/, and snmptrapd on UDP 162, writing /var/log/snmptraps.log.
- lb-f5a carries the end state of [Part 9](part09.md): vs-web (tcp, http-xff with fallback-host, oneconnect, SNAT snat-web,
  persist-cookie, pool-web with priority groups 10 / 10 / 5 / 1 and min-active-members 2), snat-web with 10.20.0.201, 10.20.0.202,
  10.20.30.201, node sorry-server, vs-web-https from part 8.
- Nothing is sent off the box yet: `sys syslog remote-servers none`, SNMP traps none, SNMP allowed-addresses 127.0.0.0/8,
  self-internal 10.20.0.241 with allow-service none. The BIG-IP reaches 10.20.0.20 through the internal VLAN, source 10.20.0.241.
- Only lb-f5a is used. lb-f5b is not touched.
- To get there: the guides of parts 2 to 9, or restore the UCS saved at the end of part 9 with `./f5-restore.sh lb-f5a <file.ucs>`.
  `./demo/part10-reset.sh` also removes every object this part creates (see Reset).

## Values used in this part
| Object | Value |
|---|---|
| Log server | log-server 10.20.0.20 (container clab-f5-clos-dc-log-server, mgmt 172.21.32.104) |
| Remote syslog | 10.20.0.20, port 514 (the web UI names the entry `remotesyslog1`) |
| Remote log file on the log server | /var/log/remote/10.20.0.241.log |
| SNMP trap destination | logsrv-trap: host 10.20.0.20, community `public`, version 2c, port 162 |
| SNMP allowed addresses | 127.0.0.0/8 + 10.20.0.0/24 |
| Port lockdown on self-internal | udp:161 |
| HSL pool | pool-hsl: 10.20.0.20:514, monitor gateway_icmp |
| Request-log profile | reqlog-web on vs-web (response logging, pool-hsl, mds-udp) |
| HSL objects | destination hsl-dest (remote-high-speed-log, udp), destination hsl-syslog (remote-syslog, rfc5424), publisher hsl-pub, filter ltm-to-hsl (level notice, source mcpd) |

`public` is the SNMP community already configured on the BIG-IP before this part. On any network other than an isolated lab, use
your own community, or SNMPv3.

## Steps
All commands run on the lab server (root, in the repo folder) unless a step says otherwise. Shortcuts used below:

```bash
LBA=admin@clab-f5-clos-dc-lb-f5a
LSX="docker exec clab-f5-clos-dc-log-server"
REM=/var/log/remote/10.20.0.241.log
```

The test event in every step is server3 going down and up:

```bash
docker exec clab-f5-clos-dc-server3 nginx -s stop    # down; the monitor marks the member down within about 20 s
docker exec clab-f5-clos-dc-server3 nginx            # up again
```

### 1. Before: everything stays on the box
```bash
ssh $LBA 'tmsh list sys syslog remote-servers; tmsh list sys snmp traps'
ssh $LBA 'ls /var/log' | column -c 140 | head -8
docker exec clab-f5-clos-dc-server3 nginx -s stop; sleep 20; ssh $LBA 'tail -n 3 /var/log/ltm'
docker exec clab-f5-clos-dc-server3 nginx; sleep 8; ssh $LBA 'tail -n 2 /var/log/ltm'
$LSX wc -l $REM
```

You should see `remote-servers none` and `traps none`. /var/log/ltm gets the member down line and then the up line:
`01070638:5: Pool /Common/pool-web member /Common/server3:80 monitor status down ...` and `01070727:5: ... monitor status up`.
Nothing reaches the log server.

### 2. Remote syslog in the web UI
In the web UI of lb-f5a (https://172.21.32.43): System > Logs > Configuration > Remote Logging: Remote IP 10.20.0.20; Remote Port
514 (the default); Add; Update.

The same in tmsh (the UI names the entry `remotesyslog1`):

```bash
ssh $LBA 'tmsh modify sys syslog remote-servers add { remotesyslog1 { host 10.20.0.20 remote-port 514 } }'
```

### 3. What arrives on the log server
```bash
ssh $LBA 'tmsh list sys syslog remote-servers'
$LSX tail -n 4 $REM
docker exec clab-f5-clos-dc-server3 nginx -s stop; sleep 20; $LSX grep server3 $REM | tail -n 2
docker exec clab-f5-clos-dc-server3 nginx; sleep 8; $LSX grep server3:80 $REM | tail -n 1
$LSX sh -c "cut -d' ' -f4 $REM | cut -d[ -f1 | sort | uniq -c | sort -rn | head -10"
```

You should see remotesyslog1 with host 10.20.0.20, and lines arriving at once from 10.20.0.241 over UDP. syslog-ng sends
everything, not only LTM: after a few minutes my count per program was logger 30 (the web UI's HTTPS access log), systemd 13,
mcpd 10, tmsh 3, syslog-ng 3, audit_forwarder 1, CROND 1. The member down and up lines are the same text as in /var/log/ltm.

### 4. SNMP traps
In tmsh on lb-f5a (`ssh -t $LBA tmsh`):

```bash
modify sys snmp traps add { logsrv-trap { host 10.20.0.20 community public version 2c port 162 } }
list sys snmp traps
quit
```

Then the test event, and the trap log on the log server:

```bash
docker exec clab-f5-clos-dc-server3 nginx -s stop; sleep 20
$LSX cat /var/log/snmptraps.log | tr "\t" "\n" | grep -E "^20|snmpTrapOID|STRING: Pool" | tail -n 6
docker exec clab-f5-clos-dc-server3 nginx; sleep 8
$LSX cat /var/log/snmptraps.log | tr "\t" "\n" | grep -E "^20|snmpTrapOID|STRING: Pool" | tail -n 3
```

You should see traps from 10.20.0.241 with numeric OIDs: `enterprises.3375.2.4.0.10` for down and `enterprises.3375.2.4.0.11` for
up, with the same message text as the log line.

### 5. The F5 MIBs on the log server
`demo/f5-mibs.sh` copies the BIG-IP's own MIB files (F5-BIGIP-COMMON, SYSTEM and LOCAL) into the log server and restarts snmptrapd.
The files are F5's: they are copied from the box at run time.

```bash
./demo/f5-mibs.sh
docker exec clab-f5-clos-dc-server3 nginx -s stop; sleep 20
$LSX cat /var/log/snmptraps.log | tr "\t" "\n" | grep -E "^20|snmpTrapOID|STRING: Pool" | tail -n 6
docker exec clab-f5-clos-dc-server3 nginx
```

You should see `F5 MIBs loaded on clab-f5-clos-dc-log-server`, then the same trap with names: bigipServiceDown (and
bigipServiceUp), varbinds bigipNotifyObjMsg (the log line's text), bigipNotifyObjNode (/Common/server3), bigipNotifyObjPort (80).

### 6. SNMP polling: two settings, both needed
```bash
ssh $LBA 'tmsh list sys snmp allowed-addresses; tmsh list net self self-internal allow-service'
$LSX snmpget -v2c -c public -t 2 -r 0 10.20.0.241 SNMPv2-MIB::sysName.0 SNMPv2-MIB::sysDescr.0
ssh $LBA 'tmsh modify sys snmp allowed-addresses add { 10.20.0.0/24 }'; $LSX snmpget -v2c -c public -t 2 -r 0 10.20.0.241 SNMPv2-MIB::sysName.0 SNMPv2-MIB::sysDescr.0
ssh $LBA 'tmsh modify net self self-internal allow-service replace-all-with { udp:161 }'; $LSX snmpget -v2c -c public -t 2 -r 0 10.20.0.241 SNMPv2-MIB::sysName.0 SNMPv2-MIB::sysDescr.0
```

You should see `Timeout` twice: with allowed-addresses 127.0.0.0/8 only, and still with 10.20.0.0/24 added. After port lockdown
allows udp:161 on self-internal: `sysName lb-f5a.f5lab.test` and `sysDescr` "BIG-IP Virtual Edition ... 17.5.1.11".

Now real values from the F5 MIBs:

```bash
$LSX snmpwalk -v2c -c public 10.20.0.241 F5-BIGIP-LOCAL-MIB::ltmPoolMbrStatusAvailState | grep 'pool-web"'
$LSX snmpget -v2c -c public 10.20.0.241 F5-BIGIP-SYSTEM-MIB::sysStatClientCurConns.0 F5-BIGIP-SYSTEM-MIB::sysGlobalHostCpuUsageRatio1m.0 F5-BIGIP-SYSTEM-MIB::sysCmFailoverStatusStatus.0
```

You should see every pool-web member green(1) (four lines), then client connections (3 in my run), the 1-minute CPU (11) and the
failover status ACTIVE.

### 7. High-speed request logging from TMM
A request-log profile makes TMM send one line per response straight to a pool, without syslog-ng. In tmsh on lb-f5a:

```bash
create ltm pool pool-hsl members add { 10.20.0.20:514 } monitor gateway_icmp
create ltm profile request-log reqlog-web response-logging enabled response-log-pool pool-hsl response-log-protocol mds-udp response-log-template "client=$CLIENT_IP:$CLIENT_PORT vs=$VIRTUAL_NAME $HTTP_METHOD $HTTP_URI status=$HTTP_STATUS"
modify ltm virtual vs-web profiles add { reqlog-web }
quit
```

One request from pc1, then the last line on the log server:

```bash
ssh admin@172.21.32.111 'curl -s -o /dev/null http://app.f5lab.test/first'; sleep 2; $LSX tail -n 1 $REM
```

You should see the line arrive, but split at the first colon: `client=10.10.0.11: 35156 ...`. The template has no syslog header,
so rsyslog takes everything up to the first colon as the tag.

The fix is a syslog header in the template: `<134>` (facility local0, severity info) and a tag. In tmsh on lb-f5a:

```bash
modify ltm profile request-log reqlog-web response-log-template "<134>f5-reqlog: client=$CLIENT_IP port=$CLIENT_PORT vs=$VIRTUAL_NAME $HTTP_METHOD $HTTP_URI status=$HTTP_STATUS server=$SERVER_IP:$SERVER_PORT time=$RESPONSE_MSECS ms"
quit
```

```bash
ssh admin@172.21.32.111 'for p in again a b; do curl -s -o /dev/null http://app.f5lab.test/$p; done'; sleep 2; $LSX grep f5-reqlog $REM | tail -n 3
```

You should see three clean lines, for example:
`f5-reqlog: client=10.10.0.11 port=59924 vs=/Common/vs-web GET /again status=200 OK server=10.20.0.11:80 time=4 ms`.

### 8. High-speed logging for system messages
The chain is destination > publisher > filter. Here the publisher has ONLY the remote destination. In tmsh on lb-f5a:

```bash
create sys log-config destination remote-high-speed-log hsl-dest pool-name pool-hsl protocol udp
create sys log-config destination remote-syslog hsl-syslog format rfc5424 remote-high-speed-log hsl-dest
create sys log-config publisher hsl-pub destinations add { hsl-syslog }
create sys log-config filter ltm-to-hsl level notice source mcpd publisher hsl-pub
quit
```

Count the traps, run the test event, and look at all three places:

```bash
echo traps received: $($LSX grep -c ^20 /var/log/snmptraps.log)
docker exec clab-f5-clos-dc-server3 nginx -s stop; sleep 20; $LSX grep server3:80 $REM | tail -n 1
ssh $LBA 'tail -n 2 /var/log/ltm'
echo traps received: $($LSX grep -c ^20 /var/log/snmptraps.log)
docker exec clab-f5-clos-dc-server3 nginx
```

You should see the RFC 5424 line arrive on the log server, with a microsecond timestamp and no message ID
(`mcpd[...] Pool /Common/pool-web member ... monitor status down`). But /var/log/ltm has no new line, and the trap count did not
move (10 before, 10 after).

### 9. The fix: the publisher also writes locally
alertd builds the SNMP traps from the local syslog stream. A filter whose publisher has no local destination takes mcpd's notices
away from /var/log/ltm, from the plain remote syslog, and from alertd. In tmsh on lb-f5a:

```bash
modify sys log-config publisher hsl-pub destinations add { local-syslog }
list sys log-config publisher hsl-pub
quit
```

```bash
echo traps received: $($LSX grep -c ^20 /var/log/snmptraps.log)
docker exec clab-f5-clos-dc-server3 nginx -s stop; sleep 20; ssh $LBA 'tail -n 2 /var/log/ltm'
echo traps received: $($LSX grep -c ^20 /var/log/snmptraps.log); $LSX cat /var/log/snmptraps.log | tr "\t" "\n" | grep -E "^20|snmpTrapOID|STRING: Pool" | tail -n 3
docker exec clab-f5-clos-dc-server3 nginx
```

You should see the down line back in /var/log/ltm, and the traps go from 10 to 12 (bigipServiceDown).

### 10. Check the end state and save
```bash
ssh $LBA 'tmsh list sys syslog remote-servers; tmsh list sys snmp traps allowed-addresses'
ssh $LBA 'tmsh list sys log-config publisher hsl-pub; tmsh list ltm virtual vs-web profiles'
ssh $LBA 'tmsh save sys config' | tail -1
```

## Verify
- Remote syslog: the member down/up lines on the log server, the same text as /var/log/ltm, sent from 10.20.0.241 over UDP.
- Traps: enterprises.3375.2.4.0.10 / .0.11 before the MIBs, bigipServiceDown / bigipServiceUp after `demo/f5-mibs.sh`.
- Polling: Timeout until both allowed-addresses 10.20.0.0/24 and allow-service udp:161 are set; then sysName lb-f5a.f5lab.test and
  every pool-web member green(1).
- Request log: one `f5-reqlog:` line per response with client, virtual server, method, URI, status, server and time.
- HSL publisher with local-syslog: the line in /var/log/ltm and the traps counter moving (10 > 12).

## Gotchas
- syslog-ng's remote server receives everything (systemd, CROND, tmsh audit lines, the web UI's access log), not only LTM messages.
- In one run the 20 s check after stopping server3 came back empty: the down line arrived just after it. Wait a few more
  seconds before you decide nothing arrived.
- SNMP polling needs BOTH the allowed address and port lockdown udp:161 on the self IP you poll. Neither alone answers, and there is
  no error: only a timeout. A wrong community also just times out.
- A request-log template without a syslog header is split at the first colon by rsyslog. Start the template with `<134>tag: `.
- In a log-config filter, `source ltm` is a syntax error. Member monitor messages come from `source mcpd`.
- A publisher with only a remote destination removes the messages it matches from /var/log/ltm and the plain remote syslog, and
  NO SNMP traps are sent for them (3 down/up events, 0 traps). Add `local-syslog` to the publisher.

## End state
lb-f5a (everything from part 9, plus):
- Remote syslog remotesyslog1: 10.20.0.20:514.
- SNMP trap logsrv-trap (10.20.0.20, v2c, port 162); allowed-addresses 127.0.0.0/8 and 10.20.0.0/24.
- self-internal allow-service udp:161.
- pool-hsl (10.20.0.20:514, gateway_icmp).
- reqlog-web on vs-web (vs-web profiles: tcp, http-xff, oneconnect, reqlog-web).
- hsl-dest, hsl-syslog, hsl-pub (hsl-syslog + local-syslog), filter ltm-to-hsl.
- Configuration saved.

The log server keeps the F5 MIB files copied by `demo/f5-mibs.sh` until the reset removes them.

Save a UCS for the next part:

```bash
./f5-save.sh lb-f5a
```

## Reset
`demo/part10-reset.sh` puts lb-f5a and the log server back to this part's starting state. On lb-f5a it removes, in dependency
order: reqlog-web from vs-web, the request-log profile, the filter, the publisher, both destinations, pool-hsl, the remote syslog
server, the trap destination, the extra allowed address, and udp:161 on self-internal; then it saves. On the log server it removes
the copied F5 MIB files, moves old log lines aside to `*.old` (never deleted) and restarts snmptrapd.

```bash
./demo/part10-reset.sh
```

## Files used
- `demo/f5-mibs.sh`: copies the BIG-IP's F5-BIGIP-COMMON/SYSTEM/LOCAL MIB files into the log server and restarts snmptrapd.
- `demo/part10-reset.sh`: removes every part 10 object on lb-f5a and the copied MIBs on the log server.

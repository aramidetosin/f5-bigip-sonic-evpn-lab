# Part 18: GSLB with BIG-IP DNS: wide IPs, pools and the resolver

**Coming.** Planned for 2026-12-17 04:00 UTC. This guide is published here with the part: every command in order, how to verify and how to reset, as for parts 1-17.

| | |
|---|---|
| Previous / next | [Part 17](part17.md) / [Part 19](part19.md) |
| All parts | [README](../../README.md#the-series-part-by-part) |

## What this part covers

The HA pair split into two sites (lb-f5a = site A, lb-f5b = site B), BIG-IP DNS on both, listeners, data centres, servers, virtual-server discovery, and a wide IP app.gslb.f5lab.test with a pool per site, resolved from pc1 by round robin, ratio and topology.

## Already in the lab

The clients' resolver (BIND on lan-switch, 10.10.0.5, `shared/resolver-up.sh`) and the firewall's DNS rule are already in the lab: `gen.py` `GSLB` holds the values (site A 10.20.5.0/25: app VIP 10.20.5.10, DNS listener 10.20.5.53; site B 10.20.5.128/25: 10.20.5.140, 10.20.5.153). Licence: BIG-IP DNS.

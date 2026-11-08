# Part 20: Anycast VIPs with route health injection: one address, two sites, active-active

**Coming.** Planned for 2026-12-22 04:00 UTC. This guide is published here with the part: every command in order, how to verify and how to reset, as for parts 1-18.

| | |
|---|---|
| Previous / next | [Part 19](part19.md) / [Part 21](part21.md) |
| All parts | [README](../../README.md#the-series-part-by-part) |

## What this part covers

One VIP advertised as a /32 by both sites with route health injection, each site with its own pool and SNAT: the fabric holds two BGP paths and load-shares by ECMP. Then site A's application fails while pc1 fetches in a loop: the route is withdrawn and the failover is timed sample by sample, with no DNS cache involved, and what happens to established flows is measured.

# F5 BIG-IP on a SONiC EVPN fabric: a containerlab lab

The lab behind the series **"Learning F5 BIG-IP on a real data-centre fabric running on SONiC switches"**: F5 BIG-IP Local Traffic
Manager, Advanced WAF and BIG-IP DNS, configured on a realistic data-centre network. That network is a SONiC spine-leaf EVPN/VXLAN fabric,
with a Palo Alto firewall between two VRFs, servers and PCs. One script builds the whole lab, and every part of the series has a
step-by-step guide here.

- **Build the lab:** [docs/BUILD.md](docs/BUILD.md) covers the prerequisites, the images, the licences you bring, `gen.py`,
  `up.sh` / `down.sh`, the secrets, validation and access.
- **Follow the series:** one guide per part, listed below. Each guide gives the goal, the starting state, every command in order,
  how to verify, what I measured, how to reset, and links to the video and the written walkthrough.

## The lab (23 nodes)

| Nodes | What |
|---|---|
| spine1-2, three leaf pairs (service, server, border) | Dell Enterprise SONiC 4.6: eBGP unnumbered underlay, BGP EVPN / VXLAN, symmetric IRB with anycast gateways, EVPN multihoming (ESI-LAG) |
| fw-pa | Palo Alto PA-VM 12.1.2: the only path between Vrf-Outside (users) and Vrf-App (servers and BIG-IPs), eBGP to both sides |
| lb-f5a, lb-f5b | F5 BIG-IP VE 17.5.1: **blank and unlicensed** after the build, management reachable only; part 2 starts the configuration |
| server1-3 | nginx "whoami" pages (http / https with a lab CA, one colour per server) and a JSON test API |
| log-server, sorry-server | rsyslog + SNMP traps; a maintenance page |
| lan-switch, pc1-3 | the users' LAN (and the clients' DNS resolver); each PC runs Firefox in a web desktop |
| k8s-cp, k8s-w1, k8s-w2 | a Kubernetes cluster (kubeadm, kindnet) on the server leaves, for F5 CIS from part 22 |

Two designs share the same cables. **Basic** (parts 2-13) is a two-arm design: the BIG-IP ports carry the basic VLANs untagged.
**Advanced** (part 14 on) adds BGP from the BIG-IPs to the service leaves with route health injection: the same ports also carry tagged
transits. The switches and firewall are configured for both, and the BIG-IP configuration decides which one is live.

## Quick start

As root on a Linux host with Docker, containerlab, KVM, about 100 GiB of free RAM, the three appliance images and two public images
([details](docs/BUILD.md#1-what-you-need)):

```bash
python3 gen.py      # regenerate the topology and configs after any change
./up.sh --check     # preflight only
./up.sh             # build everything: about 13 minutes, ends with 40 automatic checks
./validate.sh       # run the checks again at any time
./f5-save.sh        # save both BIG-IP configurations (UCS)
./down.sh           # save, refuse while a BIG-IP holds a licence, destroy
```

## The series, part by part

Videos and written walkthroughs are published at 04:00 UTC on the date shown. Each guide works as soon as it is here.

| Part | Guide | Published |
|---|---|---|
| 1 | [The lab, layer by layer](docs/parts/part01.md) | 2026-11-07 |
| 2 | [Licensing and plugging the BIG-IPs into the fabric](docs/parts/part02.md) | 2026-11-10 |
| 3 | [The first virtual server, and why it fails behind a firewall](docs/parts/part03.md) | 2026-11-12 |
| 4 | [SNAT in depth: AutoMap, SNAT pools and X-Forwarded-For](docs/parts/part04.md) | 2026-11-14 |
| 5 | [Load-balancing methods, measured](docs/parts/part05.md) | 2026-11-17 |
| 6 | [Health monitors that catch real failures](docs/parts/part06.md) | 2026-11-19 |
| 7 | [Persistence: source address and cookies](docs/parts/part07.md) | 2026-11-21 |
| 8 | [SSL offload with a lab CA](docs/parts/part08.md) | 2026-11-24 |
| 9 | [Priority groups, a sorry server and OneConnect](docs/parts/part09.md) | 2026-11-26 |
| 10 | [Remote logging and SNMP](docs/parts/part10.md) | 2026-11-28 |
| 11 | [Troubleshooting with tcpdump, from the BIG-IP to the fabric](docs/parts/part11.md) | 2026-12-01 |
| 12 | [iRules for network engineers](docs/parts/part12.md) | 2026-12-03 |
| 13 | [High availability across a leaf pair](docs/parts/part13.md) | 2026-12-05 |
| 14 | [BGP and route health injection into SONiC](docs/parts/part14.md) | 2026-12-08 |
| 15 | [Where the VIP lands inside SONiC: FRR, APPL_DB and ASIC_DB](docs/parts/part15.md) | 2026-12-10 |
| 16 | [Advanced WAF: protecting the app, from attack to false positive](docs/parts/part16.md) | 2026-12-12 |
| 17 | [Advanced WAF for APIs: a policy from the OpenAPI contract](docs/parts/part17.md) | 2026-12-15 |
| 18 | [GSLB with BIG-IP DNS: wide IPs, pools and the resolver](docs/parts/part18.md) | 2026-12-17 |
| 19 | [GSLB failover between two sites, timed](docs/parts/part19.md) | 2026-12-19 |
| 20 | [Anycast VIPs with route health injection: one address, two sites, active-active](docs/parts/part20.md) | 2026-12-22 |
| 21 | [AS3: declaring BIG-IP configuration as code](docs/parts/part21.md) | 2026-12-24 |
| 22 | [Kubernetes services through the BIG-IP with F5 CIS](docs/parts/part22.md) | 2026-12-26 |
| 23 | [CIS in cluster mode: pods as pool members, TLS and WAF from Kubernetes](docs/parts/part23.md) | coming |
| 24 | [The BIG-IP as the front door of an AI inference fabric](docs/parts/part24.md) | coming |

Videos: [youtube.com/@levelupit](https://www.youtube.com/@levelupit) (playlist "F5 BIG-IP on a SONiC EVPN Fabric"). Written walkthroughs: [levelupit.xyz](https://www.levelupit.xyz/).

## Layout

| Path | What |
|---|---|
| `gen.py` | the single source of every value |
| `f5-clos-dc.clab.yml`, `configs/`, `bootstrap/`, `mgmt-hosts.txt`, `images.txt`, `k8s/kubeadm.yaml`, `shared/*-values.sh`, `shared/openapi-*.json`, `shared/whoami-colors.txt` | generated by `gen.py` (`up.sh` runs it first; not committed) |
| `up.sh`, `down.sh`, `validate.sh` | build, tear down, check |
| `sonic-apply.sh`, `pa-load.sh`, `pa-firstpw.py`, `ssh-keys.sh`, `mgmt-access.sh`, `secrets-init.sh`, `lib.sh` | the stages `up.sh` runs |
| `f5-save.sh`, `f5-restore.sh`, `f5-revoke.sh` | save and restore your BIG-IP work as UCS; give a licence back before `down.sh` |
| `k8s-seed.sh`, `k8s-up.sh`, `k8s/` | the Kubernetes nodes' `/var` and the cluster build (stages of `up.sh`); the manifests per part; `k8s/vendor/` = F5's CIS CRDs and RBAC, unchanged |
| `shared/`, `images/` | the Linux nodes' startup scripts and Dockerfiles; `images/pa-launch/` is the PA-VM image's vrnetlab launcher with one fix |
| `demo/` | the helper scripts and BIG-IP configuration files the parts use (iRules, BGP, the WAF API policy) |
| `tests/` | tests of the Linux node images and startup scripts, without deploying |
| `docs/` | the build guide and one guide per part |

## Licence

See `LICENSE`. `images/pa-launch/launch.py` comes from vrnetlab and keeps vrnetlab's MIT licence. `k8s/vendor/` holds F5's CIS manifests from the
F5Networks/k8s-bigip-ctlr repository, unchanged, under its Apache License 2.0. F5, Palo Alto and Dell SONiC images
and licences are not included and remain under their vendors' terms.

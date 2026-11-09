# Build the lab from scratch

This guide takes an empty Linux host to the lab every part of the series starts from: a SONiC EVPN/VXLAN fabric, a Palo Alto
firewall between two VRFs, servers, PCs with a browser, and two blank BIG-IP VEs. One script builds it all. The BIG-IPs come up
**unlicensed and unconfigured**, with only their management interface reachable. Part 2 licenses them and plugs them into the fabric.

Contents:
1. [What you need](#1-what-you-need)
2. [Build the appliance images](#2-build-the-appliance-images)
3. [Get the repo and adjust gen.py](#3-get-the-repo-and-adjust-genpy)
4. [Secrets](#4-secrets)
5. [Build the lab](#5-build-the-lab)
6. [Validate](#6-validate)
7. [Get into every device](#7-get-into-every-device)
8. [Save, restore and tear down](#8-save-restore-and-tear-down)
9. [What gen.py builds](#9-what-genpy-builds)

## 1. What you need

**A Linux host** with:
- Docker and [containerlab](https://containerlab.dev). I run containerlab 0.82.
- KVM (`/dev/kvm`). The switches, the firewall and the BIG-IPs are VMs inside containers (vrnetlab).
- **At least 100 GiB of free RAM.** `up.sh` refuses to start with less (the lab needs about 90 GiB: 2 x 16 GiB BIG-IP, 8 GiB PA-VM,
  6 x 6 GiB leaves, the spines and the Linux nodes; it keeps 10 GiB free). To change the threshold: `NEED_GIB=<n> ./up.sh`.
- `python3`, `sshpass`, `openssl`, `nft`, `curl` (the preflight checks for each one).
- Internet access from the host. The management network is masqueraded out of one host interface, so the BIG-IPs can reach F5's
  licence server and the Linux images can be built.

My host is an EVE-NG server used as a plain containerlab host (96 CPUs, 377 GiB RAM). Any Linux machine with the items above works.

**Three appliance images** you build yourself from your own vendor downloads (section 2):

| Image tag (must match) | What | Used for |
|---|---|---|
| `vrnetlab/dell_sonic:4.6.0` | Dell Enterprise SONiC 4.6 virtual switch | spine1-2, six leaves |
| `vrnetlab/paloalto_pa-vm:12.1.2` | Palo Alto PA-VM 12.1.2 | fw-pa |
| `vrnetlab/f5_bigip-ve:17.5.1.11-0.0.12` | F5 BIG-IP VE 17.5.1.11 | lb-f5a, lb-f5b |

The four small Linux images (`scd/host:1`, `f5lab/web:1`, `f5lab/tools:1`, `f5lab/pc:1`) are built by `up.sh` from `images/`.

**Two public images** for the Kubernetes cluster (parts 22-24), pulled once on the host (the nodes have no internet access;
`k8s-up.sh` copies the images they need into each node):

```bash
docker pull kindest/node:v1.35.8                    # the three Kubernetes nodes (up.sh refuses to start without it)
docker pull f5networks/k8s-bigip-ctlr:2.20.4.1      # F5 CIS, part 22 on
```

**Licences you bring.** No licence key is in this repo and none is applied by the scripts.
- BIG-IP: your own registration keys, one per unit. **LTM** covers parts 2-15. Parts 16-17 need **Advanced WAF** on the same key.
  Parts 18-19 need **BIG-IP DNS**. An evaluation key that bundles all three covers the whole series. Part 2 shows activation in the
  web UI and from the CLI.
- PA-VM and Dell SONiC: whatever your vendor download requires. The lab scripts apply no licence to them.

## 2. Build the appliance images

Use [vrnetlab](https://github.com/hellt/vrnetlab) (the containerlab fork). For each appliance: put the vendor's qcow2 into the
matching vrnetlab folder, run `make`, and tag the result with the exact name from the table above:

```bash
docker images | grep -E 'dell_sonic|paloalto_pa-vm|f5_bigip-ve'
```

```bash
docker tag <image-id> vrnetlab/f5_bigip-ve:17.5.1.11-0.0.12
```

If you use other versions, change `IMG_SONIC`, `IMG_PA` and `IMG_F5` in `gen.py` **and** the three names in the preflight loop of
`up.sh`. The guides were measured on the versions above.

`images/pa-launch/launch.py` is the PA-VM image's own vrnetlab launcher with one fix (the first-boot password prompts are matched
loosely, because a kernel message on the console can split a prompt across two reads). `gen.py` bind-mounts it over the image's
`/launch.py` for fw-pa only; your image is not changed.

## 3. Get the repo and adjust gen.py

Everything runs **as root on the lab host, from the repo folder**.

```bash
git clone https://github.com/aramidetosin/f5-bigip-sonic-evpn-lab.git
```

```bash
cd f5-bigip-sonic-evpn-lab
```

`gen.py` is the single source of every name, address, VLAN and AS number. It generates the containerlab topology, the eight switch
configurations, the firewall configuration and the values the Linux nodes read. Never edit the generated files; edit `gen.py` and run
it again (`up.sh` runs it first anyway).

Check two values at the top of `gen.py` before the first build:

| Variable | Default | Set it to |
|---|---|---|
| `LAN_IF` | `pnet0` (EVE-NG's LAN bridge) | the host interface that reaches the internet; the management subnet is masqueraded out of it |
| `MGMT` | `172.21.32` | a /24 that is free on your host (no Docker network, no route). `up.sh` checks it |

Keep every other value as it is if you want to follow the guides line by line: every address in them comes from `gen.py`.

```bash
python3 gen.py
```

## 4. Secrets

`secrets-init.sh` creates the lab's credentials once, on the lab host, in **`/root/f5-clos-dc-secrets`** (mode 700, files 600). Re-runs
keep what exists. `up.sh` calls it, so you don't have to. Nothing is printed, and nothing is written into the repo folder.

| File | Holds |
|---|---|
| `appliances.env` | the switch and PA-VM logins (the images' defaults) |
| `host.env` | the Linux nodes' admin and root passwords |
| `lb-f5a.env`, `lb-f5b.env` | the BIG-IP admin and root passwords, hostname and DNS for the BIG-IP launcher (no licence key) |
| `pc.env` | the PCs' web-desktop login |
| `authorized_keys` | the host's root public keys, pushed to every node by `ssh-keys.sh` |
| `tls/` | a lab CA, and a key and certificate for `app.f5lab.test`, `sorry.f5lab.test`, `server1-3.f5lab.test` |
| `ucs/` | your BIG-IP configurations, saved by `f5-save.sh` |

Read a password only when you need one, for example the BIG-IP admin password (the same on both units):

```bash
sudo sed -n 's/^PASSWORD=//p' /root/f5-clos-dc-secrets/lb-f5a.env
```

Keep this folder out of any git repository. UCS archives contain private keys, password hashes and your licence.

## 5. Build the lab

Preflight only (tools, images, free management subnet, RAM, gen.py, secrets):

```bash
./up.sh --check
```

The whole build:

```bash
./up.sh
```

It runs these stages and logs the detail to `logs/` (ignored by git):

| Stage | What |
|---|---|
| 0 preflight | root, tools, images (builds the four Linux images from `images/`), free management subnet, RAM, `gen.py`, secrets |
| 1a Kubernetes `/var` | `k8s-seed.sh`: a fresh `/var` for each Kubernetes node in a host directory (`/var/lib/f5lab-k8s/<node>`), copied from the kindest/node image (containerd's snapshots fail on the container's own overlay root) |
| 1 deploy | `containerlab deploy --reconfigure` (refused while a BIG-IP of this lab is running: `./down.sh` first) |
| 2 access | `mgmt-access.sh`: masquerade the management subnet out of `LAN_IF`; optionally add it to the host's Tailscale routes |
| 3 switches | `sonic-apply.sh`: `configs/<switch>.cli` on all eight switches |
| 4 firewall | `pa-load.sh`: `bootstrap/fw-pa.xml` (import, partial replace, commit) |
| 4b Kubernetes | `k8s-up.sh`: kubeadm on k8s-cp with `k8s/kubeadm.yaml` (generated), the kindnet CNI, the workers joined with their fabric address as node IP, `f5lab/web:1` and CIS loaded into every node |
| 5 BIG-IP | waits until both management interfaces answer HTTPS and SSH; nothing else is configured on them |
| 5b SSH keys | `ssh-keys.sh`: passwordless SSH as `admin` from the host to the 20 non-Kubernetes nodes (the Kubernetes nodes: `docker exec`) |
| 6 validate | `validate.sh` |

In my last build it took about 13 minutes (each SONiC switch needs about 6 minutes to report "Startup complete"; the PA-VM about
8 minutes; the Kubernetes cluster about 70 s). It ends with `validate: 40 PASS, 0 FAIL`.

## 6. Validate

```bash
./validate.sh
```

Read-only. It checks, with PASS / FAIL per line:
- the underlay and EVPN sessions on every switch (spines 6, leaves 2);
- the firewall peering in both VRFs on both service leaves;
- every host reaches its anycast gateway;
- users reach the published range through the firewall, and nothing else (a server's own address must fail);
- the servers answer http and https inside Vrf-App;
- the PCs' web desktops answer;
- the BIG-IPs answer HTTPS and SSH on their management addresses (management only).

`tests/host-scripts-test.sh` tests the Linux node images and their startup scripts **without deploying** the lab. Each node runs in a
throwaway container with dummy interfaces:

```bash
./tests/host-scripts-test.sh
```

## 7. Get into every device

From the lab host, every node answers passwordless SSH as `admin` (`ssh-keys.sh`). Containers are named `clab-f5-clos-dc-<node>`;
`docker exec -it clab-f5-clos-dc-<node> bash` (or `sh`) needs no password at all.

| Node | Management | Lab address | Notes |
|---|---|---|---|
| lb-f5a / lb-f5b | 172.21.32.43 / .44 | from part 2 | web UI `https://<mgmt>`, user `admin`; SSH opens bash, type `tmsh` for the BIG-IP shell |
| fw-pa | 172.21.32.40 | transits 10.254.1.3, 10.254.2.3 | web UI `https://172.21.32.40`; SSH opens the PAN-OS CLI |
| spine1-2 | .11-.12 | | Dell SONiC: `sonic-cli`, `sudo vtysh` |
| leaf1a/b-service | .21-.22 | | firewall and BIG-IPs |
| leaf2a/b-server | .23-.24 | | servers |
| leaf3a/b-border | .25-.26 | | client LAN |
| server1-3 | .101-.103 | 10.20.0.11-13 | the whoami app: blue, green, orange |
| log-server | .104 | 10.20.0.20 | rsyslog (514) and snmptrapd (162) |
| sorry-server | .105 | 10.20.30.30 | the red maintenance page |
| lan-switch | .110 | 10.10.0.5 | the client LAN bridge (and, from part 18, the clients' DNS resolver) |
| pc1-3 | .111-.113 | 10.10.0.11-13 | Firefox in a web desktop: `https://<mgmt>:3001`, login from `pc.env` |
| k8s-cp, k8s-w1, k8s-w2 | .121-.123 | 10.20.0.31-33 | the Kubernetes nodes (part 22 on): `docker exec -it clab-f5-clos-dc-k8s-cp bash`; kubectl on k8s-cp with `--kubeconfig /etc/kubernetes/admin.conf` (`kubectl` in `demo/f5fn.sh`) |

The PCs resolve `app.f5lab.test` (10.20.30.100), `api.f5lab.test` (10.20.30.101, part 17), `any.f5lab.test` (10.20.5.200, part 20),
`as3.f5lab.test` (10.20.30.110, part 21), `k8s.f5lab.test` (10.20.30.120, part 22) and `sorry.f5lab.test` (10.20.30.30), and trust
the lab CA. On the BIG-IP's bash, `ip` is an older version: use `ip addr`, not `ip -br addr`.

To reach the management network from another machine, either route `172.21.32.0/24` via the lab host, or let `mgmt-access.sh`
advertise it on Tailscale (approve the subnet route once in your Tailscale admin console). The PCs also publish their desktops on the
host's `127.0.0.1:31N0` (http) and `31N1` (https) for SSH or VS Code port forwarding (pc1 = 3110 / 3111).

The test app every server returns (curl gets text, a browser gets a coloured page) shows exactly who answered and what it saw:

```
server2 10.20.0.12
server:           server2 10.20.0.12:80
scheme:           http
client seen:      10.20.0.240:41022
x-forwarded-for:  10.10.0.11
host:             app.f5lab.test
request:          GET / HTTP/1.1
cookie:           BIGipServerpool-web=...
request id:       ...
```

`/health` returns `OK` (for monitors), `/static/object.txt` and `/static/large.bin` are for long transfers. From part 17 the servers
also run a small JSON API on port 8080 (`shared/api-up.sh`).

## 8. Save, restore and tear down

| You want to | Command |
|---|---|
| save your BIG-IP work (one UCS per unit, in `/root/f5-clos-dc-secrets/ucs/`) | `./f5-save.sh` (or `./f5-save.sh lb-f5a`) |
| put a saved configuration back after a rebuild | `./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<file>.ucs` |
| list saved configurations | `ls -lt /root/f5-clos-dc-secrets/ucs/` |
| destroy the lab | `./down.sh` |
| destroy it once the BIG-IPs are licensed | revoke both licences first, then `./down.sh --licences-revoked` |

`f5-restore.sh` loads the UCS with `no-license`, so the unit keeps the licence you activated on it. It takes about a minute; the
BIG-IP restarts its REST API during the load, so a 502 on the way is expected.

**Revoke before you destroy.** An evaluation key still bound to a deleted VM is lost. Revoke in each web UI (System > License > Revoke)
or in tmsh (`revoke sys license`), or with `./f5-revoke.sh` (from part 14 on a unit's data-plane default route also carries its own
traffic, so the licence server is not reachable; the script adds temporary management routes, revokes, removes them and checks). `down.sh` saves both configurations first, then refuses while a BIG-IP still reports a licence,
unless you pass `--licences-revoked`. Don't run `containerlab destroy` directly: it skips both steps.

A typical session: `./up.sh` > license both BIG-IPs > `./f5-restore.sh` both units > work through a part > `./f5-save.sh` > revoke >
`./down.sh --licences-revoked`.

## 9. What gen.py builds

| Layer | What |
|---|---|
| Fabric | 2 spines (AS 65000) and three leaf pairs: `leaf1a/b-service` (AS 65001: firewall and BIG-IPs), `leaf2a/b-server` (AS 65002), `leaf3a/b-border` (AS 65003). eBGP unnumbered underlay, BGP EVPN, VXLAN, symmetric IRB with anycast gateways |
| VRFs | **Vrf-Outside** (L3VNI 50001): VLAN 110, users 10.10.0.0/24. **Vrf-App** (L3VNI 50002): VLAN 120, servers 10.20.0.0/24; VLAN 130, BIG-IP external 10.20.30.0/24. L2VNI = 10000 + VLAN |
| Multihoming | every dual-homed host (firewall, servers, log and sorry servers, Kubernetes nodes, LAN switch) on an ESI-LAG with LACP across its leaf pair. The BIG-IPs are single-homed: 1.1 to leaf1a-service, 1.2 to leaf1b-service, 1.3 to 1.3 for HA |
| Firewall | fw-pa (AS 65500) is the only path between the two VRFs: ae1 to the service pair, transit VLANs 3001 (Outside) and 3002 (App), eBGP in both. Users may reach only 10.20.30.0/24 and the 10.20.5.0/24 host routes, on tcp/80, 443, ping, and DNS (from part 18). Default deny with logging, no NAT |
| BIG-IP ports | the same cables serve two designs. **Basic** (parts 2-13): 1.1 = VLAN 130 untagged, 1.2 = VLAN 120 untagged, VIPs in 10.20.30.0/24. **Advanced** (part 14 on): the same ports also carry tagged transits 3005 / 3007, eBGP from AS 65020 to both service leaves, VIP /32s in 10.20.5.0/24. The switches and firewall are configured for both; the BIG-IP configuration decides which one is live |
| Additions | a JSON test API with its OpenAPI file (part 17); a DNS resolver on lan-switch delegating `gslb.f5lab.test` to the BIG-IP DNS listeners (parts 18-19); a three-node Kubernetes cluster on the server leaves, VLAN 120, 10.20.0.31-33 (kubeadm, kindnet; parts 22-24) |

Next: [Part 1, the lab layer by layer](parts/part01.md), then [Part 2](parts/part02.md) to license the BIG-IPs.

# Part 1: The lab, layer by layer

| | |
|---|---|
| Video | [F5 BIG-IP on a SONiC EVPN Fabric: The Lab, Layer by Layer (Part 1)](https://youtu.be/oCAVrGrmZRI) (public from 2026-11-07 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-the-lab/) (from 2026-11-07 04:00 UTC) |
| Previous / next | none / [Part 2](part02.md) |

## Goal

This part configures nothing on the BIG-IPs. It is a tour of the built lab, one layer at a time, with the command that shows each
layer live: the nodes, the eBGP unnumbered underlay, EVPN and VXLAN, EVPN multihoming, the firewall as the only door between the two
VRFs, the servers, and the users' view. It ends with two blank, unlicensed BIG-IPs and one script that rebuilds everything else.

## Starting state

- `./up.sh` has finished on the lab server and its last line is `validate: 36 PASS, 0 FAIL`.
- Both BIG-IPs (lb-f5a, lb-f5b) are blank and unlicensed. Only their management interface answers (SSH and web UI).
- Nothing from an earlier part is needed.

Every command below runs **on the lab server (root, in the repo folder)** unless a step says otherwise. The lab server reaches every
node by passwordless SSH as `admin` (`up.sh` installs the keys).

## Values used in this part

| Object | Value |
|---|---|
| Management network | 172.21.32.0/24 |
| spine1, spine2 | 172.21.32.11, .12 (AS 65000) |
| leaf1a-service, leaf1b-service | 172.21.32.21, .22 (AS 65001), VTEPs 10.255.255.11, .12 |
| leaf2a-server, leaf2b-server | 172.21.32.23, .24 (AS 65002), VTEPs 10.255.255.21, .22 |
| leaf3a-border, leaf3b-border | 172.21.32.25, .26 (AS 65003), VTEPs 10.255.255.31, .32 |
| fw-pa | management 172.21.32.40, AS 65500, 10.254.1.3 (outside transit, VLAN 3001), 10.254.2.3 (app transit, VLAN 3002) |
| lb-f5a, lb-f5b | management 172.21.32.43, .44 |
| server1, server2, server3 | 10.20.0.11, .12, .13 (management .101-.103) |
| log-server | 10.20.0.20 (management .104) |
| sorry-server | 10.20.30.30, `sorry.f5lab.test` (management .105) |
| pc1, pc2, pc3 | 10.10.0.11, .12, .13 (management .111-.113), gateway 10.10.0.1 |
| Vrf-Outside | L3 VNI 50001 (VLAN 1501); VLAN 110 = 10.10.0.0/24, L2 VNI 10110 |
| Vrf-App | L3 VNI 50002 (VLAN 1502); VLAN 120 = 10.20.0.0/24, VLAN 130 = 10.20.30.0/24 |
| Anycast gateway MAC | 00:00:5e:00:01:01 |
| Future virtual server | `app.f5lab.test` = 10.20.30.100 (range 10.20.30.100-.199) |

## Steps

### 1. All twenty nodes

containerlab runs every node. The switches, the firewall and the BIG-IPs are virtual machines inside containers; the servers and PCs
are plain Linux containers.

```bash
containerlab inspect -t f5-clos-dc.clab.yml --format csv | cut -d, -f4,6,8,10 | column -s, -t
```

You should see all 20 nodes running, each with its management address. (I ran it with containerlab 0.82; plain
`containerlab inspect -t f5-clos-dc.clab.yml` shows the same in a table.)

### 2. The underlay: eBGP unnumbered on spine1

Each leaf pair has its own AS, the spines share AS 65000. The fabric links have no IPv4 address: BGP runs over IPv6 link-local
addresses and carries the IPv4 routes.

```bash
ssh admin@172.21.32.11 'sudo vtysh -c "show bgp summary"'
```

You should see 6 neighbours (two each in AS 65001, 65002 and 65003), 6 established, in both tables (IPv4 unicast and L2VPN EVPN). The
neighbour column shows interface names, Ethernet0 to Ethernet5, not addresses: BGP unnumbered.

### 3. EVPN and VXLAN on border leaf 3a

The border leaf is where the users come in. It has a layer-2 VNI for the users' VLAN and a layer-3 VNI for Vrf-Outside.

```bash
ssh admin@172.21.32.25 'sudo vtysh -c "show evpn vni"'
ssh admin@172.21.32.25 'sudo vtysh -c "show ip route vrf Vrf-Outside"'
```

You should see VNI 10110 (L2) and 50001 (L3). In Vrf-Outside, 10.10.0.0/24 is connected on VLAN 110, and 10.20.30.0/24 is a BGP
route with two next hops, 10.255.255.11 and 10.255.255.12 (the two service leaves' VTEPs), over VLAN 1501. The firewall's outside
transit is learnt the same way.

### 4. The users' MACs in EVPN

```bash
ssh admin@172.21.32.25 'sudo vtysh -c "show evpn mac vni 10110"'
```

You should see the anycast gateway MAC 00:00:5e:00:01:01 owned by the leaf itself, and the PCs and the LAN switch learnt on
PortChannel30 (the two-cable link to the LAN switch). Every entry is advertised to the rest of the fabric.

### 5. EVPN multihoming (ESI-LAG) on server leaf 2a

Every dual-homed host (firewall, servers, LAN switch) has one PortChannel across a leaf pair, with the same ESI on both leaves.

```bash
ssh admin@172.21.32.23 'sonic-cli -c "show PortChannel summary"'
ssh admin@172.21.32.23 'sonic-cli -c "show evpn es"'
```

You should see PortChannel21 to PortChannel25 up `(U)` (server1-3, log-server, sorry-server), and each ESI of type `LR` (local and
remote) with the partner leaf 10.255.255.22.

More detail, if you want it:

```bash
ssh admin@172.21.32.23 'sudo vtysh -c "show evpn es detail"'
ssh admin@172.21.32.23 'sudo vtysh -c "show bgp l2vpn evpn route type es"'
ssh admin@172.21.32.23 'sudo vtysh -c "show bgp l2vpn evpn route type ead"'
docker exec clab-f5-clos-dc-server1 cat /proc/net/bonding/bond0
```

Healthy: `State: up` and `Ready for BGP: yes` per segment; a type-4 route per ESI from both leaves of the pair; on server1, 802.3ad
with both slaves up.

The BIG-IPs are not on an ESI-LAG: each BIG-IP data port is one single link to one service leaf.

### 6. The firewall, the only door between the VRFs

On service leaf 1a, inside Vrf-Outside, the firewall is the only BGP neighbour, and it announces the virtual server range.

```bash
ssh admin@172.21.32.21 'sudo vtysh -c "show bgp vrf Vrf-Outside summary"'
ssh admin@172.21.32.21 'sudo vtysh -c "show ip route vrf Vrf-Outside 10.20.30.0/24"'
```

You should see one neighbour, 10.254.1.3 (AS 65500), and 10.20.30.0/24 learnt from it, next hop 10.254.1.3.

### 7. The servers' whoami page

Inside Vrf-App, server2 asks server1 for its page.

```bash
ssh admin@172.21.32.102 'curl -s http://10.20.0.11/'
```

The first line says who answered (server1 10.20.0.11). The `client seen:` line says who asked (server2, 10.20.0.12). That line shows
later whether the BIG-IP translates the source address (SNAT).

### 8. The users' view, before any BIG-IP configuration

From pc1 (Vrf-Outside), through the firewall:

```bash
ssh admin@172.21.32.111 'curl -s http://sorry.f5lab.test/ | head -3'
ssh admin@172.21.32.111 'curl -s -m 5 http://10.20.0.11/ || echo blocked'
ssh admin@172.21.32.111 'curl -s -m 5 http://app.f5lab.test/ || echo "no virtual server yet"'
```

You should see:
- the sorry-server's maintenance page (10.20.30.30 is in the published range): the whole path works, border leaf, VXLAN, firewall
  policy, App side;
- `blocked` for server1: the firewall only publishes the virtual server range, and its last rule denies and logs;
- `no virtual server yet` for 10.20.30.100: the policy allows it, but nothing answers there yet.

### 9. The same in a real browser on pc1

Open pc1's web desktop at `https://172.21.32.111:3001` (from a machine that reaches the management network; `up.sh` stage 2 sets up
that access). Log in as `admin` with the password from:

```bash
sudo cat /root/f5-clos-dc-secrets/pc.env
```

Firefox opens on `http://app.f5lab.test/`. The sorry page comes through the firewall; the virtual server does not answer yet. A
standalone VNC client on port 5900 does not work: the desktop is only on the browser ports 3000 (http) and 3001 (https).

### 10. lb-f5a: blank and unlicensed

Open `https://172.21.32.43` and log in as `admin`. The password:

```bash
sudo sed -n 's/^PASSWORD=//p' /root/f5-clos-dc-secrets/lb-f5a.env
```

You should see the banner saying no licence exists for this device. Over SSH (`ssh admin@clab-f5-clos-dc-lb-f5a`) you land in bash;
type `tmsh` for the BIG-IP shell.

### 11. One file holds every value

Every name, address, VLAN and AS number lives in `gen.py`, which generates the topology, the switch configurations and the firewall
configuration. The fabric section:

```bash
sed -n '/^SPINES =/,/^VLAN_DESC = {1501/p' gen.py
```

### 12. Optional: tear it down and build it again

The lab is unlicensed at this point, so it can be destroyed safely.

```bash
./down.sh
./up.sh
```

`down.sh` saves both BIG-IP configurations as UCS archives, refuses to continue while a BIG-IP still holds a licence, then destroys
all 20 containers. `up.sh` runs: stage 0 preflight (tools, images, a free management subnet, memory, then `gen.py`), 1 deploy, 2
management access, 3 boot and configure the 8 switches, 4 load and commit the firewall configuration, 5 wait for the BIG-IPs'
management and install SSH keys on all 20 nodes, 6 the 36 checks.

## Verify

```bash
./validate.sh
```

It runs the same read-only checks `up.sh` ends with: eBGP sessions per switch (spines 6, leaves 2), the firewall's peering in both
VRFs on both service leaves, the anycast gateways from every host, the path through the firewall (allowed and denied), the servers,
the log-server's syslog and SNMP trap listeners, the PCs' web desktops and the BIG-IPs' management. In my run:
`validate: 36 PASS, 0 FAIL`.

## Gotchas

- Each SONiC switch needs a few minutes to boot ("Startup complete" took about 6 minutes per switch in my run); stage 3 is the longest.
- A Docker Hub timeout while building the small Linux images: re-running `./up.sh` fixed it.
- The PA-VM can keep its factory password if its first-boot prompt is missed; `pa-load.sh` detects "Please change your password" from
  the API and finishes the change over SSH (`pa-firstpw.py`).
- Do not use `containerlab destroy` directly: it skips the configuration save and the licence check in `down.sh`.
- From part 2 on the BIG-IPs hold licences: revoke them before `./down.sh` (an evaluation key bound to a deleted VM is lost), then run
  `./down.sh --licences-revoked`.

## End state

The lab is up, `./validate.sh` passes 36 checks, and both BIG-IPs are blank and unlicensed. There is nothing on the BIG-IPs to save.

## Reset

Nothing to reset: this part changes nothing.

## Files used

None from `demo/`. Lab scripts: `up.sh`, `down.sh`, `validate.sh`, `gen.py`.

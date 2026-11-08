# Part 2: Licensing and plugging the BIG-IPs into the fabric

| | |
|---|---|
| Video | [F5 BIG-IP Setup on a SONiC Fabric: VLANs, Self IPs, Licensing (Part 2)](https://youtu.be/S6PBGXSq_kE) (public from 2026-11-10 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-licensing-and-the-fabric/) (from 2026-11-10 04:00 UTC) |
| Previous / next | [Part 1](part01.md) / [Part 3](part03.md) |

## Goal

I license both BIG-IPs, lb-f5a in the web UI (Setup Utility) and lb-f5b from the CLI, and give both the same platform basics. Then I
plug both into the fabric: three untagged VLANs, self IPs with port lockdown, floating self IPs on lb-f5a, and a default route to the
fabric's anycast gateway. The switches then prove it: the right MACs on the right ports, ARP for the self IPs, and EVPN carrying both
BIG-IPs to a leaf that has no cable to them.

## Starting state

- The lab is up and `./validate.sh` passes (`validate: 36 PASS, 0 FAIL`): the end state of [Part 1](part01.md).
- Both BIG-IPs are blank and unlicensed, freshly booted (lb-f5a opens in the Setup Utility).
- You need **two registration keys of your own**, one per unit. Mine were evaluation keys ("Best" bundle, VE 1 Gbps), which license
  LTM, Advanced WAF, DNS, APM and AFM. This part only uses LTM.
- Units: lb-f5a (web UI, `https://172.21.32.43`) and lb-f5b (CLI).

The admin password of both BIG-IPs, on the lab server:

```bash
sudo sed -n 's/^PASSWORD=//p' /root/f5-clos-dc-secrets/lb-f5a.env
```

Bash on a BIG-IP, from the lab server: `ssh admin@clab-f5-clos-dc-lb-f5a` (or `-lb-f5b`). You land in bash as admin; `tmsh` commands
run from there.

## Values used in this part

| Object | lb-f5a | lb-f5b |
|---|---|---|
| Licensing | web UI, Setup Utility, Automatic | CLI, `SOAPLicenseClient` |
| Hostname | lb-f5a.f5lab.test | lb-f5b.f5lab.test |
| Time zone | UTC | UTC |
| NTP servers | 0.pool.ntp.org, 1.pool.ntp.org | same |
| DNS servers | 1.1.1.1, 8.8.8.8 | same |
| VLAN `external` | interface 1.1 untagged (leaf1a-service Ethernet3) | 1.1 untagged (leaf1a-service Ethernet4) |
| VLAN `internal` | interface 1.2 untagged (leaf1b-service Ethernet3) | 1.2 untagged (leaf1b-service Ethernet4) |
| VLAN `ha` | interface 1.3 untagged (direct cable) | 1.3 untagged |
| `self-external` | 10.20.30.11/24, Allow None, traffic-group-local-only | 10.20.30.12/24, same |
| `self-internal` | 10.20.0.241/24, Allow None, traffic-group-local-only | 10.20.0.242/24, same |
| `self-ha` | 192.168.255.1/30, Allow Default, traffic-group-local-only | 192.168.255.2/30, same |
| `float-external` | 10.20.30.10/24, Allow None, traffic-group-1 | none |
| `float-internal` | 10.20.0.240/24, Allow None, traffic-group-1 | none |
| Route `default-gw` | 0.0.0.0/0 via 10.20.30.1 | same |

The leaves put the untagged frames into VLAN 130 (external, 10.20.30.0/24, L2 VNI 10130) and VLAN 120 (internal, 10.20.0.0/24, the
servers' subnet). Both are in Vrf-App. 10.20.30.1 is the fabric's anycast gateway (MAC 00:00:5e:00:01:01).

## Steps

### 1. License lb-f5a in the web UI

Automatic activation sends the unit's dossier (the key plus the unit's identity) to F5's licence server out of the **management**
port and installs the signed licence it gets back. Installing a licence restarts the services: the web session drops.

In the web UI of lb-f5a (`https://172.21.32.43`), log in as `admin`. The Setup Utility opens.
1. Welcome page: **Next...**
2. License: **Activate**.
3. Base Registration Key: `<your-registration-key>`. Activation Method: **Automatic**. Outbound Interface: management (as shown).
   **Next...**
4. The EULA comes back from the licence server: **Accept**.
5. Wait. The page shows "BIG-IP system configuration has changed", then the login page: the services restarted to load the licence.
   In my run this took well under a minute.

You should see, after logging back in, the Setup Utility's License page with License type Evaluation, the licensed and expiration
dates, and the active modules. If a box about the interrupted connection appears, press **Continue**.

### 2. Finish the Setup Utility pages on lb-f5a

Still in the Setup Utility:
1. License page: **Next...**
2. Resource Provisioning: leave it as it is (Local Traffic is already Nominal). **Next...**
3. Device Certificates: keep the self-signed certificate. **Next...**
4. Platform: the management address, mask and route are already set. Host Name: `lb-f5a.f5lab.test`. Time Zone: `UTC`. The page
   also requires a new root password that passes the password policy.

Do not configure the network in the wizard: the network is built in step 5. In my run the Platform page refused the lab's root
password ("too simplistic"); the host name and the time zone were applied, and I closed the Setup Utility from the CLI in the next
step.

### 3. Platform basics on lb-f5a (CLI)

On lb-f5a (bash as admin). First a small filter that replaces anything shaped like a registration key (and the bundle identifier)
with X's; every command that could print the key goes through it.

```bash
mask() { sed -E 's/[A-Z0-9]{5}(-[A-Z0-9]{5}){3}-[A-Z0-9]{7}/XXXXX-XXXXX-XXXXX-XXXXX-XXXXXXX/g; s/[A-Z]{7}-[A-Z]{7}/XXXXXXX-XXXXXXX/g'; }
tmsh show sys license | mask | head -5
tmsh modify sys global-settings gui-setup disabled
tmsh modify sys ntp servers add { 0.pool.ntp.org 1.pool.ntp.org }
tmsh modify sys dns name-servers add { 1.1.1.1 8.8.8.8 }
tmsh list sys global-settings hostname gui-setup; tmsh list sys ntp; tmsh list sys dns
tmsh save sys config
```

`gui-setup disabled` ends the Setup Utility. You should see hostname `lb-f5a.f5lab.test`, `gui-setup disabled`, the two NTP servers
and the two DNS servers. If your host name or time zone did not stick on the Platform page, set them the way step 4 does on lb-f5b.

### 4. License lb-f5b from the CLI

The key never goes on a command line (it would land in the shell history and on screen). Put it in a file only admin can read, load
it into a variable, and delete the file in the same line.

On lb-f5b (bash as admin):

```bash
tmsh show sys license
```

You should see that the licence cannot be loaded (the same state lb-f5a was in).

```bash
mask() { sed -E 's/[A-Z0-9]{5}(-[A-Z0-9]{5}){3}-[A-Z0-9]{7}/XXXXX-XXXXX-XXXXX-XXXXX-XXXXXXX/g; s/[A-Z]{7}-[A-Z]{7}/XXXXXXX-XXXXXXX/g'; }
(umask 077; cat > /var/tmp/.regkey)
```

Paste `<your-registration-key>`, press Enter, then Ctrl-D. Then:

```bash
REGKEY=$(cat /var/tmp/.regkey); rm -f /var/tmp/.regkey; echo "key loaded: ${#REGKEY} characters"
get_dossier -b "$REGKEY" | cut -c1-72
SOAPLicenseClient --basekey "$REGKEY" 2>&1 | mask; echo "exit code $?"
```

You should see `key loaded: 31 characters` (27 characters plus 4 dashes), the start of the dossier (a long hexadecimal string), and
then the licence client's message that a new licence was installed. The note about F5's optional phone-home upload that follows does
not affect the licence. The exit code printed after a pipe is the `mask` filter's, not the licence client's: the evidence is the
message and the next two commands.

```bash
tmsh show sys license | mask | head -11
tmsh show sys license detail | mask | sed -n '/^Active Modules/,/^Optional/p' | head -16
```

You should see the masked registration key, the licensed date and the end date, and the same bundle as lb-f5a. Broadcast messages
from syslog (for example the SNMP daemon restarting) are the services restarting: expected.

Read the **Service Check Date** too: before a software upgrade, compare it with the new release's licence check date. If it is older,
reactivate the licence (same key, same unit) before upgrading, or the upgraded unit will not load its configuration.

### 5. Platform basics on lb-f5b

On lb-f5b (bash as admin):

```bash
tmsh modify sys global-settings hostname lb-f5b.f5lab.test gui-setup disabled
tmsh modify sys ntp timezone UTC servers add { 0.pool.ntp.org 1.pool.ntp.org }
tmsh modify sys dns name-servers add { 1.1.1.1 8.8.8.8 }
tmsh save sys config
```

### 6. Network on lb-f5a, in the web UI

In the web UI of lb-f5a (`https://172.21.32.43`), now with the normal menu:

VLANs (three times):
- **Network > VLANs > Create**: Name `external`; Interfaces: Interface `1.1`, Tagging `Untagged`, **Add**; **Finished**.
- **Network > VLANs > Create**: Name `internal`; Interface `1.2`, `Untagged`, **Add**; **Finished**.
- **Network > VLANs > Create**: Name `ha`; Interface `1.3`, `Untagged`, **Add**; **Finished**.

Self IPs (five times, **Network > Self IPs > Create**). For each: Name, IP Address, Netmask, VLAN / Tunnel, Port Lockdown, then untick
the "inherit traffic group" checkbox and pick the Traffic Group; **Finished**.

| Name | IP Address | Netmask | VLAN | Port Lockdown | Traffic Group |
|---|---|---|---|---|---|
| self-external | 10.20.30.11 | 255.255.255.0 | external | Allow None | traffic-group-local-only |
| self-internal | 10.20.0.241 | 255.255.255.0 | internal | Allow None | traffic-group-local-only |
| self-ha | 192.168.255.1 | 255.255.255.252 | ha | Allow Default | traffic-group-local-only |
| float-external | 10.20.30.10 | 255.255.255.0 | external | Allow None | traffic-group-1 |
| float-internal | 10.20.0.240 | 255.255.255.0 | internal | Allow None | traffic-group-1 |

The traffic group is the only difference between a self IP and a floating self IP in this form.

Default route:
- **Network > Routes > Add**: Name `default-gw`; Destination `0.0.0.0`; Netmask `0.0.0.0`; Gateway Address `10.20.30.1`;
  **Finished**.

You should see, in **Network > VLANs**, three VLANs with their interfaces, and in **Network > Self IPs**, five self IPs, two of them in
traffic-group-1.

Why the floating self IPs exist on lb-f5a only: without HA both units are standalone, and each one is active for traffic-group-1. With
10.20.30.10 on both, both would answer ARP for it (a duplicate address, and the leaf would flip between two MACs). Config sync brings
them to lb-f5b, with one active owner, when the pair is built (part 13).

### 7. Network on lb-f5b, in tmsh

The same design from tmsh, without floating self IPs. On lb-f5b (bash as admin):

```bash
tmsh create net vlan external interfaces add { 1.1 { untagged } }
tmsh create net vlan internal interfaces add { 1.2 { untagged } }
tmsh create net vlan ha interfaces add { 1.3 { untagged } }
tmsh create net self self-external address 10.20.30.12/24 vlan external allow-service none traffic-group traffic-group-local-only
tmsh create net self self-internal address 10.20.0.242/24 vlan internal allow-service none traffic-group traffic-group-local-only
tmsh create net self self-ha address 192.168.255.2/30 vlan ha allow-service default traffic-group traffic-group-local-only
tmsh create net route default-gw network default gw 10.20.30.1
tmsh list net self
tmsh show net interface | grep -E '^(Name|1\.)'
ping -c3 10.20.30.1; ping -c3 192.168.255.1
tmsh save sys config
```

You should see:
- three self IPs, each in traffic-group-local-only (`allow-service none` does not print: it is the default);
- interfaces 1.1, 1.2 and 1.3 `up` (before the VLANs existed they showed `uninit`);
- replies from the gateway 10.20.30.1 (the leaf) and from 192.168.255.1 (lb-f5a, across the HA cable).

### 8. Proof from the switches: MACs, ports and ARP

The switches are the witnesses. On the lab server (root, in the repo folder):

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show net vlan external' | grep -E 'Interface Name|Mac Address'
ssh admin@172.21.32.21 'sonic-cli -c "show mac address-table vlan 130"'
ssh admin@172.21.32.21 'sonic-cli -c "show interface status"' | grep -E '^Name|lb-f5'
ssh admin@172.21.32.21 'sonic-cli -c "show ip arp vrf Vrf-App"' | grep -E '^Address|10\.20\.30\.1[0-2] '
```

You should see, on leaf1a-service:
- lb-f5a's external MAC (the VLAN's MAC is its interface's MAC) learnt dynamically on **Ethernet3**, and lb-f5b's on **Ethernet4**;
  the two other entries are the sorry-server, learnt over VXLAN from both server leaves;
- Ethernet3 described as lb-f5a external 1.1, Ethernet4 as lb-f5b external 1.1;
- ARP in Vrf-App: 10.20.30.11 and the floating 10.20.30.10 both on lb-f5a's MAC through Ethernet3, 10.20.30.12 on lb-f5b's through
  Ethernet4. The floating address shares the unit's MAC (no MAC masquerade yet).

In my run lb-f5a's external MAC was aa:c1:ab:ed:0b:53; yours will differ.

### 9. Proof from a leaf with no cable to a BIG-IP: EVPN

VLAN 130 is stretched to the server leaves. Ask leaf2a-server. Use the last bytes of your two units' external MACs from step 8 (mine
were `ed:0b:53` for lb-f5a and `50:13:fb` for lb-f5b). On the lab server:

```bash
ssh admin@172.21.32.23 'hostname; sonic-cli -c "show mac address-table vlan 130"' | grep -E 'leaf|^VLAN|<lb-f5a-mac-end>|<lb-f5b-mac-end>'
ssh admin@172.21.32.23 'sudo vtysh -c "show evpn mac vni 10130"' | grep -E 'MAC|<lb-f5a-mac-end>|<lb-f5b-mac-end>'
ssh admin@172.21.32.23 'sudo vtysh -c "show bgp l2vpn evpn route type macip"' | grep -E 'Route Dist|<lb-f5a-mac-end>' | head -12
```

You should see both BIG-IP MACs on leaf2a with the interface shown as VXLAN towards 10.255.255.11 (leaf1a-service's VTEP); both
remote in VNI 10130; and EVPN type-2 routes with leaf1a-service's route distinguisher: one with the MAC only, others with MAC plus IP
(10.20.30.10 and 10.20.30.11), each twice (once through each spine).

### 10. Proof of port lockdown

On the lab server:

```bash
ssh admin@172.21.32.101 'ping -c3 10.20.0.241'
ssh admin@172.21.32.101 'curl -sk -m 5 -o /dev/null -w "%{http_code}\n" https://10.20.0.241/ || echo "no answer: port lockdown"'
ssh admin@clab-f5-clos-dc-lb-f5b 'curl -sk -m 5 -o /dev/null -w "HTTPS from lb-f5b to the HA self IP: %{http_code}\n" https://192.168.255.1/'
```

You should see: server1's ping to self-internal answered (Allow None still answers ICMP); HTTPS to it times out after 5 seconds
(`no answer: port lockdown`); HTTPS from lb-f5b to lb-f5a's HA self IP (Allow Default) answers `302`, the web UI's redirect.

## Verify

- `tmsh show sys license` on both units: licensed, the same bundle, an end date.
- `tmsh list net self` on lb-f5a: five self IPs (two in traffic-group-1); on lb-f5b: three.
- `ping -c3 10.20.30.1; ping -c3 192.168.255.1` from lb-f5b: both answer (and 192.168.255.2 from lb-f5a).
- What I measured: leaf1a-service learnt lb-f5a's external MAC on Ethernet3 and lb-f5b's on Ethernet4; ARP for .10 and .11 pointed
  at lb-f5a's MAC; leaf2a-server learnt both MACs by EVPN type-2 from VTEP 10.255.255.11; server1 pings 10.20.0.241 but gets no HTTPS
  answer; the HA self IP answers 302.

## Gotchas

- Automatic activation worked with no DNS server configured on the BIG-IP (no nameserver in `/etc/resolv.conf`): internet access over
  the management default route was enough.
- Licensing restarts the services: the web session drops to the login page, SSH sessions get broadcast messages. Never license or
  re-license a unit that carries traffic.
- The Setup Utility's Platform page refused my lab's root password ("too simplistic"). Host name and time zone were applied; I closed
  the wizard with `tmsh modify sys global-settings gui-setup disabled` and kept the lab passwords.
- `echo $?` after `SOAPLicenseClient ... | mask` prints the exit code of `mask`, not of the licence client.
- No floating self IPs on lb-f5b while the units are standalone: both would own them (duplicate address).
- Each BIG-IP arm is one cable to one leaf (BIG-IP VE has no LACP), so a leaf failure takes that arm off **both** units at once. The
  fix in this lab is routing: eBGP to both leaves with BFD (part 14).
- An untagged VLAN still gets an internal tag inside the BIG-IP (external got 4094 in my run); it never goes on the wire. The VLAN MTU
  is 1500 while the fabric allows 9100: the smaller side decides.
- **Licences and `./down.sh`:** an evaluation key bound to a deleted VM is lost. Before destroying the lab, revoke each unit's licence
  (web UI: **System > License > Revoke**, or `tmsh revoke sys license`), then run `./down.sh --licences-revoked`. `./down.sh`
  without the flag refuses while a BIG-IP holds a licence.

## End state

- Both units licensed, hostnames lb-f5a.f5lab.test / lb-f5b.f5lab.test, time zone UTC, NTP 0/1.pool.ntp.org, DNS 1.1.1.1 / 8.8.8.8,
  Setup Utility disabled, config saved.
- lb-f5a: VLANs `external` (1.1), `internal` (1.2), `ha` (1.3); self IPs `self-external` 10.20.30.11, `self-internal` 10.20.0.241,
  `self-ha` 192.168.255.1, `float-external` 10.20.30.10, `float-internal` 10.20.0.240; route `default-gw` via 10.20.30.1.
- lb-f5b: the same VLANs; `self-external` 10.20.30.12, `self-internal` 10.20.0.242, `self-ha` 192.168.255.2; route `default-gw`.

Save it (on the lab server, in the repo folder):

```bash
./f5-save.sh
```

One UCS per unit lands in `/root/f5-clos-dc-secrets/ucs/`. `./f5-restore.sh <unit> <file.ucs>` loads it back with `no-license`, so the
unit keeps the licence you activated on it.

## Reset

To go back to the network-less state (licences and platform basics kept), on each unit (bash as admin), in dependency order. On
lb-f5b skip the two `float-` lines.

```bash
tmsh delete net route default-gw
tmsh delete net self float-external
tmsh delete net self float-internal
tmsh delete net self self-external
tmsh delete net self self-internal
tmsh delete net self self-ha
tmsh delete net vlan external
tmsh delete net vlan internal
tmsh delete net vlan ha
tmsh save sys config
```

To go back to an unlicensed unit, revoke the licence (web UI: **System > License > Revoke**).

## Files used

None from `demo/`. Lab scripts: `f5-save.sh`, `f5-restore.sh`, `down.sh`.

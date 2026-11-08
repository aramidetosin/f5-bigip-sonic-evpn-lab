#!/usr/bin/env python3
"""gen.py: the single source of the lab. Every name, address, VLAN and AS number lives here; the outputs are generated,
never edited by hand. Run it from this folder (python3 gen.py) after any change. It writes:
  f5-clos-dc.clab.yml      the whole containerlab topology
  mgmt-hosts.txt           the management addresses (<ip> <node> <group>)
  configs/<switch>.cli     one Dell SONiC (sonic-cli) command per line, applied by sonic-apply.sh
  bootstrap/fw-pa.xml      the PA-VM configuration, loaded by pa-load.sh (import + partial replace + commit)

One cabling and one switch / firewall configuration serve two designs, chosen by how you configure the BIG-IPs:
  basic     course-style two-arm: BIG-IP 1.1 = VLAN 130 untagged (leaf1a-service), 1.2 = VLAN 120 untagged (leaf1b-service);
            virtual servers in 10.20.30.0/24, no routing protocol on the BIG-IP
  advanced  1.1 / 1.2 also carry tagged transits (VLAN 3005 / 3007); eBGP from the BIG-IPs to the service leaves, virtual
            server /32s in 10.20.5.0/24 advertised only while their pool is up (route health injection)
"""
import json, os

LAB = "f5-clos-dc"
MGMT = "172.21.32"
LAN_IF = "pnet0"
SECRETS = "/root/f5-clos-dc-secrets"
MODES = ("basic", "advanced")

IMG_SONIC = "vrnetlab/dell_sonic:4.6.0"
IMG_PA = "vrnetlab/paloalto_pa-vm:12.1.2"
IMG_F5 = "vrnetlab/f5_bigip-ve:17.5.1.11-0.0.12"
IMG_HOST = "scd/host:1"
IMG_WEB = "f5lab/web:1"                  # servers, sorry-server: images/web/Dockerfile (nginx, http + https)
IMG_TOOLS = "f5lab/tools:1"              # log-server: images/tools/Dockerfile (rsyslog, net-snmp)
IMG_PC = "f5lab/pc:1"
PC_WEB_PORTS = (3000, 3001)
PC_PUBLISH = {"pc1": (3110, 3111), "pc2": (3120, 3121), "pc3": (3130, 3131)}
BUILD_IMAGES = {IMG_HOST: "images/host", IMG_WEB: "images/web", IMG_TOOLS: "images/tools", IMG_PC: "images/pc"}

SPINES = ["spine1", "spine2"]
SPINE_ASN = 65000
PAIRS = {   # pair: (leaves, ASN, pair id for system-MAC / ESI); a leaf's name carries its pair number and its role
    "service": (["leaf1a-service", "leaf1b-service"], 65001, 1),
    "server":  (["leaf2a-server", "leaf2b-server"], 65002, 2),
    "border":  (["leaf3a-border", "leaf3b-border"], 65003, 3),
}
ROLE_TEXT = {"service": "firewall + load balancers", "server": "servers", "border": "external users (client LAN)"}
LEAVES = [l for p in PAIRS.values() for l in p[0]]      # spine ethN = LEAVES[N-1]; leaf eth1 = spine1, eth2 = spine2
SWITCH_MGMT = dict(zip(SPINES, (11, 12)))
SWITCH_MGMT.update(zip(LEAVES, range(21, 27)))
LOOP_OCTET = dict(zip(SPINES, (1, 2)))
LOOP_OCTET.update(zip(LEAVES, (11, 12, 21, 22, 31, 32)))
LOOP = {n: "10.255.255.%d" % o for n, o in LOOP_OCTET.items()}   # Loopback0 = router-id = VTEP
ANYMAC = "00:00:5e:00:01:01"
NUM_NICS = 8
LEAF_MEMORY = "6144"
ES_ACTIVATION_MS = 3000

VRFS = {"Vrf-Outside": (50001, 1501), "Vrf-App": (50002, 1502)}         # L3VNI, its VLAN
VLANS = {   # VLAN: (VRF, anycast gateway, description, the pairs that carry it); L2VNI = 10000 + VLAN
    110: ("Vrf-Outside", "10.10.0.1/24", "outside-clients", ["border"]),
    120: ("Vrf-App", "10.20.0.1/24", "app-servers", ["server", "service"]),     # basic: also the BIG-IPs' internal VLAN (1.2 untagged)
    130: ("Vrf-App", "10.20.30.1/24", "lb-external", ["service", "server"]),    # basic: the BIG-IPs' external VLAN (1.1 untagged), VIPs, sorry-server
}
VLAN_DESC = {1501: "l3vni-outside", 1502: "l3vni-app"}
VLAN_DESC.update({v: d[2] for v, d in VLANS.items()})

FW, FW_ASN, FW_MGMT, FW_PORT, FW_PO = "fw-pa", 65500, 40, "eth3", 10
FW_VR = "vr-main"
PUBLISHED = [("10.20.30.0/24", True), ("10.20.5.0/24", False)]
CLIENTS = [("10.10.0.0/24", True)]
TRANSITS = [
    (3001, "10.254.1", "Vrf-Outside", "outside", "fw-transit-outside", CLIENTS, PUBLISHED),
    (3002, "10.254.2", "Vrf-App", "app", "fw-transit-app", PUBLISHED, CLIENTS),
]
for _t in TRANSITS:
    VLAN_DESC[_t[0]] = _t[4]

F5_HA_NET, F5_HA_PORT = "192.168.255.0/30", "eth3"
# unit: (port on BOTH service leaves, management octet, HA address, basic external self, basic internal self, advanced transit octet)
F5 = {"lb-f5a": ("eth4", 43, "192.168.255.1", "10.20.30.11", "10.20.0.241", 3),
      "lb-f5b": ("eth5", 44, "192.168.255.2", "10.20.30.12", "10.20.0.242", 4)}
BASIC = {   # (leaf, untagged VLAN on the BIG-IP ports, BIG-IP interface, floating self IP)
    "external": ("leaf1a-service", 130, "1.1", "10.20.30.10"),
    "internal": ("leaf1b-service", 120, "1.2", "10.20.0.240"),
    "vips": "10.20.30.100-.199", "vip": "10.20.30.100",
}
ADVANCED = {
    "transit": {"leaf1a-service": ("10.254.5", 3005, "1.1"), "leaf1b-service": ("10.254.7", 3007, "1.2")},
    "asn": 65020, "vips": "10.20.5.0/24 (a /32 each)", "vip": "10.20.5.10",
}
for _t, (_net, _vl, _i) in ADVANCED["transit"].items():
    VLAN_DESC[_vl] = "lb-transit-app-%s" % _t.split("-")[0]

# ---------------------------------------------------------------- servers, tools, users
# hosts on the server pair: (port on both server leaves, VLAN, address, gateway, PortChannel, mgmt octet, image, startup script, role)
APP_HOSTS = {
    "server1": ("eth3", 120, "10.20.0.11", "10.20.0.1", 21, 101, IMG_WEB, "server-up.sh", "web"),
    "server2": ("eth4", 120, "10.20.0.12", "10.20.0.1", 22, 102, IMG_WEB, "server-up.sh", "web"),
    "server3": ("eth5", 120, "10.20.0.13", "10.20.0.1", 23, 103, IMG_WEB, "server-up.sh", "web"),
    "log-server": ("eth6", 120, "10.20.0.20", "10.20.0.1", 24, 104, IMG_TOOLS, "tools-up.sh", "syslog + snmp"),
    "sorry-server": ("eth7", 130, "10.20.30.30", "10.20.30.1", 25, 105, IMG_WEB, "server-up.sh", "sorry"),
}
SERVERS = [n for n, v in APP_HOSTS.items() if v[8] == "web"]
WHOAMI_COLORS = {"server1": ("#1971c2", "blue"), "server2": ("#2f9e44", "green"), "server3": ("#e8590c", "orange"),
                 "sorry-server": ("#c92a2a", "red")}
LAN_SWITCH = ("lan-switch", "eth3", "10.10.0.5", 30, 110)
PCS = {"pc1": ("eth3", "10.10.0.11", 111), "pc2": ("eth4", "10.10.0.12", 112), "pc3": ("eth5", "10.10.0.13", 113)}
TLS_NAMES = ["app.f5lab.test", "sorry.f5lab.test"] + ["%s.f5lab.test" % s for s in SERVERS]
API = {"name": "api.f5lab.test", "vip": "10.20.30.101", "port": 8080, "base": "/api/v1",
       "undocumented": ["/api/v1/admin/users", "DELETE /api/v1/items/{id}"]}

GSLB = {"zone": "gslb.f5lab.test", "wideip": "app.gslb.f5lab.test", "resolver": ("lan-switch", "10.10.0.5"),
        "sites": {"lb-f5a": ("site-a", "10.20.5.0/25", "10.20.5.10", "10.20.5.53"),
                  "lb-f5b": ("site-b", "10.20.5.128/25", "10.20.5.140", "10.20.5.153")}}   # unit: (name, range, app VIP, DNS listener)

def openapi(version="1.0.0"):
    """The API's OpenAPI 3.0.3 description (shared/openapi-f5lab-api.json): the positive-security model for part 17.
    1.1.0 (shared/openapi-f5lab-api-v1.1.json) adds GET /version: the release that ships before its description is imported."""
    item = {"type": "object", "additionalProperties": False, "required": ["name", "qty"],
            "properties": {"name": {"type": "string", "minLength": 1, "maxLength": 40},
                           "qty": {"type": "integer", "minimum": 1, "maximum": 100}}}
    ok = lambda d, ref=None: {"description": d, "content": {"application/json": {"schema": {"$ref": ref} if ref else {"type": "object"}}}}
    idp = {"name": "id", "in": "path", "required": True, "schema": {"type": "integer", "minimum": 1, "maximum": 9999}}
    return {"openapi": "3.0.3",
            "info": {"title": "f5lab items API", "version": version, "description": "The part 17 test API on server1-3"},
            "servers": [{"url": "http://%s%s" % (API["name"], API["base"])}],
            "paths": {
                "/health": {"get": {"operationId": "health", "responses": {"200": ok("up")}}},
                "/items": {"get": {"operationId": "listItems", "responses": {"200": ok("all items")}},
                           "post": {"operationId": "createItem",
                                    "requestBody": {"required": True, "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Item"}}}},
                                    "responses": {"201": ok("created")}}},
                "/items/{id}": {"get": {"operationId": "getItem", "parameters": [idp], "responses": {"200": ok("one item", "#/components/schemas/Item")}}},
                **({"/version": {"get": {"operationId": "version", "responses": {"200": ok("the API release")}}}} if version >= "1.1" else {})},
            "components": {"schemas": {"Item": item}}}


def eth_to_sonic(port):   # clab ethN -> EthernetN-1 (Dell SONiC native naming)
    return "Ethernet%d" % (int(port[3:]) - 1)


def pair_of(sw):
    for p, (leaves, asn, pid) in PAIRS.items():
        if sw in leaves:
            return p, asn, pid
    raise KeyError(sw)


def esi_ports(pair):
    """[(member port, PortChannel, untagged VLAN or None, tagged VLANs, host name)]: '<host>-lag' / '<host>-lag-member'"""
    if pair == "service":
        return [(FW_PORT, FW_PO, None, [t[0] for t in TRANSITS], FW)]
    if pair == "server":
        return [(v[0], v[4], v[1], [], n) for n, v in APP_HOSTS.items()]
    return [(LAN_SWITCH[1], LAN_SWITCH[3], LAN_SWITCH[4], [], LAN_SWITCH[0])]


def pair_vlans(pair):
    return sorted(v for v, d in VLANS.items() if pair in d[3])


def pair_vrfs(pair):
    vrfs = {VLANS[v][0] for v in pair_vlans(pair)}
    if pair == "service":
        vrfs |= {t[2] for t in TRANSITS}
    return sorted(vrfs)


def sonic_cli(sw):
    """eBGP unnumbered underlay, EVPN, symmetric IRB, ESI-LAG."""
    c = ["configure terminal", "interface Loopback 0", "ip address %s/32" % LOOP[sw], "exit"]
    uplinks = ["Ethernet%d" % i for i in range(len(LEAVES))] if sw in SPINES else ["Ethernet%d" % i for i in range(len(SPINES))]
    peers = LEAVES if sw in SPINES else SPINES
    for p, peer in zip(uplinks, peers):
        c += ["interface %s" % p, "description %s-%s" % ("downlink" if sw in SPINES else "uplink", peer),
              "no shutdown", "mtu 9100", "ipv6 enable", "no ipv6 nd suppress-ra", "ipv6 nd ra-interval 5", "exit"]
    vrfs = []
    if sw in SPINES:
        asn = SPINE_ASN
    else:
        pair, asn, pid = pair_of(sw)
        service = pair == "service"
        vrfs = pair_vrfs(pair)
        f5net, f5vl, _i = ADVANCED["transit"][sw] if service else (None, None, None)
        l2 = pair_vlans(pair) + ([t[0] for t in TRANSITS] if service else [])   # transits: L2VNIs between the two service leaves (sonic F2)
        c += ["ip anycast-mac-address %s" % ANYMAC] + ["ip vrf %s" % v for v in vrfs]
        c += ["evpn esi-multihoming", "es-activation-delay %d" % ES_ACTIVATION_MS, "exit"]
        for v in vrfs:
            c += ["interface Vlan%d" % VRFS[v][1], "description %s" % VLAN_DESC[VRFS[v][1]], "ip vrf forwarding %s" % v, "exit"]
        for v in pair_vlans(pair):
            vrf, gw, _d, _p = VLANS[v]
            c += ["interface Vlan%d" % v, "description %s" % VLAN_DESC[v], "ip vrf forwarding %s" % vrf, "mtu 9100",
                  "ip anycast-address %s" % gw, "exit"]
        if service:
            idx = PAIRS["service"][0].index(sw) + 1
            for tv, net, vrf, *_ in TRANSITS:
                c += ["interface Vlan%d" % tv, "description %s" % VLAN_DESC[tv], "ip vrf forwarding %s" % vrf, "ip address %s.%d/29" % (net, idx), "exit"]
            # advanced: this leaf's own transit to the BIG-IP pair (tagged, local, not stretched); basic: the untagged VLAN of this leaf's arm
            c += ["interface Vlan%d" % f5vl, "description %s" % VLAN_DESC[f5vl], "ip vrf forwarding Vrf-App", "ip address %s.1/29" % f5net, "exit"]
            arm = next(a for a in ("external", "internal") if BASIC[a][0] == sw)
            for unit, v in F5.items():
                c += ["interface %s" % eth_to_sonic(v[0]), "description %s-%s-%s" % (unit, arm, BASIC[arm][2]), "mtu 9100",
                      "switchport access Vlan %d" % BASIC[arm][1], "switchport trunk allowed Vlan %d" % f5vl, "no shutdown", "exit"]
        for port, po, untagged, tagged, desc in esi_ports(pair):
            c += ["interface PortChannel%d fast_rate" % po, "description %s-lag" % desc, "mtu 9100"]
            c += ["switchport access Vlan %d" % untagged] if untagged else []
            c += ["switchport trunk allowed Vlan %s" % ",".join(map(str, tagged))] if tagged else []
            c += ["system-mac 02:00:00:%02x:00:%02x" % (pid, po), "no shutdown",
                  "evpn ethernet-segment 00:00:00:00:00:00:00:00:%02x:%02x" % (pid, po), "exit", "exit"]
            c += ["interface %s" % eth_to_sonic(port), "description %s-lag-member" % desc, "mtu 9100", "channel-group %d" % po, "no shutdown", "exit"]
        c += ["interface vxlan vtep1", "source-ip %s" % LOOP[sw], "qos-mode pipe dscp 0"]
        c += ["map vni %d vlan %d" % (10000 + v, v) for v in l2]
        for v in vrfs:
            c += ["map vni %d vlan %d" % VRFS[v], "map vni %d vrf %s" % (VRFS[v][0], v)]
        c += ["exit"]
    c += ["router bgp %d" % asn, "router-id %s" % LOOP[sw], "log-neighbor-changes", "timers 3 9",
          "address-family ipv4 unicast", "maximum-paths 8", "network %s/32" % LOOP[sw], "exit", "address-family l2vpn evpn"]
    c += [] if sw in SPINES else ["advertise-all-vni"]
    c += ["exit"]
    for p in uplinks:
        c += ["neighbor interface %s" % p, "v6only", "remote-as external", "capability extended-nexthop", "address-family ipv4 unicast", "activate"]
        c += [] if sw in SPINES else ["allowas-in 1"]
        c += ["exit", "address-family l2vpn evpn", "activate"] + ([] if sw in SPINES else ["allowas-in 1"]) + ["exit", "exit"]
    c += ["exit"]
    for v in vrfs:
        c += ["router bgp %d vrf %s" % (asn, v), "router-id %s" % LOOP[sw], "log-neighbor-changes",
              "address-family ipv4 unicast", "redistribute connected", "maximum-paths 8", "exit",
              "address-family l2vpn evpn", "advertise ipv4 unicast", "exit"]
        if pair_of(sw)[0] == "service":
            for tv, net, vrf, *_ in TRANSITS:
                if vrf == v:
                    c += ["neighbor %s.3" % net, "remote-as %d" % FW_ASN, "timers 3 9", "address-family ipv4 unicast", "activate", "allowas-in 1", "exit", "exit"]
            if v == "Vrf-App":
                f5net = ADVANCED["transit"][sw][0]
                for unit, u in F5.items():
                    c += ["neighbor %s.%d" % (f5net, u[5]), "remote-as %d" % ADVANCED["asn"], "timers 3 9", "bfd", "address-family ipv4 unicast", "activate", "exit", "exit"]
        c += ["exit"]
    return c + ["end", "write memory"]


def fw_xml():
    """ae1 (LACP) with one unit per transit, one virtual router, eBGP per transit with narrow
    import / export rules, zones per transit, default deny + log. No NAT: the users' addresses reach the BIG-IP unchanged."""
    E = lambda n, body="": "<entry name=\"%s\">%s</entry>" % (n, body)
    M = lambda *xs: "".join("<member>%s</member>" % x for x in xs)
    allow, deny = "<action><allow/></action><enable>yes</enable>", "<action><deny/></action><enable>yes</enable>"
    mss = "<adjust-tcp-mss><enable>yes</enable><ipv4-mss-adjustment>40</ipv4-mss-adjustment></adjust-tcp-mss>"
    units = "".join(E("ae1.%d" % tv, "<tag>%d</tag><ip>%s</ip><interface-management-profile>allow-ping</interface-management-profile>%s" % (tv, E("%s.3/29" % net), mss))
                    for tv, net, *_ in TRANSITS)
    eths = E("ethernet1/1", "<aggregate-group>ae1</aggregate-group>") + E("ethernet1/2", "<aggregate-group>ae1</aggregate-group>")
    ifs = "<ethernet>%s</ethernet><aggregate-ethernet>%s</aggregate-ethernet>" % (
        eths, E("ae1", "<layer3><lacp><enable>yes</enable><mode>active</mode><transmission-rate>fast</transmission-rate></lacp><units>%s</units></layer3>" % units))
    groups = imp = exp = ""
    leaves = PAIRS["service"][0]
    for tv, net, vrf, zone, _d, accepts, sends in TRANSITS:
        g = "main-%s" % vrf.lower()           # e.g. main-vrf-app (PAN-OS: BGP policy rule names <= 31 characters)
        peers = "".join(E("%s-%s" % (g, l.split("-")[0]), "<peer-as>%d</peer-as><enable>yes</enable><enable-sender-side-loop-detection>no</enable-sender-side-loop-detection><local-address><interface>ae1.%d</interface>"
                          "<ip>%s.3/29</ip></local-address><peer-address><ip>%s.%d</ip></peer-address>" % (PAIRS["service"][1], tv, net, net, i))
                        for i, l in enumerate(leaves, 1))
        groups += E(g, "<type><ebgp><remove-private-as>yes</remove-private-as><import-nexthop>original</import-nexthop><export-nexthop>resolve</export-nexthop></ebgp></type>"
                    "<enable>yes</enable><peer>%s</peer>" % peers)
        imp += "".join(E("%s-import-%d" % (g, k), "<used-by>%s</used-by><match><address-prefix>%s</address-prefix></match>%s"
                         % (M(g), E(p, "<exact>%s</exact>" % ("yes" if ex else "no")), allow)) for k, (p, ex) in enumerate(accepts))
        imp += E("%s-import-deny" % g, "<used-by>%s</used-by>%s" % (M(g), deny))
        exp += "".join(E("%s-export-%d" % (g, k), "<used-by>%s</used-by><match><address-prefix>%s</address-prefix></match>%s"
                         % (M(g), E(p, "<exact>%s</exact>" % ("yes" if ex else "no")), allow)) for k, (p, ex) in enumerate(sends))
        exp += E("%s-export-deny" % g, "<used-by>%s</used-by>%s" % (M(g), deny))
    bgp = ("<protocol><bgp><enable>yes</enable><router-id>%s.3</router-id><local-as>%d</local-as><install-route>yes</install-route>"
           "<policy><import><rules>%s</rules></import><export><rules>%s</rules></export></policy><peer-group>%s</peer-group></bgp></protocol>") % (
        TRANSITS[0][1], FW_ASN, imp, exp, groups)
    vrs = E(FW_VR, "<interface>%s</interface>%s" % (M(*["ae1.%d" % t[0] for t in TRANSITS]), bgp))
    zones = "".join(E(t[3], "<network><layer3>%s</layer3></network>" % M("ae1.%d" % t[0])) for t in TRANSITS)
    svc = E("web", "<protocol><tcp><port>80,443</port></tcp></protocol>")
    svc += E("dns-udp", "<protocol><udp><port>53</port></udp></protocol>") + E("dns-tcp", "<protocol><tcp><port>53</port></tcp></protocol>")
    addrs = "".join(E("published-%d" % k, "<ip-netmask>%s</ip-netmask>" % p) for k, (p, _x) in enumerate(PUBLISHED)) + \
        E("clients", "<ip-netmask>%s</ip-netmask>" % CLIENTS[0][0])

    def rule(name, fz, tz, src, dst, apps, svcs, action="allow", extra=""):
        return E(name, "<from>%s</from><to>%s</to><source>%s</source><destination>%s</destination><application>%s</application><service>%s</service>"
                 "<action>%s</action>%s<log-end>yes</log-end>" % (M(*fz), M(*tz), M(*src), M(*dst), M(*apps), M(*svcs), action, extra))
    pub = ["published-%d" % k for k in range(len(PUBLISHED))]
    sec = rule("clients-to-published-web", ["outside"], ["app"], ["clients"], pub, ["any"], ["web"])
    sec += rule("clients-to-published-ping", ["outside"], ["app"], ["clients"], pub, ["ping"], ["application-default"])
    sec += rule("clients-to-published-dns", ["outside"], ["app"], ["clients"], pub, ["any"], ["dns-udp", "dns-tcp"])
    sec += rule("allow-intrazone", ["any"], ["any"], ["any"], ["any"], ["any"], ["any"], extra="<rule-type>intrazone</rule-type>")
    sec += rule("deny-all-log", ["any"], ["any"], ["any"], ["any"], ["any"], ["any"], "deny", "<rule-type>interzone</rule-type>")
    allif = ["ae1.%d" % t[0] for t in TRANSITS]
    return ("<config version=\"12.1.0\" urldb=\"paloaltonetworks\" detail-version=\"12.1.2\"><devices><entry name=\"localhost.localdomain\"><network>"
            "<profiles><interface-management-profile>%s</interface-management-profile></profiles><interface>%s</interface>"
            "<virtual-router>%s</virtual-router></network>"
            "<deviceconfig><system><hostname>%s</hostname><timezone>UTC</timezone></system></deviceconfig>"
            "<vsys><entry name=\"vsys1\"><import><network><interface>%s</interface></network></import><zone>%s</zone><service>%s</service>"
            "<address>%s</address><rulebase><security><rules>%s</rules></security></rulebase></entry></vsys>"
            "</entry></devices></config>\n") % (E("allow-ping", "<ping>yes</ping>"), ifs, vrs, FW, M(*allif), zones, svc, addrs, sec)


def links():
    """Every cable: (a, a port, b, b port, kind). The same for both topologies."""
    L = []
    for si, s in enumerate(SPINES):
        for li, l in enumerate(LEAVES):
            L.append((s, "eth%d" % (li + 1), l, "eth%d" % (si + 1), "underlay"))
    sa, sb = PAIRS["service"][0]
    L += [(sa, FW_PORT, FW, "eth1", "fw"), (sb, FW_PORT, FW, "eth2", "fw")]
    for u, v in F5.items():
        L += [(sa, v[0], u, "eth1", "f5"), (sb, v[0], u, "eth2", "f5")]
    L.append(("lb-f5a", F5_HA_PORT, "lb-f5b", F5_HA_PORT, "f5-ha"))
    va, vb = PAIRS["server"][0]
    for n, v in APP_HOSTS.items():
        L += [(va, v[0], n, "eth1", "esi"), (vb, v[0], n, "eth2", "esi")]
    ba, bb = PAIRS["border"][0]
    sw, port = LAN_SWITCH[0], LAN_SWITCH[1]
    L += [(ba, port, sw, "eth1", "esi"), (bb, port, sw, "eth2", "esi")]
    for n, (swport, _ip, _m) in PCS.items():
        L.append((sw, swport, n, "eth1", "lan"))
    return L


def clab():
    y = ["# %s (generated by gen.py, do not edit). One cabling and one fabric config for both topologies (basic / advanced)." % LAB,
         "name: %s" % LAB,
         "mgmt:", "  network: clab-%s" % LAB, "  ipv4-subnet: %s.0/24" % MGMT,
         "topology:", "  kinds:",
         "    dell_sonic:", "      image: %s" % IMG_SONIC, "      env:", "        NUM_NICS: %d" % NUM_NICS,
         "    paloalto_panos:", "      image: %s" % IMG_PA, "      env:", "        QEMU_CPU: host", "        QEMU_MEMORY: 8192",
         "    f5_bigip-ve:", "      image: %s" % IMG_F5, "      env:", '        QEMU_MEMORY: "16384"', '        QEMU_SMP: "4"',
         "    linux:", "      image: %s" % IMG_HOST, "      binds:", "        - shared:/shared:ro",
         "        - %s/host.env:/run/f5lab/host.env:ro" % SECRETS, "        - %s/authorized_keys:/run/f5lab/authorized_keys:ro" % SECRETS,
         "  nodes:"]
    for s in SPINES:
        y.append("    %s: {kind: dell_sonic, mgmt-ipv4: %s.%d, group: fabric}" % (s, MGMT, SWITCH_MGMT[s]))
    for l in LEAVES:
        y.append('    %s: {kind: dell_sonic, mgmt-ipv4: %s.%d, group: fabric, env: {QEMU_MEMORY: "%s"}}' % (l, MGMT, SWITCH_MGMT[l], LEAF_MEMORY))
    y.append("    %s: {kind: paloalto_panos, mgmt-ipv4: %s.%d, group: firewall, binds: [images/pa-launch/launch.py:/launch.py:ro]}"
             % (FW, MGMT, FW_MGMT))
    for u, v in F5.items():
        y += ["    %s:" % u, "      kind: f5_bigip-ve", "      mgmt-ipv4: %s.%d" % (MGMT, v[1]), "      group: load-balancers",
              "      env-files:", "        - %s/%s.env" % (SECRETS, u)]

    def host(name, m, group, env, script, image=None, binds=(), env_files=(), shm=None, ports=()):
        out = ["    %s:" % name, "      kind: linux"] + (["      image: %s" % image] if image and image != IMG_HOST else [])
        out += ["      mgmt-ipv4: %s.%d" % (MGMT, m), "      group: %s" % group]
        out += ["      shm-size: %s" % shm] if shm else []
        out += ["      ports:"] + ['        - "%s"' % p for p in ports] if ports else []
        out += ["      env-files:"] + ["        - %s" % f for f in env_files] if env_files else []
        if binds:   # a node's own binds replace the kind's: repeat the kind's two
            out += ["      binds:", "        - shared:/shared:ro", "        - %s/host.env:/run/f5lab/host.env:ro" % SECRETS,
                    "        - %s/authorized_keys:/run/f5lab/authorized_keys:ro" % SECRETS] + ["        - %s" % b for b in binds]
        out += ["      env:"] + ['        %s: "%s"' % kv for kv in env]
        return out + ["      exec:", "        - bash /shared/%s" % script]

    for n, (_p, _vl, ip, gw, _po, m, img, script, role) in APP_HOSTS.items():
        env = [("IP", ip + "/24"), ("GW", gw), ("BOND", "1")] + ([("ROLE", role)] if img == IMG_WEB else [])
        binds = ["%s/tls:/run/f5lab/tls:ro" % SECRETS] if img == IMG_WEB else []
        y += host(n, m, "servers" if img == IMG_WEB else "tools", env, script, img, binds)
    sw, _p, ip, _po, m = LAN_SWITCH
    y += host(sw, m, "lan", [("IP", ip + "/24"), ("GW", "10.10.0.1"), ("BOND", "1"), ("BRIDGE", " ".join(p for p, _i, _m in PCS.values()))], "host-up.sh")
    for n, (_p, ip, m) in PCS.items():
        y += host(n, m, "lan", [("IP", ip + "/24"), ("GW", "10.10.0.1"), ("TZ", "Etc/UTC")], "pc-up.sh", IMG_PC,
                  binds=["%s/tls/ca.crt:/run/f5lab/ca.crt:ro" % SECRETS], env_files=["%s/pc.env" % SECRETS], shm="1gb",
                  ports=["127.0.0.1:%d:%d" % (hp, cp) for hp, cp in zip(PC_PUBLISH[n], PC_WEB_PORTS)])
    y.append("  links:")
    for a, ap, b, bp, _k in links():
        y.append('    - endpoints: ["%s:%s", "%s:%s"]' % (a, ap, b, bp))
    return "\n".join(y) + "\n"


def mgmt_hosts():
    rows = [(SWITCH_MGMT[n], n, "fabric") for n in SPINES + LEAVES] + [(FW_MGMT, FW, "firewall")]
    rows += [(v[1], u, "load-balancers") for u, v in F5.items()]
    rows += [(v[5], n, "servers" if v[6] == IMG_WEB else "tools") for n, v in APP_HOSTS.items()] + [(LAN_SWITCH[4], LAN_SWITCH[0], "lan")]
    rows += [(v[2], n, "lan") for n, v in PCS.items()]
    return "".join("%s.%d %s %s\n" % (MGMT, o, n, g) for o, n, g in sorted(rows))


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    os.chdir(here)
    os.makedirs("configs", exist_ok=True); os.makedirs("bootstrap", exist_ok=True)
    open("%s.clab.yml" % LAB, "w").write(clab())
    open("mgmt-hosts.txt", "w").write(mgmt_hosts())
    for sw in SPINES + LEAVES:
        open("configs/%s.cli" % sw, "w").write("\n".join(sonic_cli(sw)) + "\n")
    open("bootstrap/fw-pa.xml", "w").write(fw_xml())
    open("shared/whoami-colors.txt", "w").write("".join("%s %s %s\n" % (n, c, w) for n, (c, w) in WHOAMI_COLORS.items()))
    open("shared/gslb-values.sh", "w").write("# generated by gen.py (GSLB): parts 18-19\nGSLB_ZONE=%s\nGSLB_WIDEIP=%s\nRESOLVER_HOST=%s\nRESOLVER_IP=%s\n"
        % (GSLB["zone"], GSLB["wideip"], GSLB["resolver"][0], GSLB["resolver"][1])
        + "".join("SITE_%s=\"%s %s %s %s\"\n" % (u.replace("-", "_").upper(), *v) for u, v in GSLB["sites"].items())
        + "GSLB_LISTENERS=\"%s\"\n" % " ".join(v[3] for v in GSLB["sites"].values()))
    open("shared/api-values.sh", "w").write("# generated by gen.py (API): part 17's test API\nAPI_NAME=%s\nAPI_VIP=%s\nAPI_PORT=%d\nAPI_BASE=%s\n"
                                         % (API["name"], API["vip"], API["port"], API["base"]))
    open("shared/openapi-f5lab-api.json", "w").write(json.dumps(openapi(), indent=2) + "\n")
    open("shared/openapi-f5lab-api-v1.1.json", "w").write(json.dumps(openapi("1.1.0"), indent=2) + "\n")
    open("images.txt", "w").write("".join("%s %s\n" % kv for kv in BUILD_IMAGES.items()))
    print("gen.py: %d switches, %d links, %d hosts, %d switch configs, fw-pa.xml" % (len(SPINES + LEAVES), len(links()),
          len(APP_HOSTS) + 1 + len(PCS), len(SPINES + LEAVES)))

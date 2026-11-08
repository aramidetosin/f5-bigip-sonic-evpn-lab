#!/bin/bash
# resolver-up.sh: the clients' DNS resolver for parts 18-19, BIND 9 on lan-switch (10.10.0.5), run by host-up.sh on RESOLVER_HOST;
# re-runnable: docker exec clab-f5-clos-dc-lan-switch bash /shared/resolver-up.sh
#   gslb.f5lab.test: static-stub to the BIG-IP DNS listeners (GSLB_LISTENERS, shared/gslb-values.sh): the resolver asks them directly,
#                    as it would after following a delegation, and caches each answer for its TTL
#   everything else: NXDOMAIN at once from an empty local root zone: the lab has no internet DNS (the containers' own 127.0.0.11
#                    never answers: their default route leads into the fabric), so failing fast beats timing out
#   only the client LAN (10.10.0.0/24) may query; DNSSEC validation off (the lab zone is unsigned); query log in /var/cache/bind/queries.log
set -e
. /shared/gslb-values.sh
LS=$(echo $GSLB_LISTENERS | sed 's/ /; /g')
mkdir -p /var/cache/bind /run/named; chown named:named /var/cache/bind /run/named   # named runs as user named
printf '$TTL 300\n@ IN SOA localhost. root.localhost. 1 3600 600 86400 300\n@ IN NS localhost.\n' > /var/cache/bind/root.empty
cat > /etc/bind/named.conf <<EOF
options {
  directory "/var/cache/bind";
  listen-on { $RESOLVER_IP; 127.0.0.1; };
  listen-on-v6 { none; };
  allow-query { 10.10.0.0/24; 127.0.0.1; };
  recursion yes;
  dnssec-validation no;
};
logging { channel q { file "/var/cache/bind/queries.log" versions 2 size 5m; print-time yes; }; category queries { q; }; };
zone "." { type primary; file "/var/cache/bind/root.empty"; };
zone "$GSLB_ZONE" { type static-stub; server-addresses { $LS; }; };
EOF
named-checkconf /etc/bind/named.conf
if pgrep -x named >/dev/null; then rndc reconfig 2>/dev/null || { pkill -x named; sleep 1; named -u named -n 2 -c /etc/bind/named.conf; }
else named -u named -n 2 -c /etc/bind/named.conf; fi
echo "resolver on $RESOLVER_IP: $GSLB_ZONE > $GSLB_LISTENERS"

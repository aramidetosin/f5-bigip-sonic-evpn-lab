#!/bin/bash
# host-up.sh: network and SSH of the Linux nodes, from their environment (IP, GW, BOND, BRIDGE):
#   BOND=1: bond0 = eth1 + eth2 (LACP fast) to a leaf pair (ESI-LAG); BOND=0: eth1 alone
#   BRIDGE="eth3 eth4 eth5": br0 = the uplink + those ports (the lan-switch: the PCs hang off it), the address on br0
# A busybox httpd answers "<hostname> <ip>" on :80; sshd on the management address (admin, with the lab's authorized keys).
set -e
for i in eth1 eth2; do ethtool -K $i tx off >/dev/null 2>&1 || true; done
if [ "$BOND" = 1 ]; then
  ip link add bond0 type bond mode 802.3ad lacp_rate fast miimon 100 xmit_hash_policy layer3+4
  for i in eth1 eth2; do ip link set $i down; ip link set $i master bond0; done
  DEV=bond0
else DEV=eth1; fi
if [ -n "${BRIDGE:-}" ]; then
  ip link set $DEV mtu 9000; ip link set $DEV up
  ip link add br0 type bridge; ip link set br0 mtu 9000; ip link set $DEV master br0
  for i in $BRIDGE; do ip link set $i mtu 9000 2>/dev/null && ip link set $i master br0 && ip link set $i up; done
  DEV=br0
fi
ip link set $DEV mtu 9000; ip link set $DEV up; ip addr add $IP dev $DEV
ip route replace default via $GW dev $DEV
[ -n "${NOHTTP:-}" ] || { mkdir -p /www && echo "$(hostname) ${IP%/*}" > /www/index.html && httpd -p ${IP%/*}:80 -h /www; }   # server-up.sh / tools-up.sh: NOHTTP=1
# ssh on the management address: the admin / root passwords come from /run/f5lab/host.env, a read-only bind of
# /root/f5-clos-dc-secrets/host.env (HOST_ADMIN_PW, HOST_ROOT_PW); without it the accounts have no password: docker exec only
id admin >/dev/null 2>&1 || adduser -D -s /bin/bash admin
if [ -r /run/f5lab/host.env ]; then . /run/f5lab/host.env
  printf 'admin:%s\nroot:%s\n' "$HOST_ADMIN_PW" "$HOST_ROOT_PW" | chpasswd; unset HOST_ADMIN_PW HOST_ROOT_PW
fi
if [ -s /run/f5lab/authorized_keys ]; then
  mkdir -p /home/admin/.ssh && cp /run/f5lab/authorized_keys /home/admin/.ssh/authorized_keys && chmod 700 /home/admin/.ssh && chmod 600 /home/admin/.ssh/authorized_keys && chown -R admin:admin /home/admin/.ssh
fi
ssh-keygen -A >/dev/null
sed -i -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
pgrep -x sshd >/dev/null || /usr/sbin/sshd
. /shared/gslb-values.sh; [ "$(hostname)" = "$RESOLVER_HOST" ] && bash /shared/resolver-up.sh || true

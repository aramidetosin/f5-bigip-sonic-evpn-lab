#!/bin/bash
# demo/users.sh <pc> <users> <requests> [jar|nojar]: several "users" on one PC (one source address, like many users behind one NAT)
# each send <requests> requests to the app's VIP; prints which server answered each (part 7). With "jar" every user keeps its own
# cookie jar, like a browser; with "nojar" no cookie is ever sent back. Run on the lab server. Values: pc mgmt IPs from gen.py.
PC=${1:-pc1}; U=${2:-6}; N=${3:-3}; MODE=${4:-jar}
case $PC in pc1) IP=172.21.32.111;; pc2) IP=172.21.32.112;; pc3) IP=172.21.32.113;; *) echo "pc1|pc2|pc3"; exit 1;; esac
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR admin@$IP "
for u in \$(seq $U); do J=/tmp/user\$u.jar; rm -f \$J; printf '$PC user %-2s ' \$u
  for i in \$(seq $N); do
    if [ $MODE = jar ]; then curl -s -b \$J -c \$J -o /dev/null -w '%header{x-server} ' http://app.f5lab.test/
    else curl -s -o /dev/null -w '%header{x-server} ' http://app.f5lab.test/; fi
  done; echo; done"

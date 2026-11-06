#!/bin/bash
# server-up.sh: startup of server1-3 and the sorry-server: host-up.sh, then the whoami web page.
set -e
NOHTTP=1 bash /shared/host-up.sh
bash /shared/whoami-up.sh

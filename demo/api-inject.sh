#!/bin/bash
# api-inject.sh: from the lab server, pc1 POSTs one item whose name is a SQL injection that the JSON schema allows
# (a string of 1-40 characters): {"name":"x' OR '1'='1","qty":3}. Positive security has nothing to object to; only signatures can.
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
ssh $O -n admin@172.21.32.111 "cat > /tmp/inj.json <<'J'
{\"name\":\"x' OR '1'='1\",\"qty\":3}
J
cat /tmp/inj.json; curl -s -X POST -H 'Content-Type: application/json' --data-binary @/tmp/inj.json http://api.f5lab.test/api/v1/items"

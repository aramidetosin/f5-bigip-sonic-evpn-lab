#!/bin/bash
# k8s-seed.sh : before a deploy, give each Kubernetes node a fresh /var on the lab server's own disk ($K8S_VAR/<node>), copied from
# the kindest/node image. containerd keeps its overlay snapshots under /var; on the container's own overlay root they fail ("failed to
# mount rootfs component ... invalid argument"). kind uses a docker volume; containerlab binds only host paths.
# Every deploy builds a NEW cluster (k8s-up.sh), so the old /var is removed. Refuses while a node of this lab runs.
cd "$(dirname "$0")"; . ./lib.sh; . shared/k8s-values.sh
for n in $K8S_NODES; do
  docker inspect $C-$n >/dev/null 2>&1 && { say "k8s-seed: $n is running: ./down.sh first"; exit 1; }
done
for n in $K8S_NODES; do
  d=$K8S_VAR/$n; rm -rf "$d"; mkdir -p "$d"
  docker run --rm --entrypoint "" -v "$d":/x $K8S_IMAGE cp -a /var/. /x/ || { say "k8s-seed: copy for $n failed"; exit 1; }
  say "k8s-seed: $n /var ready ($(du -sh "$d" | cut -f1))"
done

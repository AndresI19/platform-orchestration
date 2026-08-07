#!/usr/bin/env bash
# Brings the platform up on minikube, from a cold boot, idempotently.
#
# This exists because two steps on this box are NOT what the minikube docs say, and both fail looking
# like something else. See k8s/README.md for the long version; the short one:
#   1. kubeconfig points at an unroutable IP. Docker here is not native — it lives in a Colima QEMU VM.
#      minikube sees a unix socket, assumes Docker is local, and writes the node's bridge address
#      (192.168.49.2:8443), reachable only inside the VM. So every kubectl call from the host hangs and
#      `minikube start` dies with "apiserver healthz never reported healthy" though the control plane
#      is fine. Fix: point kubeconfig at the port Colima forwards out — which Docker reassigns on every
#      `minikube start`, so this is a script, not a one-time note.
#   2. `minikube docker-env` is unusable, same reason: DOCKER_HOST points at that dead IP. So images
#      are built with Colima's Docker and side-loaded (deploy.sh: docker save | minikube cp | docker load).
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Colima (the Docker runtime VM)"
if ! colima status &>/dev/null; then
  # 2 CPU / 4 GiB is Colima's default and is not enough to hold a K8s control plane plus
  # ingress-nginx plus the stack.
  colima start --cpu 8 --memory 16
else
  echo "    already running"
fi

# minikube's forwarded apiserver port changes on every start, so kubeconfig is repointed at it each run
# (`docker port` asked fresh). `minikube status` is NOT a usable gate: it probes the unroutable
# 192.168.49.2 and reports the cluster down even while it serves, forcing a needless `minikube start`
# that then sits through a ~6-minute "apiserver healthz never reported healthy" timeout. So gate on what
# is actually true — the node container is up and the apiserver answers once kubeconfig points at the
# forwarded port (this mirrors systemd/platform-boot.sh, which was fixed the same way).
repoint_kubeconfig() {
  local port; port="$(docker port minikube 8443 2>/dev/null | head -1 | sed 's/.*://')"
  [[ -n "$port" ]] || return 1
  kubectl config set-cluster minikube --server="https://127.0.0.1:${port}" >/dev/null
  echo "    apiserver -> https://127.0.0.1:${port}"
}
node_running() { docker ps --format '{{.Names}}' | grep -qx minikube; }
apiserver_answers() { kubectl --request-timeout=10s get --raw /healthz &>/dev/null; }

echo "==> minikube"
if node_running && repoint_kubeconfig && apiserver_answers; then
  echo "    already running"
else
  # May exit non-zero with "apiserver healthz never reported healthy" — the unroutable-IP problem in
  # (1) surfacing as a start failure, not a broken cluster; the repoint below is the actual fix.
  minikube start --driver=docker --cpus=4 --memory=8g || echo "    (start reported an error; repointing kubeconfig before believing it)"
  repoint_kubeconfig
  apiserver_answers || { echo "apiserver still unreachable after repointing kubeconfig" >&2; exit 1; }
fi
kubectl get nodes

echo "==> ingress addon"
minikube addons enable ingress >/dev/null
echo "    enabled"

# The registry and — the half that is easy to forget — the CA trust that makes it usable. Both the
# colima VM's docker daemon and the node's hold that trust in an /etc that a `delete` destroys, so it
# has to be reinstalled by whatever recreates the cluster. That is this script. Run after
# `minikube start`, because the registry attaches to the network minikube creates.
./k8s/registry.sh

# Bootstrap: the namespace, SealedSecrets and PVCs the chart references but does NOT own (see
# k8s/bootstrap/). They must exist before deploy.sh runs helm, because the version-writer hook mounts
# the content PVC and --wait/--rollback-on-failure will roll back if it cannot.
echo "==> Applying bootstrap (namespace, sealed secrets, PVCs, deployer RBAC)"
kubectl apply -f k8s/bootstrap/

# ONE deploy path. deploy.sh builds every component with a content-addressed tag, side-loads it, and
# runs `helm upgrade --install`. Delegating here (instead of a second hand-rolled build+load list)
# is what stops the two from drifting — the old list here had already lost platform-auth.
echo "==> Deploying the stack (build + side-load + helm upgrade --install)"
./k8s/deploy.sh

cat <<'EOF'

==> Up. The cluster has no host-routable IP (minikube ip / minikube tunnel do NOT work through
    Colima), so reach it by forwarding the router:

        kubectl -n platform port-forward svc/nginx 8081:8080
        # then: http://localhost:8081/   /cloud-developer-quiz/   /vmcp/   /mcp

    The public site is NOT served from here — deploy it with `./k8s/deploy.sh public`
    (charts/platform-infra/values-public.yaml), and read its cutover note before applying it.
EOF

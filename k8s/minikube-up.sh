#!/usr/bin/env bash
# Brings the platform up on minikube, from a cold boot, idempotently.
#
# This exists because two steps on this box are NOT what the minikube docs tell you to do, and both
# fail in ways that look like something else. See k8s/README.md for the long version; the short one:
#
#   1. kubeconfig points at an unroutable IP. Docker here is not a native daemon — it lives inside a
#      Colima QEMU VM. minikube sees a unix socket, concludes Docker is local, and writes the node's
#      bridge address (192.168.49.2:8443) into kubeconfig. That address exists only inside the VM's
#      network namespace, so every kubectl call from the host hangs and `minikube start` itself dies
#      with "apiserver healthz never reported healthy" — even though the control plane is fine.
#      The fix is to point kubeconfig at the port Colima forwards out to the host instead. That port
#      is assigned by Docker at container-create time, so it CHANGES on every `minikube start` —
#      which is why this is a script and not a one-time note.
#
#   2. `minikube docker-env` is unusable, for the same reason: it hands out DOCKER_HOST pointing at
#      that same dead IP. So images are built with Colima's Docker and side-loaded with
#      `minikube image load`.
set -euo pipefail

cd "$(dirname "$0")/.."
IMAGES=(home quiz vmcp rs-mcp-server fvt-traffic)

echo "==> Colima (the Docker runtime VM)"
if ! colima status &>/dev/null; then
  # 2 CPU / 4 GiB is Colima's default and is not enough to hold a K8s control plane plus
  # ingress-nginx plus the stack. The VM is also still running the compose site, so leave it room.
  colima start --cpu 8 --memory 16
else
  echo "    already running"
fi

echo "==> minikube"
if ! minikube status &>/dev/null || ! docker ps --format '{{.Names}}' | grep -qx minikube; then
  # Sized to leave roughly half the VM to the compose containers sharing it.
  # This may exit non-zero with "apiserver healthz never reported healthy" — that is the kubeconfig
  # problem in (1), not a broken cluster, and the repoint below is what fixes it.
  minikube start --driver=docker --cpus=4 --memory=8g || echo "    (start reported an error; repointing kubeconfig before believing it)"
else
  echo "    already running"
fi

echo "==> Repointing kubeconfig at the forwarded apiserver port"
# `docker port` is asked fresh every run precisely because this port is not stable across restarts.
PORT="$(docker port minikube 8443 | head -1 | sed 's/.*://')"
kubectl config set-cluster minikube --server="https://127.0.0.1:${PORT}" >/dev/null
echo "    apiserver -> https://127.0.0.1:${PORT}"
kubectl get nodes

echo "==> ingress addon"
minikube addons enable ingress >/dev/null
echo "    enabled"

echo "==> Building images (Colima's Docker) and side-loading them into the cluster"
docker build -q -t home ../project-platform/portfolio-home >/dev/null
docker build -q -t quiz --build-arg BASE_PATH=/cloud-developer-quiz/ ../data-driven-quiz-server >/dev/null
docker build -q -t vmcp ../open-vMCP >/dev/null
docker build -q -t rs-mcp-server ../rs-mcp-server >/dev/null
docker build -q -t fvt-traffic -f ../rs-mcp-server/Dockerfile.fvt ../rs-mcp-server >/dev/null
for i in "${IMAGES[@]}"; do
  # The platform- prefix is not cosmetic: with imagePullPolicy IfNotPresent and a bare name like
  # `home`, a cache miss would send the kubelet to Docker Hub for docker.io/library/home — a real
  # name that is not ours. A miss on platform-home fails loudly instead.
  docker tag "$i:latest" "platform-$i:latest"
  echo "    loading platform-$i"
  minikube image load "platform-$i:latest"
done

echo "==> Applying the local stack"
kubectl apply -k k8s/
kubectl -n platform wait --for=condition=available --timeout=300s deploy --all

cat <<'EOF'

==> Up. The cluster has no host-routable IP (minikube ip / minikube tunnel do NOT work through
    Colima), so reach it by forwarding the router:

        kubectl -n platform port-forward svc/nginx 8081:8080
        # then: http://localhost:8081/   /cloud-developer-quiz/   /vmcp/   /mcp

    The public site is NOT served from here — see k8s/overlays/public/, and read its cutover note
    before applying it.
EOF

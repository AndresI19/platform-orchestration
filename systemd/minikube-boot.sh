#!/usr/bin/env bash
# Boot-time bring-up for the minikube cluster. Invoked by minikube.service; safe to run by hand.
#
# Deliberately does NOT build or load images: the minikube node is a container whose docker daemon
# keeps its images across a stop/start, so a reboot only needs the cluster started, not repopulated.
# (Rebuilding five images on every boot would add minutes to the site's recovery time for nothing.)
# Use k8s/minikube-up.sh when the images themselves need to change.
set -euo pipefail

export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"

# Colima owns the Docker daemon that minikube's node container runs in, so nothing below can work
# until its VM is up. systemd orders us After=colima.service, but "started" for a oneshot unit only
# means `colima start` returned — the docker socket can still be a moment behind. Poll rather than
# assume.
for _ in $(seq 1 60); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done
docker info >/dev/null 2>&1 || { echo "docker never came up; is colima running?" >&2; exit 1; }

minikube status >/dev/null 2>&1 || minikube start --driver=docker --cpus=4 --memory=8g || true

# THE STEP THAT IS EASY TO FORGET. minikube writes the node's bridge IP (192.168.49.2:8443) into
# kubeconfig, which is unroutable from this host because docker lives inside Colima's VM — so every
# kubectl call, including the ones below, would hang. Colima forwards the node's published port out
# to the host, and that port is reassigned by docker on every start, so it must be re-read each boot
# rather than hard-coded. See k8s/README.md.
PORT="$(docker port minikube 8443 | head -1 | sed 's/.*://')"
kubectl config set-cluster minikube --server="https://127.0.0.1:${PORT}" >/dev/null
echo "apiserver -> https://127.0.0.1:${PORT}"

# The cluster's own restartPolicy brings the workloads back on its own; this just refuses to report
# success until the site can actually serve, so `systemctl --user status minikube` tells the truth.
kubectl -n platform wait --for=condition=available --timeout=300s deploy --all
echo "platform is up"

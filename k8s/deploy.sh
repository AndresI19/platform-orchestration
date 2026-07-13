#!/usr/bin/env bash
# Build, publish and roll out the platform. This is the ONLY supported way to deploy.
#
# ---------------------------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS: the previous flow could silently deploy nothing.
#
# It was: build → `minikube image load platform-x:latest` → `kubectl rollout restart`. Every step
# reported success, and the cluster went on running the old code. TWO independent faults, and they
# covered for each other:
#
#   1. `minikube image load` NO-OPS when a tag is already present in the node. It prints nothing and
#      exits 0. The new image never crosses into the cluster.
#   2. `:latest` + `imagePullPolicy: IfNotPresent` means the kubelet never looks for a newer image —
#      the tag is already there, so it uses it. And because the Pod spec is byte-identical between
#      deploys, `kubectl apply` sees nothing to change, so a `rollout restart` was needed just to get
#      new Pods at all — which then found the same stale image.
#
# Both faults come from ONE mistake: a mutable tag. `:latest` is a pointer, not an identity, so
# nothing downstream can tell two builds apart. This script tags every image by CONTENT instead:
#
#   * clean tree → the commit sha           e.g. platform-home:0fcc7de
#   * dirty tree → sha + a hash of the diff e.g. platform-home:0fcc7de-dirty.a1b2c3d
#
# The dirty case matters. `git describe --dirty` would call every uncommitted state "0fcc7de-dirty",
# so two different sets of local edits would collide on one tag and we would be back where we
# started. Hashing the diff makes the tag a function of what is actually in the image.
#
# The tag then flows into k8s/base/kustomization.yaml, so the POD SPEC CHANGES on every deploy and
# `kubectl apply` performs a real rolling update. No `rollout restart` anywhere. And the file records
# what is deployed — `git diff` on it is the deployment history.
# ---------------------------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OVERLAY="${1:-}" # pass "public" to deploy the public overlay instead of the base

# Repoint kubeconfig at the forwarded apiserver port. Docker here lives in a Colima VM, so minikube
# writes an unroutable bridge IP into kubeconfig and every kubectl call hangs (see minikube-up.sh for
# the long version). The forwarded port changes on every `minikube start`, so it is re-derived here
# rather than hard-coded — which is what makes deploy self-sufficient instead of needing a manual
# repoint before each run. Skips quietly if minikube isn't up (the apply step will report that).
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx minikube; then
  APISERVER_PORT="$(docker port minikube 8443 2>/dev/null | head -1 | sed 's/.*://')"
  if [ -n "${APISERVER_PORT:-}" ]; then
    kubectl config set-cluster minikube --server="https://127.0.0.1:${APISERVER_PORT}" >/dev/null 2>&1 || true
    echo "==> kubeconfig -> https://127.0.0.1:${APISERVER_PORT}"
  fi
fi

# app name -> source repo (relative to this repo)
APPS=(home quiz vmcp rs-mcp-server fvt-traffic platform-auth)
declare -A REPO=(
  [home]=../project-platform/portfolio-home
  [quiz]=../data-driven-quiz-server
  [vmcp]=../open-vMCP
  [rs-mcp-server]=../rs-mcp-server
  [fvt-traffic]=../rs-mcp-server
  [platform-auth]=../project-platform/platform-auth
)

# Content-addressed tag. A clean tree is its commit; a dirty tree is its commit plus a hash of the
# diff, so two different working states can never share a tag.
content_tag() {
  local repo="$1" sha diff
  sha="$(git -C "$repo" rev-parse --short HEAD)"
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    # Tracked edits AND untracked files both change the image, so both go into the hash.
    diff="$( { git -C "$repo" diff HEAD; git -C "$repo" ls-files --others --exclude-standard; } | sha1sum | cut -c1-7)"
    echo "${sha}-dirty.${diff}"
  else
    echo "$sha"
  fi
}

# Get the image into the cluster's OWN docker daemon (the minikube node runs its own, separate from
# Colima's). `minikube image load` is NOT used: it silently no-ops on an existing tag — see above.
# A save/copy/load is slower but it either works or fails loudly, which is the property that matters.
push_to_cluster() {
  local img="$1" tar
  tar="$(mktemp -t platform-img-XXXXXX.tar)"
  docker save "$img" -o "$tar"
  minikube cp "$tar" /home/docker/img.tar >/dev/null
  minikube ssh -- "docker load -i /home/docker/img.tar >/dev/null && rm -f /home/docker/img.tar"
  rm -f "$tar"
  # Prove it landed. Without this the whole failure mode we are fixing could simply come back in a
  # different disguise.
  minikube ssh -- "docker image inspect $img >/dev/null 2>&1" \
    || { echo "FATAL: $img is not in the cluster after load" >&2; exit 1; }
}

declare -A TAG
echo "==> Building"
for app in "${APPS[@]}"; do
  repo="${REPO[$app]}"
  TAG[$app]="$(content_tag "$repo")"
  img="platform-${app}:${TAG[$app]}"

  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "    $img (already built — content unchanged)"
    continue
  fi

  case "$app" in
    quiz) docker build -q -t "$img" --build-arg BASE_PATH=/cloud-developer-quiz/ "$repo" >/dev/null ;;
    fvt-traffic) docker build -q -t "$img" -f "$repo/Dockerfile.fvt" "$repo" >/dev/null ;;
    *) docker build -q -t "$img" "$repo" >/dev/null ;;
  esac
  echo "    $img"
done

echo "==> Publishing into the cluster"
for app in "${APPS[@]}"; do
  img="platform-${app}:${TAG[$app]}"
  if minikube ssh -- "docker image inspect $img >/dev/null 2>&1"; then
    echo "    $img (already in cluster)"
  else
    echo "    $img"
    push_to_cluster "$img"
  fi
done

echo "==> Pinning the tags into k8s/base/kustomization.yaml"
PLATFORM_TAGS=""
for app in "${APPS[@]}"; do PLATFORM_TAGS+="${app}=${TAG[$app]};"; done
export PLATFORM_TAGS
python3 - "$ROOT" "${APPS[@]}" <<'PY'
import re, sys
root, apps = sys.argv[1], sys.argv[2:]
import subprocess
path = f"{root}/k8s/base/kustomization.yaml"
src = open(path).read()
tags = dict(t.split("=", 1) for t in __import__("os").environ["PLATFORM_TAGS"].split(";") if t)
# newTag is quoted: an all-digit short SHA (e.g. 6882688) is otherwise read as a YAML number,
# and kustomize rejects a numeric newTag ("cannot unmarshal number ... into type string").
block = "images:\n" + "".join(
    f'  - name: platform-{a}\n    newTag: "{tags[a]}"\n' for a in apps
)
if re.search(r"(?m)^images:\n(?:  .*\n)*", src):
    src = re.sub(r"(?m)^images:\n(?:  .*\n)*", block, src)
else:
    src = src.rstrip() + "\n\n# Set by k8s/deploy.sh. Content-addressed tags: the Pod spec changes\n" \
                         "# whenever the code does, so `kubectl apply` performs a real rolling update.\n" + block
open(path, "w").write(src)
for a in apps:
    print(f"    platform-{a}:{tags[a]}")
PY

echo "==> Applying"
if [ "$OVERLAY" = "public" ]; then
  kubectl apply -k k8s/overlays/public/
else
  kubectl apply -k k8s/
fi

echo "==> Waiting for rollouts"
kubectl -n platform wait --for=condition=available --timeout=300s deploy --all

echo "==> Deployed"
kubectl -n platform get deploy -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image' --no-headers | sed 's/^/    /'

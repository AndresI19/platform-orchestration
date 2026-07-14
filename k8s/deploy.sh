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

# ---------------------------------------------------------------------------------------------
# VERSION: the human-readable half of the identity, and what the component reports at /version.
#
#   in sync with main → the repo's latest git tag              e.g. 0.1.4
#   differs from main → that tag, suffixed                     e.g. 0.1.4-snapshot
#
# "Differs from main" means uncommitted edits, untracked files, OR commits not yet on main — anything
# that makes the built image something other than what main describes.
#
# The diff is SCOPED TO THE COMPONENT'S SUBTREE, deliberately. Two components share one repo in two
# places (home + platform-auth in project-platform; rs-mcp-server + fvt-traffic in rs-mcp-server), so
# a repo-wide diff would stamp platform-auth as a snapshot merely because the home page was edited.
# The tag, by contrast, IS repo-wide — that is what a git tag is.
#
# Extra arguments are git pathspecs appended to the diff — in practice, exclusions. See the call for
# PLATFORM_VERSION below, which is the only user of them and explains why.
component_version() {
  local path="$1"; shift
  local extra=("$@")
  local root rel base ref changes
  root="$(git -C "$path" rev-parse --show-toplevel)"
  rel="$(realpath --relative-to="$root" "$path")"
  # Latest tag reachable from HEAD; a repo that has never been tagged starts at 0.0.0.
  base="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)"
  # origin/main, not main: the question is "does this differ from what is ON main", and the local
  # main branch can itself be stale — on this box it was, by three merged PRs.
  ref=origin/main
  git -C "$root" rev-parse --verify -q "$ref" >/dev/null || ref=main
  # `git diff <ref> -- <path>` compares the WORKING TREE to the ref, so one command covers both
  # unpushed commits and uncommitted edits. Untracked files change the image too, so they count.
  changes="$( { git -C "$root" diff "$ref" --name-only -- "$rel" "${extra[@]}"
                git -C "$root" ls-files --others --exclude-standard -- "$rel" "${extra[@]}"; } )"
  [ -n "$changes" ] && echo "${base}-snapshot" || echo "$base"
}

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

declare -A TAG VERSION
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# THIS repo has a version too, by exactly the same rule — and it is the only component that ships no
# image. It is not a service; it is the description of the platform (manifests, routing, secrets,
# boot), and it is the thing that decides what everything else is. So it cannot carry its version in
# an image the way the others do. It is written onto the PersistentVolume instead (see below), which
# is the same reasoning the résumé and the card decks are on there: content that changes on a
# different clock than the code that serves it.
#
# kustomization.yaml is EXCLUDED from the platform's own diff, and it has to be. This script writes
# the image pins into that file — so a deploy dirties the very repo it is versioning, and the platform
# would report `-snapshot` from the moment it was first deployed, forever, without anybody having
# touched it. The version would then be measuring "have you deployed recently" rather than "what is
# this", which is worthless.
#
# The justification is that the pins are an OUTPUT of a deploy, not a description of the platform:
# they record what was deployed; they do not change what the platform IS. Every other file here does.
#
# The cost, stated plainly: a HAND edit to kustomization.yaml — adding a resource, say — no longer
# marks the platform as a snapshot. That is a real hole. It is the narrower one, though: the
# alternative is a version that is permanently and uninformatively "-snapshot".
PLATFORM_VERSION="$(component_version "$ROOT" ':!k8s/base/kustomization.yaml')"
echo "==> Platform ${PLATFORM_VERSION}"

echo "==> Building"
for app in "${APPS[@]}"; do
  repo="${REPO[$app]}"
  VERSION[$app]="$(component_version "$repo")"
  # The version is HALF THE TAG, not just a label, and that is load-bearing. Cutting a git tag does
  # not change a single byte of source — so on a content-addressed tag alone, releasing 0.1.4 → 0.1.5
  # would produce the identical tag, skip the build as "content unchanged", skip the push as "already
  # in cluster", leave the Pod spec byte-identical, and never deploy. The version IS image content
  # (it is baked into the VERSION file), so it has to be part of the image's identity.
  # Bonus: `kubectl get deploy` now shows the running version without opening anything.
  TAG[$app]="${VERSION[$app]}-$(content_tag "$repo")"
  img="platform-${app}:${TAG[$app]}"

  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "    $img (already built — content unchanged)"
    continue
  fi

  # Every image takes the same three OCI args. VERSION is the one with teeth: the Dockerfile writes it
  # to a VERSION file that the app reads at startup and serves from /version.
  args=(--build-arg "VERSION=${VERSION[$app]}"
        --build-arg "GIT_SHA=$(git -C "$repo" rev-parse --short HEAD)"
        --build-arg "BUILD_DATE=${BUILD_DATE}")
  case "$app" in
    quiz) docker build -q -t "$img" "${args[@]}" --build-arg BASE_PATH=/cloud-developer-quiz/ "$repo" >/dev/null ;;
    fvt-traffic) docker build -q -t "$img" "${args[@]}" -f "$repo/Dockerfile.fvt" "$repo" >/dev/null ;;
    *) docker build -q -t "$img" "${args[@]}" "$repo" >/dev/null ;;
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

# ---------------------------------------------------------------------------------------------
# The version spec: what this deploy actually put on the cluster, written where the platform can
# read it back.
#
# Every other component carries its version INSIDE its image. This one cannot — the orchestration
# repo ships no image — so the platform's own version travels on the PersistentVolume, next to the
# résumé and the card decks. Same reasoning: it is content, not code, and it changes on a different
# clock than the app that serves it. The home page reads it from there and serves it at /version and
# /api/versions.
#
# Writing it needs a pod, because the volume only exists inside the cluster. home mounts /content
# READ-ONLY (it is a consumer of this file, and a web server has no business being able to rewrite
# the record of what is deployed), so `kubectl cp` into home would fail. An ephemeral writer that
# mounts the PVC read-write is the same pattern platform-ops/pv-content.sh uses to replace the
# résumé — busybox:1.36 deliberately, because that image is already in the node and needs no pull.
#
# The spec records the component tags as well as the platform version. The endpoint only serves the
# platform version today, but the expensive half of this is spinning the pod, not the extra keys —
# and a file on the volume saying exactly what was deployed, and when, is worth having.
echo "==> Writing the version spec onto the volume"
SPEC="$(mktemp -t platform-version-XXXXXX.json)"
trap 'rm -f "$SPEC"' EXIT
{
  printf '{\n  "platform": "%s",\n  "deployedAt": "%s",\n  "components": {\n' "$PLATFORM_VERSION" "$BUILD_DATE"
  sep=""
  for app in "${APPS[@]}"; do
    printf '%s    "%s": { "version": "%s", "image": "platform-%s:%s" }' \
      "$sep" "$app" "${VERSION[$app]}" "$app" "${TAG[$app]}"
    sep=$',\n'
  done
  printf '\n  }\n}\n'
} > "$SPEC"

WRITER=version-writer
kubectl -n platform delete pod "$WRITER" --ignore-not-found --now >/dev/null 2>&1 || true
kubectl -n platform apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $WRITER, namespace: platform, labels: { app: pv-writer } }
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
    - name: w
      image: busybox:1.36
      command: ["sh", "-c", "sleep 300"]
      volumeMounts: [{ name: content, mountPath: /content }]
  volumes:
    - name: content
      persistentVolumeClaim: { claimName: platform-content }
YAML
kubectl -n platform wait --for=condition=Ready "pod/$WRITER" --timeout=90s >/dev/null
kubectl -n platform cp "$SPEC" "platform/$WRITER:/content/platform-version.json"

# `kubectl cp` is a tar stream: it carries the LOCAL file's mode and owner into the volume. mktemp
# creates 0600 owned by whoever ran this script, so without this the spec lands unreadable by the home
# container, which runs as a different user — and the endpoint reports `null` forever, blaming a
# missing file that is right there. Found exactly that way. 0644: everything on this volume is public
# content, and home mounts it read-only anyway.
kubectl -n platform exec "$WRITER" -- chmod 0644 /content/platform-version.json

# Prove it landed AND that home will be able to read it, rather than trusting a cp that reported
# success. The mode is asserted rather than a `test -r`, because this writer runs as root: root can
# read a 0600 file, so `test -r` would pass happily on exactly the broken state described above. The
# question is whether a DIFFERENT user can read it, and that is a question about the mode.
kubectl -n platform exec "$WRITER" -- sh -c \
  '[ "$(stat -c %a /content/platform-version.json)" = "644" ]' \
  || { echo "FATAL: the version spec is not on the volume, or home cannot read it" >&2; exit 1; }
kubectl -n platform delete pod "$WRITER" --now >/dev/null 2>&1 || true
echo "    platform-version.json → platform ${PLATFORM_VERSION}"

# home reads the spec per REQUEST, not at startup, so it needs no restart to notice this — which is
# the whole point of the file living on the volume rather than in the image.

echo "==> Deployed"
kubectl -n platform get deploy -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image' --no-headers | sed 's/^/    /'

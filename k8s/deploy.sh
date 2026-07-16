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
#      the tag is already there, so it uses it.
#
# Both faults come from ONE mistake: a mutable tag. This script tags every image by CONTENT instead:
#
#   * clean tree → the commit sha           e.g. platform-home:0fcc7de
#   * dirty tree → sha + a hash of the diff e.g. platform-home:0fcc7de-dirty.a1b2c3d
#
# The tag then rides into the release as a Helm VALUE (apps.<app>.image.tag), so the Pod spec changes
# on every deploy and Helm performs a real rolling update. No `rollout restart` anywhere.
#
# WHY HELM, NOT kustomize: the tag no longer lives in a committed file. It lives in the Helm release,
# which is server-side state — so there is nothing for a later `apply` to revert to (the old kustomize
# `images:` pins-vs-`set image` conflict is gone), every deploy is a versioned, rollback-able release
# (`helm history platform`, `helm rollback platform`), and the versions are resolved into values
# BEFORE the deploy, so the release itself is versioned and the version-writer hook renders
# platform-version.json from exactly what was deployed. See chart/ and templates/hooks/version-writer.yaml.
#
# BOOTSTRAP FIRST: the namespace, SealedSecrets and the three PVCs are NOT in the chart (they are in
# k8s/bootstrap/, applied with kubectl). They must exist before the first deploy — the version-writer
# hook mounts the content PVC, and --wait/--rollback-on-failure will roll back if it cannot. See k8s/README.md.
# ---------------------------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OVERLAY="${1:-}" # pass "public" to layer the public front door (values-public.yaml) on top

# Repoint kubeconfig at the forwarded apiserver port. Docker here lives in a Colima VM, so minikube
# writes an unroutable bridge IP into kubeconfig and every kubectl/helm call hangs (see minikube-up.sh
# for the long version). The forwarded port changes on every `minikube start`, so it is re-derived here
# rather than hard-coded. Skips quietly if minikube isn't up (the deploy step will report that).
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx minikube; then
  APISERVER_PORT="$(docker port minikube 8443 2>/dev/null | head -1 | sed 's/.*://')"
  if [ -n "${APISERVER_PORT:-}" ]; then
    kubectl config set-cluster minikube --server="https://127.0.0.1:${APISERVER_PORT}" >/dev/null 2>&1 || true
    echo "==> kubeconfig -> https://127.0.0.1:${APISERVER_PORT}"
  fi
fi

# app name -> source repo (relative to this repo)
APPS=(home quiz vmcp rs-mcp-server platform-auth)
declare -A REPO=(
  [home]=../project-platform/portfolio-home
  [quiz]=../data-driven-quiz-server
  [vmcp]=../open-vMCP
  [rs-mcp-server]=../rs-mcp-server
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
# The diff is SCOPED TO THE COMPONENT'S SUBTREE, deliberately. Two components share one repo —
# home + platform-auth both live in project-platform — so a repo-wide diff would stamp platform-auth
# as a snapshot merely because the home page was edited.
# The tag, by contrast, IS repo-wide — that is what a git tag is.
#
# Extra arguments are git pathspecs appended to the diff — in practice, exclusions.
component_version() {
  local path="$1"; shift
  local extra=("$@")
  local root rel base ref changes
  root="$(git -C "$path" rev-parse --show-toplevel)"
  rel="$(realpath --relative-to="$root" "$path")"
  base="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)"
  ref=origin/main
  git -C "$root" rev-parse --verify -q "$ref" >/dev/null || ref=main
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
    diff="$( { git -C "$repo" diff HEAD; git -C "$repo" ls-files --others --exclude-standard; } | sha1sum | cut -c1-7)"
    echo "${sha}-dirty.${diff}"
  else
    echo "$sha"
  fi
}

# Get the image into the cluster's OWN docker daemon (the minikube node runs its own, separate from
# Colima's). `minikube image load` is NOT used: it silently no-ops on an existing tag — see above.
push_to_cluster() {
  local img="$1" tar
  tar="$(mktemp -t platform-img-XXXXXX.tar)"
  docker save "$img" -o "$tar"
  minikube cp "$tar" /home/docker/img.tar >/dev/null
  minikube ssh -- "docker load -i /home/docker/img.tar >/dev/null && rm -f /home/docker/img.tar"
  rm -f "$tar"
  minikube ssh -- "docker image inspect $img >/dev/null 2>&1" \
    || { echo "FATAL: $img is not in the cluster after load" >&2; exit 1; }
}

declare -A TAG VERSION
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# THIS repo has a version too, by the same rule — and it is the only component that ships no image, so
# it rides on the content volume (written by the version-writer hook) instead of in an image.
#
# NOTE — the old kustomization.yaml exclusion is GONE, and it can be. deploy.sh used to write the image
# pins into a TRACKED file, so a deploy dirtied the very repo it versioned and the platform reported
# `-snapshot` forever; the diff had to exclude that file. Helm passes the tags as --set values instead,
# writing NOTHING to the working tree, so a deploy no longer dirties this repo and the platform version
# is honest again with no special-case.
PLATFORM_VERSION="$(component_version "$ROOT")"
echo "==> Platform ${PLATFORM_VERSION}"

echo "==> Building"
for app in "${APPS[@]}"; do
  repo="${REPO[$app]}"
  VERSION[$app]="$(component_version "$repo")"
  # The version is HALF THE TAG, not just a label: cutting a git tag changes no source, so on a
  # content-addressed tag alone a release would produce an identical tag, skip the build, skip the
  # push, leave the Pod spec byte-identical, and never deploy. The VERSION file IS image content.
  TAG[$app]="${VERSION[$app]}-$(content_tag "$repo")"
  img="platform-${app}:${TAG[$app]}"

  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "    $img (already built — content unchanged)"
    continue
  fi

  args=(--build-arg "VERSION=${VERSION[$app]}"
        --build-arg "GIT_SHA=$(git -C "$repo" rev-parse --short HEAD)"
        --build-arg "BUILD_DATE=${BUILD_DATE}")
  case "$app" in
    quiz) docker build -q -t "$img" "${args[@]}" --build-arg BASE_PATH=/cloud-developer-quiz/ "$repo" >/dev/null ;;
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

# ---------------------------------------------------------------------------------------------
# Deploy: one Helm release, versions resolved into values BEFORE the upgrade.
#
# The tags and versions become --set values, so the release is the single source of truth for what is
# deployed, `helm history platform` records every revision, and `helm rollback platform` reverts both
# the images AND (via the post-rollback hook) the reported version. --rollback-on-failure rolls a failed deploy back
# on its own; --wait blocks until every workload AND the version-writer hook are done, so a version
# write that home cannot read fails the deploy loudly rather than silently.
echo "==> Deploying (helm upgrade --install platform)"
HELM_SET=(--set "platform.version=${PLATFORM_VERSION}")
for app in "${APPS[@]}"; do
  HELM_SET+=(--set "apps.${app}.image.tag=${TAG[$app]}"
             --set "apps.${app}.version=${VERSION[$app]}")
done
VALUES=()
[ "$OVERLAY" = "public" ] && VALUES=(-f "$ROOT/chart/values-public.yaml")

helm upgrade --install platform "$ROOT/chart" \
  --namespace platform --create-namespace \
  "${VALUES[@]}" "${HELM_SET[@]}" \
  --wait --rollback-on-failure --timeout 5m

echo "==> Deployed  (platform ${PLATFORM_VERSION})"
kubectl -n platform get deploy -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image' --no-headers | sed 's/^/    /'
echo "    helm history platform   # revisions      helm rollback platform <n>   # revert"

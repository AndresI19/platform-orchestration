#!/usr/bin/env bash
# Build, publish and roll out the platform — the ONLY supported way to deploy.
#
# WHY: the old flow (build → `minikube image load :latest` → `kubectl rollout restart`) could deploy
# nothing while every step reported success. Two faults covered for each other: `minikube image load`
# no-ops (exit 0, silent) on a tag already in the node, and `:latest` + `imagePullPolicy: IfNotPresent`
# means the kubelet never re-pulls. Both stem from ONE mutable tag. So every image is tagged by CONTENT:
#   clean tree → commit sha            e.g. platform-home:0fcc7de
#   dirty tree → sha + a hash of diff  e.g. platform-home:0fcc7de-dirty.a1b2c3d
# The tag rides into the release as a Helm value (image.tag), so the Pod spec changes on every deploy
# and Helm does a real rolling update — no `rollout restart` anywhere.
#
# WHY HELM, NOT kustomize: the tag lives in the Helm release (server-side state), not a committed file,
# so a later `apply` has nothing to revert to (the old `images:` pins vs `set image` conflict is gone),
# every deploy is a versioned, rollback-able release, and versions resolve into values BEFORE the deploy
# so the version-writer hook renders platform-version.json from exactly what was deployed.
#
# SIX releases, not one: `platform-infra` (router, databases, tunnel, platform-config, version spec)
# plus one per service, each from the generic `charts/service` chart and the service's OWN
# deploy/<name>.values.yaml in the repo that ships it. One release rendering every app forced CI to
# deploy with `--reuse-values`, making the RELEASE (not the chart) the source of truth and silently
# breaking both directions — a deleted key lived on, an added key never arrived.
#
# This path and CI deploy THE SAME six releases from THE SAME charts/values; they differ only in image
# source. CI pulls `registry:5000/<name>:<version>` and overrides image.repo; this script side-loads
# `platform-<name>:<tag>` and leaves image.repo at the values file's local default.
#
# BOOTSTRAP FIRST: the namespace, SealedSecrets and three PVCs are NOT in the chart (k8s/bootstrap/,
# applied with kubectl) and must exist before the first deploy — the version-writer hook mounts the
# content PVC and --wait/--rollback-on-failure rolls back if it cannot. See k8s/README.md.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OVERLAY="${1:-}" # pass "public" to layer the public front door (values-public.yaml) on top

# Repoint kubeconfig at the forwarded apiserver port: Docker lives in a Colima VM, so minikube writes
# an unroutable bridge IP and every kubectl/helm call hangs (minikube-up.sh has the long version). The
# port changes on every `minikube start`, so re-derive it. Skips quietly if minikube isn't up.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx minikube; then
  APISERVER_PORT="$(docker port minikube 8443 2>/dev/null | head -1 | sed 's/.*://')"
  if [ -n "$APISERVER_PORT" ]; then
    kubectl config set-cluster minikube --server="https://127.0.0.1:${APISERVER_PORT}" >/dev/null 2>&1 || true
    echo "==> kubeconfig -> https://127.0.0.1:${APISERVER_PORT}"
  fi
fi

# app name -> build context (what `docker build` targets, and what the version diff is scoped to). For
# the two components sharing a repo it is a SUBTREE — editing home must not stamp platform-auth.
APPS=(home quiz vmcp rs-mcp-server platform-auth)
declare -A REPO=(
  [home]=../project-platform/portfolio-home
  [quiz]=../data-driven-quiz-server
  [vmcp]=../open-vMCP
  [rs-mcp-server]=../rs-mcp-server
  [platform-auth]=../project-platform/platform-auth
)

# app name -> its deploy values, owned by the repo that ships it. NOT derivable from REPO above: values
# live at the repo ROOT's deploy/, while the build context may be a subtree (project-platform's one
# deploy/ holds both home and platform-auth). These are the same files CI deploys from — the single
# source of truth. The old duplicated copy in this repo's deploy-values/ is gone: two files that must
# stay identical eventually don't.
declare -A VALUES_FILE=(
  [home]=../project-platform/deploy/home.values.yaml
  [quiz]=../data-driven-quiz-server/deploy/quiz.values.yaml
  [vmcp]=../open-vMCP/deploy/vmcp.values.yaml
  [rs-mcp-server]=../rs-mcp-server/deploy/rs-mcp-server.values.yaml
  [platform-auth]=../project-platform/deploy/platform-auth.values.yaml
)

# VERSION: the human-readable half of the identity, reported at /version.
#   in sync with main → the repo's latest git tag   e.g. 0.1.4
#   differs from main → that tag, suffixed          e.g. 0.1.4-snapshot
# "Differs" = uncommitted edits, untracked files, OR commits not on main — anything making the image
# other than what main describes. The diff is SCOPED TO THE COMPONENT'S SUBTREE: home + platform-auth
# share project-platform, so a repo-wide diff would stamp platform-auth a snapshot when only home
# changed. The tag is repo-wide — that is what a git tag is.
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

# Does the minikube node's OWN docker daemon already hold this image? Its daemon is separate from
# Colima's, so this is `minikube ssh`, not a host `docker` call — asked both to skip a redundant
# side-load and to prove one landed.
image_in_cluster() { minikube ssh -- "docker image inspect $1 >/dev/null 2>&1"; }

# Get the image into the cluster's OWN docker daemon (the minikube node runs its own, separate from
# Colima's). `minikube image load` is NOT used: it silently no-ops on an existing tag — see above.
push_to_cluster() {
  local img="$1" tar
  tar="$(mktemp -t platform-img-XXXXXX.tar)"
  docker save "$img" -o "$tar"
  minikube cp "$tar" /home/docker/img.tar >/dev/null
  minikube ssh -- "docker load -i /home/docker/img.tar >/dev/null && rm -f /home/docker/img.tar"
  rm -f "$tar"
  image_in_cluster "$img" \
    || { echo "FATAL: $img is not in the cluster after load" >&2; exit 1; }
}

declare -A TAG VERSION
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# THIS repo has a version too, by the same rule, but ships no image — it rides on the content volume
# (written by the version-writer hook). The old kustomization.yaml exclusion is GONE: deploy.sh used to
# write image pins into a TRACKED file, so a deploy dirtied the repo it versioned and the platform read
# `-snapshot` forever — the diff had to exclude it. Helm passes tags as --set, writing nothing to the
# tree, so no special-case and the version is honest again.
PLATFORM_VERSION="$(component_version "$ROOT")"
echo "==> Platform ${PLATFORM_VERSION}"

# Fail before building if a values file is missing: otherwise helm upgrade "succeeds" against the
# generic chart's own defaults — a component-shaped nothing. The usual cause is the sibling repo not
# being checked out, worth saying up front rather than as a render error later. CI checks the same.
for app in "${APPS[@]}"; do
  [ -f "$ROOT/${VALUES_FILE[$app]}" ] || {
    echo "FATAL: ${app} has no deploy values at ${VALUES_FILE[$app]}" >&2
    echo "       that file is owned by the repo shipping ${app}; is the sibling repo checked out?" >&2
    exit 1
  }
done

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
  # quiz is served under a sub-path, so it alone needs a BASE_PATH; every app builds the same way otherwise.
  [ "$app" = quiz ] && args+=(--build-arg BASE_PATH=/cloud-developer-quiz/)
  docker build -q -t "$img" "${args[@]}" "$repo" >/dev/null
  echo "    $img"
done

echo "==> Publishing into the cluster"
for app in "${APPS[@]}"; do
  img="platform-${app}:${TAG[$app]}"
  if image_in_cluster "$img"; then
    echo "    $img (already in cluster)"
    continue
  fi
  echo "    $img"
  push_to_cluster "$img"
done

# Deploy: six releases, versions resolved into --set values before each upgrade, so each release is the
# source of truth, `helm history` records every revision, and `helm rollback` reverts the images (and,
# for platform-infra, the reported version via the post-rollback hook). --rollback-on-failure reverts a
# failed deploy; --wait blocks until ready, so a break fails loudly here.
#
# INFRA FIRST, not for tidiness: platform-config and the databases are what services read at startup,
# and the version-writer hook (post-install/upgrade here) needs the content PVC. A service starting
# before its config reads an empty env and must be restarted.
#
# The library subchart is vendored, never committed (.gitignore'd) — without this the charts cannot
# render at all.
echo "==> Vendoring chart dependencies"
helm dependency build "$ROOT/charts/platform-infra" >/dev/null
helm dependency build "$ROOT/charts/service" >/dev/null

INFRA_VALUES=()
[ "$OVERLAY" = "public" ] && INFRA_VALUES=(-f "$ROOT/charts/platform-infra/values-public.yaml")

echo "==> Deploying platform-infra (${PLATFORM_VERSION}${OVERLAY:+, ${OVERLAY} overlay})"
helm upgrade --install platform-infra "$ROOT/charts/platform-infra" \
  --namespace platform --create-namespace \
  "${INFRA_VALUES[@]}" \
  --set "platform.version=${PLATFORM_VERSION}" \
  --wait --rollback-on-failure --timeout 5m

# Each service: generic chart + the service repo's own values + this deploy's image identity.
# image.repo is deliberately NOT set — the values file defaults it to `platform-<name>`, and only CI
# overrides it to the registry.
for app in "${APPS[@]}"; do
  echo "==> Deploying ${app} (${VERSION[$app]})"
  helm upgrade --install "$app" "$ROOT/charts/service" \
    --namespace platform \
    -f "$ROOT/${VALUES_FILE[$app]}" \
    --set "image.tag=${TAG[$app]}" \
    --set "version=${VERSION[$app]}" \
    --wait --rollback-on-failure --timeout 5m
done

echo "==> Deployed  (platform ${PLATFORM_VERSION})"
kubectl -n platform get deploy -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image' --no-headers | sed 's/^/    /'
echo "    helm history <release>   # revisions      helm rollback <release> <n>   # revert"
echo "    releases: platform-infra ${APPS[*]}"

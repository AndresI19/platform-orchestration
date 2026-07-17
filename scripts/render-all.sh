#!/usr/bin/env bash
# render-all.sh [outdir] — render every release this platform deploys, without applying anything.
#
# The platform is SIX Helm releases: `platform-infra` (router, databases, tunnel, config, version
# spec) plus one per service, each from the generic `charts/service` chart and the service's own
# deploy/<name>.values.yaml. This renders all of them the same way a deploy does, so that "what CI
# scans" and "what gets deployed" cannot drift apart.
#
# WHY A SCRIPT, not a few lines in ci.yml: two CI jobs use it (the Trivy config scan and the
# kubeconform schema check), and it is the fastest local check that a chart edit renders at all. One
# renderer, three callers.
#
# It replaced render-parity.sh, which proved the split charts rendered identically to the umbrella.
# That gate did its job: the split is deployed and serving, the umbrella is gone — nothing left to be
# at parity WITH.
#
# WHERE THE SERVICE VALUES COME FROM. Each is owned by the repo that ships the component, so this
# needs those repos on disk. Two layouts, both supported, because there are two callers:
#   * CI checks the repos out into ./repos/<repo>
#   * locally they are siblings of this repo, ../<repo>
# Override with REPOS_DIR=<path> if yours are somewhere else.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="${1:-rendered}"

if [ -z "${REPOS_DIR:-}" ]; then
  if [ -d "$ROOT/repos" ]; then REPOS_DIR="$ROOT/repos"; else REPOS_DIR="$ROOT/.."; fi
fi

# service -> its values file, relative to REPOS_DIR. project-platform ships TWO components, which is
# why this is a flat map of component to file rather than one derived from a repo name.
SERVICES=(home quiz vmcp rs-mcp-server platform-auth)
declare -A VALUES_FILE=(
  [home]=project-platform/deploy/home.values.yaml
  [quiz]=data-driven-quiz-server/deploy/quiz.values.yaml
  [vmcp]=open-vMCP/deploy/vmcp.values.yaml
  [rs-mcp-server]=rs-mcp-server/deploy/rs-mcp-server.values.yaml
  [platform-auth]=project-platform/deploy/platform-auth.values.yaml
)

mkdir -p "$OUT"
rm -f "$OUT"/*.yaml

# The library subchart is vendored, never committed (see .gitignore), so a fresh checkout cannot render
# until this runs — every caller would otherwise die on "found in Chart.yaml, but missing in charts/".
helm dependency build "$ROOT/charts/platform-infra" >/dev/null
helm dependency build "$ROOT/charts/service" >/dev/null

# Both infra value sets: the local defaults and the public overlay that serves the live site.
helm template platform-infra "$ROOT/charts/platform-infra" \
  > "$OUT/platform-infra-local.yaml"
helm template platform-infra "$ROOT/charts/platform-infra" \
  -f "$ROOT/charts/platform-infra/values-public.yaml" \
  > "$OUT/platform-infra-public.yaml"
echo "  rendered platform-infra (local + public)"

for svc in "${SERVICES[@]}"; do
  values="$REPOS_DIR/${VALUES_FILE[$svc]}"
  [ -f "$values" ] || {
    echo "FATAL: no deploy values for ${svc} at ${values}" >&2
    echo "       that file is owned by the repo shipping ${svc}; set REPOS_DIR or check it out" >&2
    exit 1
  }
  helm template "$svc" "$ROOT/charts/service" -f "$values" > "$OUT/${svc}.yaml"
  echo "  rendered ${svc}"
done

echo "render-all: ${OUT}/ holds $(ls -1 "$OUT"/*.yaml | wc -l) rendered releases"

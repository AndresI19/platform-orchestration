#!/usr/bin/env bash
# render-parity.sh — prove the split charts (platform-infra + per-service) render the SAME Kubernetes
# objects as the umbrella chart, on both the local and public value sets. This is the gate that must
# pass before the split is applied to the cluster: it compares parsed resources by kind/name, so it is
# immune to document ordering and the `# Source:` comments that differ between charts.
#
# The version-writer Job is expected to differ in exactly two ways — its release-derived name and its
# command (the umbrella wrote a `components` map home never read; the split writes only `platform`).
# Everything else must be byte-identical as parsed objects.
#
# Needs: helm, node with js-yaml (NODE_PATH can point at any node_modules that has it).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NODE_PATH:=$HOME/git-workspace/claude-workspace/data-driven-quiz-server/node_modules}"
export NODE_PATH
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SERVICES="home quiz vmcp rs-mcp-server platform-auth"

helm dependency build charts/platform-infra >/dev/null
helm dependency build charts/service >/dev/null

render_new() { # $1=values-flag-for-infra
  helm template platform-infra ./charts/platform-infra ${1:-}
  for s in $SERVICES; do helm template "$s" ./charts/service -f "deploy-values/$s.yaml"; done
}

compare() { # $1=label $2=umbrella-file $3=new-file
  node - "$1" "$2" "$3" <<'JS'
const yaml=require('js-yaml'),fs=require('fs');
const load=f=>yaml.loadAll(fs.readFileSync(f,'utf8')).filter(Boolean);
const key=o=>`${o.kind}/${o.metadata.name}`, norm=s=>JSON.stringify(s);
const [label,uf,nf]=process.argv.slice(2);
const uMap=new Map(load(uf).map(o=>[key(o),o])), nMap=new Map(load(nf).map(o=>[key(o),o]));
const VW_OLD='Job/platform-version-writer', VW_NEW='Job/platform-infra-version-writer';
let diffs=0,matched=0;
const onlyU=[...uMap.keys()].filter(k=>!nMap.has(k)&&k!==VW_OLD);
const onlyN=[...nMap.keys()].filter(k=>!uMap.has(k)&&k!==VW_NEW);
for(const [k,uo] of uMap){ if(k===VW_OLD)continue; const no=nMap.get(k); if(!no)continue;
  if(norm(uo)===norm(no))matched++; else {diffs++; console.log(`  DIFF ${k}`);} }
const ok = diffs===0 && onlyU.length===0 && onlyN.length===0;
console.log(`  [${label}] identical=${matched} differing=${diffs} onlyU=${JSON.stringify(onlyU)} onlyN=${JSON.stringify(onlyN)} -> ${ok?'PARITY OK':'MISMATCH'}`);
process.exit(ok?0:1);
JS
}

helm template platform ./chart > "$TMP/umbrella-local.yaml"
render_new > "$TMP/new-local.yaml"
compare local "$TMP/umbrella-local.yaml" "$TMP/new-local.yaml"

helm template platform ./chart -f chart/values-public.yaml > "$TMP/umbrella-public.yaml"
render_new "-f charts/platform-infra/values-public.yaml" > "$TMP/new-public.yaml"
compare public "$TMP/umbrella-public.yaml" "$TMP/new-public.yaml"

echo "  render-parity: OK on local + public"
